// dsh-skill-audit — 技能审核的自动触发器（host 层执行，不经 ctx.shell，因此不受沙箱限制）。
//
// 为什么必须是插件，而不是 hooks 桥接：
//   @deepseek-ai/dsh-hooks-claude-code 通过 `ctx.shell` 运行钩子命令。当宿主没有可用的沙箱
//   runner 时（执行器按设计 fail-closed、绝不静默降级，表现为 `SANDBOX_UNAVAILABLE`），钩子
//   命令根本无法启动 —— 钩子配置配得再对也没用。本插件在 harness 进程内用 `ctx.subprocess`
//   （host 层）直接跑审核脚本，绕开该限制；这也是官方对"没有 Claude Code 对应物的定制行为"
//   给出的推荐形态。
//
// 两条通道：
//   1) `tools/post-execute` 自动触发（写入**之后**，审的是新内容）：
//        · write / edit 命中 <DSH_HOME>/skills/<技能>/ → 只审该技能
//        · 调用形态为「整批改写」的工具（参数 mode 为 restore / backup）→ 全量（整批覆盖 / 入库前）
//        · pwsh 等 shell，命令行同时含 skills 与写操作迹象 → 全量
//   2) `skill_audit` 工具 —— agent 可主动定向或全量审核。
//
// 审核逻辑不在本插件内（单一真源），按优先级三选一：
//   1) config.auditScript（显式；指定了却不存在 → 直接报错，不静默回落）
//   2) 用户态技能 <DSH_HOME>/skills/skill-audit/scripts/audit-skills.ps1 —— 规则真源
//   3) 包内快照   <pkg>/skill/scripts/audit-skills.ps1 —— 回退副本，使"装上插件就能用"
// 并**仅在用户态技能缺失时**用 ctx.skills.register 注册一份回退技能——层级是
// project > runtime > user，无条件注册会遮蔽用户态技能本身（硬约束，见 registerFallbackSkill）。
// 引擎缺失时工具报明确错误、自动触发静默跳过（不打扰正常写文件）。

import { existsSync, readFileSync } from 'node:fs'
import { stat } from 'node:fs/promises'
import { dirname, isAbsolute, join, resolve as resolvePath } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { Context } from '@deepseek-ai/cordis'
import { defineTool } from '@deepseek-ai/dsh-tools'
// 类型侧引入 subprocess 服务声明（扩展 Context.subprocess 类型；编译时擦除）
import type {} from '@deepseek-ai/dsh-subprocess'

// Plugin display name, shown in loader diagnostics.
export const name = 'tool-skill-audit'

export const inject = ['tools', 'subprocess']

const SKILL_NAME = 'skill-audit'
const ENGINE_RELATIVE = join('scripts', 'audit-skills.ps1')
const BUNDLED_SKILL_DIRNAME = 'skill'

const POWERSHELL =
  process.platform === 'win32'
    ? 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
    : 'pwsh'

const RAW_OUTPUT_MAX_BYTES = 4 * 1024 * 1024 // 全量审核的 JSON 报告可达数十 KB，留足余量
const STDERR_MAX_BYTES = 256 * 1024
const GRACE_MS = 3000
const DEFAULT_TIMEOUT_MS = 120000
const DEFAULT_MAX_CONTEXT_CHARS = 2000

export interface SkillAuditConfig {
  /**
   * 审核脚本路径。**显式指定且不存在时报错，不静默回落**。
   * 缺省按 用户态技能 → 包内快照 的顺序自动解析（见 resolveEngine）。
   */
  auditScript?: string
  /** 技能根目录；缺省 <DSH_HOME>/skills。 */
  skillsRoot?: string
  /** 关闭 write/edit 后的自动审核（工具仍可用）。缺省 true。 */
  autoAudit?: boolean
  /** PowerShell 可执行文件路径；缺省 Windows 内置 powershell.exe，其它平台 pwsh。 */
  powershell?: string
  /** 单次审核超时（毫秒）。缺省 120000。 */
  timeoutMs?: number
  /** 回传给模型的上下文字符上限。缺省 2000。 */
  maxContextChars?: number
  /**
   * 额外把哪些工具视为「整批改写技能目录」（触发全量审核）。
   * **缺省为空**：通用规则已覆盖 `mode` 为 restore / backup 的调用形态，因此本插件
   * **不绑定任何具体备份插件**。只有当你所用工具的"模式"参数不叫 `mode`、或取值不在这两个词里时，
   * 才需要在这里补上工具名。
   */
  fullAuditTools?: string[]
}

interface Finding {
  code: string
  level: string
  message: string
  file?: string
}

interface SkillResult {
  skill: string
  status: string
  fails: number
  warns: number
  scripts: number
  findings: Finding[]
}

interface AuditReport {
  auditedAt?: string
  skillsRoot?: string
  fail?: number
  warn?: number
  results?: SkillResult[]
}

interface RunOutcome {
  exitCode: number
  stdout: string
  stderr: string
}

interface Plan {
  /** null = 全量审核 */
  skills: string[] | null
  scope: string
}

function dshHome(): string {
  if (process.env.DSH_HOME) return process.env.DSH_HOME
  const home = process.env.USERPROFILE ?? process.env.HOME ?? '.'
  return join(home, '.dsh')
}

async function fileExists(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isFile()
  } catch {
    return false
  }
}

// —— 引擎与技能的定位（插件自带回退副本，使"装了就能用"）——
//
// 引擎三个来源，优先级从高到低：
//   1. config.auditScript —— 显式指定。**指定了却不存在则不静默回落**：显式意图优先于便利，
//      悄悄换一个引擎跑会让"我明明指了路径"变成难以察觉的错。
//   2. 用户态技能 <skillsRoot>/skill-audit/scripts/audit-skills.ps1 —— 规则真源，改完即生效。
//   3. 包内快照 <pkg>/skill/scripts/audit-skills.ps1 —— 随插件版本发布的回退副本。
// 为什么真源留在用户态而不搬进包：sync.ps1 的 restore 收尾与 AGENTS.md 的手工兜底命令都按
// **普通文件路径**调用它，而那时插件可能还没装（新机引导）；且用户态改判据立即生效、不必重建
// 重发重启。三层分工见 skill-audit 技能 §2.0。

export type EngineSource = 'config' | 'user-skill' | 'bundled'

export interface ResolvedEngine {
  path: string
  source: EngineSource
}

export interface ResolveEngineOptions {
  configured?: string
  skillsRoot: string
  bundledSkillDir?: string | null
  /** 供测试注入的"是不是文件"判定；缺省用 existsSync。 */
  isFile?: (path: string) => boolean
}

export function resolveEngine(options: ResolveEngineOptions): ResolvedEngine | null {
  const isFile = options.isFile ?? ((p: string) => existsSync(p))
  if (options.configured) {
    return isFile(options.configured) ? { path: options.configured, source: 'config' } : null
  }
  const userEngine = join(options.skillsRoot, SKILL_NAME, ENGINE_RELATIVE)
  if (isFile(userEngine)) return { path: userEngine, source: 'user-skill' }
  if (options.bundledSkillDir) {
    const bundled = join(options.bundledSkillDir, ENGINE_RELATIVE)
    if (isFile(bundled)) return { path: bundled, source: 'bundled' }
  }
  return null
}

/** 包内 skill/ 快照目录：从本模块向上找含 skill/SKILL.md 的目录（逐文件 dist/ 与打包形态都可定位）。 */
export function resolveBundledSkillDir(startUrl: string = import.meta.url): string | null {
  let dir = dirname(fileURLToPath(startUrl))
  for (let depth = 0; depth < 6; depth++) {
    const candidate = join(dir, BUNDLED_SKILL_DIRNAME)
    if (existsSync(join(candidate, 'SKILL.md'))) return candidate
    const parent = dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return null
}

/** 极简 frontmatter 取值（只认单行 `key: value`，够用且不为此引 YAML 依赖）。 */
function frontmatterField(content: string, key: string): string | undefined {
  // 注意：行内标志 (?m) 是 .NET/PCRE 写法，JS 的 RegExp 会抛 "Invalid group" —— 多行标志必须走第二参数。
  const match = content.match(new RegExp(`^${key}\\s*:\\s*(.+?)\\s*$`, 'm'))
  if (!match) return undefined
  return match[1].replace(/^["']|["']$/g, '')
}

/**
 * 把回退技能正文里的"用户态引擎路径"改写成实际生效的路径。
 * 只替换**精确字面量**：真源改了措辞就自然不再匹配，不会误伤别的路径。
 */
export function rewriteEnginePaths(content: string, enginePath: string): string {
  return content
    .replace(/\$env:USERPROFILE\\\.dsh\\skills\\skill-audit\\scripts\\audit-skills\.ps1/g, enginePath)
    .replace(/<DSH_HOME>[\\/]skills[\\/]skill-audit[\\/]scripts[\\/]audit-skills\.ps1/g, enginePath)
}

/** dsh-skill 的技能注册服务（结构化声明，避免为一行调用引入新的包依赖）。 */
interface SkillServiceLike {
  register(skill: {
    name: string
    description: string
    whenToUse?: string
    source: string
    content: string
    resourceBase?: { kind: 'directory'; path: string }
  }): () => void
}

export type FallbackRegistration =
  | 'registered'
  | 'skipped-user-skill'
  | 'skipped-no-service'
  | 'skipped-no-bundle'

/**
 * 仅在**用户态技能缺失**时注册回退技能。
 *
 * 硬约束：dsh-skill 的 `register()` 层级是 **project > runtime > user**，而
 * `<DSH_HOME>/skills` 属于 user 层 —— 无条件注册一个同名 runtime 技能会**遮蔽用户态技能本身**
 * （2026-09-17 查 dsh-skill 的 `lib/types/index.d.ts` 确认）。对本机而言那等于把天天在改的规则
 * 真源盖掉，是绝不能出的错。故这里先做文件系统判定，存在就一步都不做。
 */
export function registerFallbackSkill(
  ctx: unknown,
  options: { skillsRoot: string; bundledSkillDir: string | null; enginePath: string },
): FallbackRegistration {
  if (existsSync(join(options.skillsRoot, SKILL_NAME, 'SKILL.md'))) return 'skipped-user-skill'
  const skills = (ctx as { skills?: SkillServiceLike }).skills
  if (skills === undefined || typeof skills.register !== 'function') return 'skipped-no-service'
  if (!options.bundledSkillDir) return 'skipped-no-bundle'
  const skillMd = join(options.bundledSkillDir, 'SKILL.md')
  if (!existsSync(skillMd)) return 'skipped-no-bundle'

  const content = readFileSync(skillMd, 'utf8')
  skills.register({
    name: SKILL_NAME,
    description:
      frontmatterField(content, 'description') ??
      'DSH skill audit: deterministic static checks over skill frontmatter, script usability, reference integrity, credential leakage, machine-specific paths and dangerous commands.',
    whenToUse:
      frontmatterField(content, 'whenToUse') ??
      'A skill was created, edited, or restored from a backup repository; you need to know whether a skill is usable, self-consistent, and free of leaked credentials.',
    source: 'runtime',
    content: rewriteEnginePaths(content, options.enginePath),
    resourceBase: { kind: 'directory', path: options.bundledSkillDir },
  })
  return 'registered'
}

/** 从工具参数里尽力提取被操作的路径（不同工具键名不同，另有兜底扫描）。 */
export function candidatePaths(args: unknown): string[] {
  const out: string[] = []
  if (!args || typeof args !== 'object') return out
  const rec = args as Record<string, unknown>
  for (const key of ['file_path', 'filePath', 'path', 'target_file', 'file', 'notebook_path']) {
    const value = rec[key]
    if (typeof value === 'string' && value.length > 0) out.push(value)
  }
  for (const value of Object.values(rec)) {
    if (typeof value === 'string' && /skills[\\/]/i.test(value)) out.push(value)
    else if (Array.isArray(value)) {
      for (const item of value) {
        if (typeof item === 'string' && /skills[\\/]/i.test(item)) out.push(item)
      }
    }
  }
  return [...new Set(out)]
}

const SHELL_TOOLS = new Set(['pwsh', 'powershell', 'bash', 'sh', 'cmd'])

/**
 * 只有写入类文件工具才触发审核。read / glob / grep 等只读工具同样携带 `file_path`，
 * 但它们不修改内容 —— 2026-09-17 实测：不做这个白名单，每读一次技能文件就会注入一次
 * 审核上下文（纯噪音）。新出现的写入工具名在此登记即可。
 */
const FILE_WRITE_TOOLS = new Set([
  'write',
  'edit',
  'multi_edit',
  'multiedit',
  'notebook_edit',
  'apply_patch',
  'create_file',
  'str_replace_editor',
])
const WRITE_HINTS = /(?:Set-Content|Out-File|Add-Content|Clear-Content|Copy-Item|Move-Item|Remove-Item|New-Item|robocopy|git\s+(?:checkout|restore|apply))/i

/**
 * 「整批改写」的调用形态：这类工具会大范围改动技能目录（备份 / 恢复 / 同步），但**参数里不带路径**，
 * 没法靠路径判定，只能靠调用形态。判据是**参数**而不是工具名——插件因此不绑定任何具体备份插件。
 *
 * 2026-09-17 去硬依赖：原先写成按**工具名**硬匹配，对没有装那个备份插件的用户是纯死逻辑。
 * 现在只要参数是 `mode: 'restore' | 'backup'` 就触发，无论工具叫什么（真实备份操作必然带 `mode`，
 * 故行为不变）；模式名不叫 `mode` 的场景用 config.fullAuditTools 显式补充。
 */
const BULK_MODES = new Set(['restore', 'backup'])

/** 决定这次工具调用要不要触发审核；返回 null 表示与该工具无关。 */
export function planAudit(
  toolName: string,
  args: unknown,
  skillsRoot: string,
  fullAuditTools: readonly string[] = [],
): Plan | null {
  const lower = toolName.toLowerCase()
  const record = (args ?? {}) as Record<string, unknown>

  if (fullAuditTools.some((t) => t.toLowerCase() === lower)) {
    return { skills: null, scope: `${toolName}（配置为整批改写） → 全量` }
  }

  const mode = typeof record.mode === 'string' ? record.mode.toLowerCase() : ''
  if (BULK_MODES.has(mode)) {
    return { skills: null, scope: `${toolName}(${mode}) → 全量` }
  }

  if (SHELL_TOOLS.has(lower)) {
    const command = String((args as { command?: unknown } | undefined)?.command ?? '')
    if (!command || !/skills/i.test(command) || !WRITE_HINTS.test(command)) return null
    return { skills: null, scope: `${toolName} → 命令行涉及 skills 目录（全量）` }
  }

  // 只读工具（read/glob/grep …）也带 file_path，但不改内容 → 不触发
  if (!FILE_WRITE_TOOLS.has(lower)) return null

  const hits: string[] = []
  const root = skillsRoot.toLowerCase()
  for (const raw of candidatePaths(args)) {
    const abs = isAbsolute(raw) ? raw : resolvePath(raw)
    if (!abs.toLowerCase().startsWith(root)) continue
    const seg = abs.slice(skillsRoot.length).replace(/^[\\/]+/, '').split(/[\\/]/)[0]
    if (seg) hits.push(seg)
  }
  if (hits.length === 0) return null
  const skills = [...new Set(hits)]
  return { skills, scope: `${toolName} → 技能 ${skills.join(', ')}` }
}

export function parseReport(text: string): AuditReport | null {
  const raw = text.trim()
  if (!raw) return null
  try {
    return JSON.parse(raw) as AuditReport
  } catch {
    // 输出可能带前置警告/ BOM：从第一个 { 起再试一次
    const idx = raw.indexOf('{')
    if (idx <= 0) return null
    try {
      return JSON.parse(raw.slice(idx)) as AuditReport
    } catch {
      return null
    }
  }
}

export function apply(ctx: Context, config: SkillAuditConfig = {}): void {
  const skillsRoot = (config.skillsRoot ?? join(dshHome(), 'skills')).replace(/[\\/]+$/, '')
  const bundledSkillDir = resolveBundledSkillDir()
  const resolved = resolveEngine({ configured: config.auditScript, skillsRoot, bundledSkillDir })
  // 解析不到时仍算出"期望路径"作为报错文案（显式配置优先展示用户给的那条）。
  const auditScript =
    resolved?.path ?? config.auditScript ?? join(skillsRoot, SKILL_NAME, ENGINE_RELATIVE)
  const powershell = config.powershell ?? POWERSHELL
  const autoAudit = config.autoAudit !== false
  const timeoutMs =
    config.timeoutMs && config.timeoutMs > 0 ? config.timeoutMs : DEFAULT_TIMEOUT_MS
  const maxContextChars =
    config.maxContextChars && config.maxContextChars > 0
      ? config.maxContextChars
      : DEFAULT_MAX_CONTEXT_CHARS
  const fullAuditTools = Array.isArray(config.fullAuditTools) ? config.fullAuditTools : []

  async function runAudit(skills: string[] | null, signal?: AbortSignal): Promise<RunOutcome> {
    if (!(await fileExists(auditScript))) {
      return { exitCode: -1, stdout: '', stderr: `审核脚本不存在: ${auditScript}` }
    }
    const argv = [
      powershell,
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      auditScript,
      '-Json',
      '-SkillsRoot',
      skillsRoot,
    ]
    if (skills && skills.length > 0) argv.push('-Skill', skills.join(','))

    let handle
    try {
      handle = ctx.subprocess.spawn({
        argv,
        cwd: skillsRoot,
        stdio: {
          stdin: 'ignore',
          stdout: { maxBytes: RAW_OUTPUT_MAX_BYTES },
          stderr: { maxBytes: STDERR_MAX_BYTES },
        },
        graceMs: GRACE_MS,
        signal,
      })
    } catch (error) {
      return { exitCode: -1, stdout: '', stderr: `无法启动审核脚本: ${String(error)}` }
    }

    let outcome
    try {
      outcome = await handle.done
    } catch (error) {
      return { exitCode: -1, stdout: '', stderr: `审核脚本执行失败: ${String(error)}` }
    }
    if (outcome.signal !== null || outcome.exitCode === null) {
      return {
        exitCode: -1,
        stdout: '',
        stderr: `审核脚本被信号终止: ${outcome.signal ?? '(unknown)'}`,
      }
    }
    const stdout = handle.collected.stdout?.readFrom(0)
    const stderr = handle.collected.stderr?.readFrom(0)
    return {
      exitCode: outcome.exitCode,
      stdout: stdout?.text ?? '',
      stderr: stderr?.text ?? '',
    }
  }

  /** 审核并把结论渲染成人读文本（供工具返回）；无法解析时返回原始输出。 */
  async function auditAndRender(
    skills: string[] | null,
    signal?: AbortSignal,
  ): Promise<{ ok: boolean; text: string; report: AuditReport | null }> {
    const run = await runAudit(skills, signal)
    if (run.exitCode === -1) return { ok: false, text: run.stderr, report: null }
    const report = parseReport(run.stdout)
    if (!report) {
      const fallback = [run.stdout.trim(), run.stderr.trim()].filter(Boolean).join('\n')
      return { ok: false, text: fallback || '(审核脚本无输出)', report: null }
    }
    const problem = (report.results ?? []).filter((r) => r.status !== 'pass')
    const lines: string[] = []
    lines.push(
      `技能审核：${report.results?.length ?? 0} 个技能，fail ${report.fail ?? 0}，warn ${report.warn ?? 0}`,
    )
    for (const r of report.results ?? []) {
      const mark = r.status === 'pass' ? '[通过]' : r.status === 'warn' ? '[注意]' : '[失败]'
      lines.push(`${mark} ${r.skill}（脚本 ${r.scripts} 个，fail ${r.fails}，warn ${r.warns}）`)
      for (const f of r.findings ?? []) {
        if (f.level === 'info') continue
        lines.push(`    - [${f.level}] ${f.message}`)
      }
    }
    if (problem.length === 0) lines.push('全部技能通过。')
    return { ok: true, text: lines.join('\n'), report }
  }

  /**
   * 构造回传上下文；只有存在需要行动的问题时才返回消息。
   *
   * `failsOnly` 用于**全量场景**（restore/backup、shell 批量改写）：那里 warn 的绝对数量很大，
   * 逐条列出会把上下文挤爆且失去焦点 —— 全量时只详列 fail，warn 压成一行汇总；
   * 定向单技能时（通常只有个位数条）才 fail + warn 都列。
   * 全量且**只有 warn**时直接返回 undefined：那属于背景噪音，不该打断任何一次写入。
   */
  async function buildContextMessage(
    report: AuditReport,
    scope: string,
    failsOnly = false,
  ): Promise<unknown | undefined> {
    const problem = (report.results ?? []).filter((r) => r.status !== 'pass')
    if (problem.length === 0) return undefined

    const lines: string[] = [`【技能审核 skill-audit】范围：${scope}`]
    const warnOnly: string[] = []
    for (const r of problem) {
      const detail = (r.findings ?? []).filter((f) => f.level !== 'info')
      const fails = detail.filter((f) => f.level === 'fail')
      if (failsOnly && fails.length === 0) {
        warnOnly.push(r.skill)
        continue
      }
      const mark = r.status === 'fail' ? '未通过' : '有注意项'
      lines.push(`· ${r.skill}：${mark}（fail ${r.fails} / warn ${r.warns}）`)
      const list = failsOnly ? fails : detail
      const shown = list.slice(0, 4)
      for (const f of shown) lines.push(`    - [${f.level}] ${f.message}`)
      if (list.length > shown.length) {
        lines.push(`    … 另有 ${list.length - shown.length} 项，见 ~/.dsh/vet/skill-audits/latest.json`)
      }
    }
    // 全量场景下一条 fail 都没有 → 完全不打扰（warn 是背景噪音，只留在日志里）。
    // 注意必须在这里早退：一旦先 push 了下面的汇总行，再判断"只剩标题"就永远不成立。
    if (failsOnly && lines.length === 1) return undefined
    if (warnOnly.length > 0) {
      const head = warnOnly.slice(0, 8).join('、')
      lines.push(
        `· 另有 ${warnOnly.length} 个技能仅有 warn（多为缺 version/whenToUse 等元数据）：${head}${warnOnly.length > 8 ? ' …' : ''}`,
      )
    }
    lines.push('修复后可调用 skill_audit 工具复验；判据与误报处置见 skill-audit 技能。')

    let text = lines.join('\n')
    if (text.length > maxContextChars) {
      text = `${text.slice(0, maxContextChars)}\n…（已截断；完整结论见 ~/.dsh/vet/skill-audits/latest.json）`
    }

    try {
      const llm = (await import('@deepseek-ai/dsh-llm')) as {
        createUserMessage?: (input: unknown) => unknown
      }
      if (typeof llm.createUserMessage !== 'function') return undefined
      return llm.createUserMessage({
        content: [{ type: 'text', text }],
        source: { kind: 'plugin', plugin: 'tool-skill-audit' },
      })
    } catch {
      // dsh-llm 不可用时降级：审核照常执行并留日志，只是不注入上下文
      return undefined
    }
  }

  ctx.tools.register(
    defineTool({
      name: 'skill_audit',
      description:
        'Statically audit DSH skills: frontmatter contract (name/description/whenToUse/version), ' +
        'script usability (UTF-8 BOM + PowerShell 5.1 parse), SKILL.md reference integrity, ' +
        'credential leakage, machine-specific paths and dangerous command patterns. ' +
        'Pass "skill" to audit one or more skills (comma separated); omit it to audit every skill ' +
        'under the skills root. Findings are also logged to <DSH_HOME>/vet/skill-audits/.',

      parameters: {
        skill: {
          type: 'string',
          description:
            'Skill name(s) to audit, comma separated. Omit to audit all skills in the skills root.',
        },
      },

      output: {
        schema: {
          type: 'object',
          properties: {
            stdout: { type: 'string', required: true, description: 'Human-readable audit report.' },
            stderr: { type: 'string', required: true, description: 'Diagnostics when the run failed.' },
          },
          additionalProperties: false,
        },
        render: (_args, value) => [
          {
            type: 'text',
            text:
              (value.stdout?.trim?.()?.length ?? 0) > 0
                ? value.stdout
                : value.stderr?.trim?.()?.length > 0
                  ? `(no stdout) ${value.stderr}`
                  : '(empty output)',
          },
        ],
      },

      timeoutMs,

      async execute(args, exec) {
        if (exec.signal.aborted) throw new Error('skill_audit was aborted before completion')
        const raw = typeof args.skill === 'string' ? args.skill.trim() : ''
        const skills = raw
          ? raw
              .split(',')
              .map((s) => s.trim())
              .filter(Boolean)
          : null
        const { ok, text } = await auditAndRender(skills, exec.signal)
        if (exec.signal.aborted) throw new Error('skill_audit was aborted before completion')
        if (!ok) throw new Error(`skill_audit 执行失败:\n${text}`)
        return { stdout: text, stderr: '' }
      },
    }),
  )

  if (autoAudit) {
    const on = (
      ctx as unknown as {
        on?: (event: string, handler: (...handlerArgs: unknown[]) => unknown) => unknown
      }
    ).on
    if (typeof on === 'function') {
      on('tools/post-execute', async (...handlerArgs: unknown[]) => {
        // waterfall 契约：(exec, result, next)
        const exec = handlerArgs[0] as
          | { name?: string; arguments?: unknown; signal?: AbortSignal }
          | undefined
        const next = handlerArgs[2] as (() => Promise<unknown>) | undefined
        try {
          const toolName = typeof exec?.name === 'string' ? exec.name : ''
          if (!toolName || typeof next !== 'function') return await next?.()
          const plan = planAudit(toolName, exec?.arguments, skillsRoot, fullAuditTools)
          if (!plan) return await next()

          const run = await runAudit(plan.skills, exec?.signal)
          const report = run.exitCode === -1 ? null : parseReport(run.stdout)
          const context = report
            ? await buildContextMessage(report, plan.scope, plan.skills === null)
            : undefined

          const downstream = (await next()) as
            | { kind?: string; additionalContexts?: unknown[] }
            | undefined
          if (!context) return downstream
          const existing = Array.isArray(downstream?.additionalContexts)
            ? downstream.additionalContexts
            : []
          return { ...(downstream ?? {}), additionalContexts: [context, ...existing] }
        } catch {
          // 自动触发永远不能影响工具调用本身
          return await next?.()
        }
      })
    }
  }

  // 回退技能注册与 autoAudit 无关：它决定"模型能不能加载到 skill-audit 技能"，
  // 而不是"要不要自动跑审核"。用户态技能在场时这一步是空操作。
  const fallbackSkill = registerFallbackSkill(ctx, {
    skillsRoot,
    bundledSkillDir,
    enginePath: auditScript,
  })

  ctx.logger.info(
    `[tool-skill-audit] registered "skill_audit" — engine=${auditScript} (${resolved?.source ?? 'MISSING'}) skillsRoot=${skillsRoot} autoAudit=${autoAudit} fallbackSkill=${fallbackSkill}`,
  )
}
