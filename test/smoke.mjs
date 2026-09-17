// End-to-end smoke test for the built plugin (dist/index.js).
//
// It drives the real tool implementation and the real post-execute listener against a
// throwaway skills sandbox: ctx is faked (tools.register captures the tool, subprocess.spawn
// delegates to node:child_process, on() captures the waterfall handler), while the audit
// engine itself is the LIVE skill-audit script copied into the sandbox — so the suite proves
// the plugin <-> engine contract, not a mock of it. Live DSH sources are never touched.
//
// Run with:  node test/smoke.mjs   (or: npm test)
//
// SMOKE_PLUGIN_DIST points the suite at another copy of the plugin (e.g. a second local build).
// The copy must live in a tree that can resolve @deepseek-ai/dsh-tools / dsh-llm; do NOT point it
// at the DSH install tree (~/.dsh/profiles/web/node_modules/...) — bare node there resolves a
// mismatched @deepseek-ai/dsh-llm copy. A *published* artifact is verified by content:
// compare the tarball's dist/index.js SHA256 against the local build, then let
// `dsh --profile web --dump-config` prove the host assembles it.

import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const pluginDist = process.env.SMOKE_PLUGIN_DIST ?? new URL('../dist/index.js', import.meta.url).href
console.log(`plugin under test: ${pluginDist}`)
const { apply, planAudit, parseReport, resolveEngine, resolveBundledSkillDir, registerFallbackSkill, rewriteEnginePaths } =
  await import(pluginDist)

const PS = 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
const HOME = process.env.USERPROFILE ?? process.env.HOME ?? '.'
const LIVE_AUDIT_SCRIPT = join(HOME, '.dsh', 'skills', 'skill-audit', 'scripts', 'audit-skills.ps1')

let failures = 0
function check(name, ok, detail = '') {
  if (ok) console.log(`PASS  ${name}`)
  else {
    console.log(`FAIL  ${name}   ${detail}`)
    failures++
  }
}

// ---------- sandbox ----------
const root = join(tmpdir(), `dsh-skill-audit-smoke-${process.pid}`)
rmSync(root, { recursive: true, force: true })
const skillsRoot = join(root, 'skills')
mkdirSync(join(skillsRoot, 'demo-warn'), { recursive: true })
mkdirSync(join(skillsRoot, 'demo-bad', 'scripts'), { recursive: true })

// demo-warn：必填项齐全、但缺 whenToUse/version/last_updated → warn（用于验证"有发现才注入上下文"）
writeFileSync(
  join(skillsRoot, 'demo-warn', 'SKILL.md'),
  [
    '---',
    'name: demo-warn',
    'description: "一个用于冒烟测试的技能：契约必填项齐全但缺少可选元数据，应当只报 warn 而不是 fail。"',
    '---',
    '',
    '# demo-warn',
    '',
  ].join('\n'),
  'utf8',
)

// demo-bad：缺 description（fail）+ 脚本无 BOM（fail），用于验证 fail 会被检出
writeFileSync(
  join(skillsRoot, 'demo-bad', 'SKILL.md'),
  ['---', 'name: demo-bad', '---', '', '# demo-bad', ''].join('\n'),
  'utf8',
)
writeFileSync(
  join(skillsRoot, 'demo-bad', 'scripts', 'nobom.ps1'),
  "# 无 BOM 的中文脚本\nWrite-Host '中文：会被 5.1 按 GBK 解码'\n",
  'utf8',
)

if (!existsSync(LIVE_AUDIT_SCRIPT)) {
  throw new Error(`live audit engine not found: ${LIVE_AUDIT_SCRIPT} — cannot run the contract test`)
}
const auditScript = join(root, 'audit-skills.ps1')
writeFileSync(auditScript, readFileSync(LIVE_AUDIT_SCRIPT))

// ---------- fake cordis ctx ----------
let tool
let postExecute
const ctx = {
  tools: { register: (t) => { tool = t } },
  logger: { info: () => {}, warn: (m) => console.log(`[warn] ${m}`) },
  on: (event, handler) => { if (event === 'tools/post-execute') postExecute = handler },
  subprocess: {
    spawn({ argv, cwd }) {
      const child = spawn(argv[0], argv.slice(1), { cwd, windowsHide: true })
      const out = []
      const err = []
      child.stdout.on('data', (d) => out.push(d))
      child.stderr.on('data', (d) => err.push(d))
      const done = new Promise((resolve) => {
        child.on('close', (code, sig) => resolve({ exitCode: code, signal: sig }))
      })
      const collected = {
        stdout: { readFrom: () => ({ text: Buffer.concat(out).toString('utf8') }) },
        stderr: { readFrom: () => ({ text: Buffer.concat(err).toString('utf8') }) },
      }
      return { done, collected }
    },
  },
}

apply(ctx, { skillsRoot, auditScript, powershell: PS })
const exec = { signal: new AbortController().signal }
const call = (args) => tool.execute(args, exec)
const nextReturning = (value) => async () => value ?? { kind: 'enter', additionalContexts: [] }

console.log('--- 1) tool definition ---')
check('tool name registered', tool?.name === 'skill_audit', String(tool?.name))
check('skill parameter declared', tool?.parameters?.properties?.skill?.type === 'string', JSON.stringify(tool?.parameters?.properties?.skill))
check('post-execute listener registered', typeof postExecute === 'function', String(typeof postExecute))

console.log('--- 2) planAudit (pure) ---')
check(
  'write into a skill dir → scoped to that skill',
  JSON.stringify(planAudit('write', { file_path: join(skillsRoot, 'demo-warn', 'SKILL.md') }, skillsRoot)) ===
    JSON.stringify({ skills: ['demo-warn'], scope: `write → 技能 demo-warn` }),
  JSON.stringify(planAudit('write', { file_path: join(skillsRoot, 'demo-warn', 'SKILL.md') }, skillsRoot)),
)
check('write outside skills → null', planAudit('write', { file_path: join(root, 'notes.md') }, skillsRoot) === null)
check(
  'read-only tool (read) → null even inside a skill',
  planAudit('read', { file_path: join(skillsRoot, 'demo-warn', 'SKILL.md') }, skillsRoot) === null,
)
check('glob → null', planAudit('glob', { path: skillsRoot }, skillsRoot) === null)
check(
  'edit into a skill script → scoped',
  planAudit('edit', { file_path: join(skillsRoot, 'demo-bad', 'scripts', 'nobom.ps1') }, skillsRoot)?.skills?.[0] === 'demo-bad',
)
// 「整批改写」判据必须与工具名无关：原先按工具名硬匹配，对没装那个备份插件的用户是死逻辑。
// 用户是死逻辑。下面一律用中性名字，确保这条判据真的是按**调用形态**（mode 参数）而非名字触发的。
check(
  'any tool with mode:restore → full audit (name-independent)',
  planAudit('some_backup_plugin', { mode: 'restore' }, skillsRoot)?.skills === null,
)
check(
  'any tool with mode:backup → full audit (case-insensitive)',
  planAudit('another_sync_tool', { mode: 'BACKUP' }, skillsRoot)?.skills === null,
)
check('unrelated mode → null', planAudit('some_backup_plugin', { mode: 'nonsense' }, skillsRoot) === null)
check('no mode argument → null', planAudit('some_backup_plugin', { dryRun: true }, skillsRoot) === null)
check(
  'fullAuditTools opt-in covers tools whose mode arg is named differently',
  planAudit('my_restore_tool', { op: 'apply' }, skillsRoot, ['my_restore_tool'])?.skills === null,
)
check(
  'fullAuditTools does not leak onto other tools',
  planAudit('other_tool', { op: 'apply' }, skillsRoot, ['my_restore_tool']) === null,
)
check('read-only shell → null', planAudit('pwsh', { command: 'Get-ChildItem C:\\x\\skills' }, skillsRoot) === null)
check(
  'shell writing into skills → full audit',
  planAudit('pwsh', { command: 'Set-Content C:\\x\\skills\\a\\SKILL.md x' }, skillsRoot)?.skills === null,
)

console.log('--- 3) parseReport (pure) ---')
check('plain json parsed', parseReport('{"fail":1,"warn":0,"results":[]}')?.fail === 1)
check('noise before json tolerated', parseReport('WARNING: x\n{"fail":2,"results":[]}')?.fail === 2)
check('garbage → null', parseReport('not json at all') === null)
check('empty → null', parseReport('   ') === null)

console.log('--- 4) skill_audit tool: full audit ---')
let res = await call({})
check('full audit returns stdout', typeof res.stdout === 'string' && res.stdout.length > 0)
check('full audit reports the failing skill', /demo-bad/.test(res.stdout) && /\[失败\]/.test(res.stdout), res.stdout)
check('full audit reports the warning-only skill', /demo-warn/.test(res.stdout) && /\[注意\]/.test(res.stdout), res.stdout)

console.log('--- 5) skill_audit tool: scoped audit ---')
res = await call({ skill: 'demo-warn' })
check('scoped audit only mentions the requested skill', res.stdout.includes('demo-warn') && !res.stdout.includes('demo-bad'), res.stdout)
res = await call({ skill: 'demo-warn,demo-bad' })
check(
  'comma-separated multi-skill audit covers both (regression: -File argv does not split on commas)',
  res.stdout.includes('demo-warn') && res.stdout.includes('demo-bad'),
  res.stdout,
)

console.log('--- 6) post-execute: write into a skill dir injects context ---')
let nextCalls = 0
let out = await postExecute(
  { name: 'write', arguments: { file_path: join(skillsRoot, 'demo-warn', 'SKILL.md') }, signal: exec.signal },
  { content: [] },
  async () => { nextCalls++; return { kind: 'enter', additionalContexts: [] } },
)
check('next() delegated once', nextCalls === 1, `calls=${nextCalls}`)
check('context injected for warn-level finding', Array.isArray(out?.additionalContexts) && out.additionalContexts.length === 1, JSON.stringify(out)?.slice(0, 200))
check('injected message carries the audit header', JSON.stringify(out?.additionalContexts?.[0] ?? {}).includes('技能审核'), JSON.stringify(out?.additionalContexts?.[0] ?? {}).slice(0, 200))

console.log('--- 7) post-execute: unrelated write stays silent ---')
out = await postExecute(
  { name: 'write', arguments: { file_path: join(root, 'notes.md') }, signal: exec.signal },
  { content: [] },
  nextReturning({ kind: 'enter' }),
)
check('no context for unrelated path', !out?.additionalContexts, JSON.stringify(out))

console.log('--- 7b) post-execute: read-only tools stay silent ---')
out = await postExecute(
  { name: 'read', arguments: { file_path: join(skillsRoot, 'demo-warn', 'SKILL.md') }, signal: exec.signal },
  { content: [] },
  nextReturning({ kind: 'enter' }),
)
check('no context for read', !out?.additionalContexts, JSON.stringify(out))

console.log('--- 8) post-execute: restore audits everything (fails included) ---')
out = await postExecute(
  { name: 'any_backup_tool', arguments: { mode: 'restore' }, signal: exec.signal },
  { content: [] },
  nextReturning({ kind: 'enter' }),
)
check('context injected after restore', Array.isArray(out?.additionalContexts) && out.additionalContexts.length === 1)
check('restore context mentions the failing skill', JSON.stringify(out?.additionalContexts?.[0] ?? {}).includes('demo-bad'), JSON.stringify(out?.additionalContexts?.[0] ?? {}).slice(0, 300))
check('full-scope context omits warn details', !/\[warn\]/.test(JSON.stringify(out?.additionalContexts?.[0] ?? {})), JSON.stringify(out?.additionalContexts?.[0] ?? {}).slice(0, 300))

console.log('--- 8b) full-scope audit with only warnings stays quiet ---')
const warnOnlyRoot = join(root, 'skills-warn-only')
mkdirSync(join(warnOnlyRoot, 'demo-warn'), { recursive: true })
writeFileSync(join(warnOnlyRoot, 'demo-warn', 'SKILL.md'), readFileSync(join(skillsRoot, 'demo-warn', 'SKILL.md')))
let warnOnlyHandler
apply(
  { ...ctx, tools: { register: () => {} }, on: (_e, h) => { warnOnlyHandler = h } },
  { skillsRoot: warnOnlyRoot, auditScript, powershell: PS },
)
out = await warnOnlyHandler(
  { name: 'any_backup_tool', arguments: { mode: 'restore' }, signal: exec.signal },
  { content: [] },
  nextReturning({ kind: 'enter' }),
)
check('no context when every finding is warn-only', !out?.additionalContexts, JSON.stringify(out))

console.log('--- 9) missing engine fails closed / stays silent ---')
let tool2
const ctx2 = {
  ...ctx,
  tools: { register: (t) => { tool2 = t } },
  on: () => {},
}
apply(ctx2, { skillsRoot, auditScript: join(root, 'nope.ps1'), powershell: PS })
let threw = null
try { await tool2.execute({}, exec) } catch (e) { threw = e }
check('tool reports a missing engine', /不存在/.test(threw?.message ?? ''), threw?.message)
let silent
const ctx3 = { ...ctx, tools: { register: () => {} }, on: (_e, h) => { silent = h } }
apply(ctx3, { skillsRoot, auditScript: join(root, 'nope.ps1'), powershell: PS })
const silentOut = await silent(
  { name: 'write', arguments: { file_path: join(skillsRoot, 'demo-warn', 'SKILL.md') }, signal: exec.signal },
  { content: [] },
  nextReturning({ kind: 'enter' }),
)
check('auto path stays silent when the engine is missing', !silentOut?.additionalContexts, JSON.stringify(silentOut))

console.log('--- 10) engine resolution precedence ---')
{
  const only = (present) => (p) => present.includes(p)
  const cfgPath = join(root, 'cfg.ps1')
  const userEngine = join(skillsRoot, 'skill-audit', 'scripts', 'audit-skills.ps1')
  const bundledDir = join('X:', 'pkg', 'skill')
  const bundledEngine = join(bundledDir, 'scripts', 'audit-skills.ps1')
  const at = (opts) => resolveEngine({ skillsRoot, ...opts })?.source ?? null
  check('configured + exists → config', at({ configured: cfgPath, isFile: only([cfgPath]) }) === 'config')
  check(
    'configured + missing → null (no silent fallback to another engine)',
    at({ configured: cfgPath, bundledSkillDir: bundledDir, isFile: only([bundledEngine]) }) === null,
  )
  check('no config, user-land skill present → user-skill', at({ isFile: only([userEngine]) }) === 'user-skill')
  check(
    'no config, no user-land skill → bundled',
    at({ bundledSkillDir: bundledDir, isFile: only([bundledEngine]) }) === 'bundled',
  )
  check('nothing available → null', at({ isFile: only([]) }) === null)
}

console.log('--- 11) fallback skill registration guard ---')
const bundled = resolveBundledSkillDir(pluginDist)
check('bundled skill dir located from the built module', typeof bundled === 'string' && /[\\/]skill$/.test(bundled), String(bundled))
{
  let registered = null
  const skillsCtx = { skills: { register: (s) => { registered = s; return () => {} } } }
  const opts = { skillsRoot, bundledSkillDir: bundled, enginePath: 'E:/x.ps1' }

  // 用户态技能在场 → 一步都不能做：runtime 层高于 user 层，注册会遮蔽用户态技能本身。
  mkdirSync(join(skillsRoot, 'skill-audit'), { recursive: true })
  writeFileSync(join(skillsRoot, 'skill-audit', 'SKILL.md'), '---\nname: skill-audit\n---\n', 'utf8')
  check('user-land skill present → skipped', registerFallbackSkill(skillsCtx, opts) === 'skipped-user-skill')
  check('nothing registered while the user-land skill exists', registered === null)

  rmSync(join(skillsRoot, 'skill-audit'), { recursive: true, force: true })
  const verdict = registerFallbackSkill(skillsCtx, opts)
  check('user-land skill absent → registered', verdict === 'registered', verdict)
  check('registered under the canonical name', registered?.name === 'skill-audit', String(registered?.name))
  check('declares runtime source (required by dsh-skill)', registered?.source === 'runtime', String(registered?.source))
  check(
    'description / whenToUse parsed from the bundled frontmatter',
    (registered?.description ?? '').length > 40 && (registered?.whenToUse ?? '').length > 20,
    `desc=${(registered?.description ?? '').length} when=${(registered?.whenToUse ?? '').length}`,
  )
  check(
    'resourceBase points at the bundled dir (so relative paths resolve)',
    registered?.resourceBase?.kind === 'directory' && registered.resourceBase.path === bundled,
    JSON.stringify(registered?.resourceBase),
  )
  check('engine path substituted into the body', (registered?.content ?? '').includes('E:/x.ps1'))
  check('no skills service → skipped', registerFallbackSkill({}, opts) === 'skipped-no-service')
}

console.log('--- 12) bundled assets integrity ---')
{
  const bundledEngine = join(bundled, 'scripts', 'audit-skills.ps1')
  check('bundled engine shipped', existsSync(bundledEngine))
  const bom = readFileSync(bundledEngine).subarray(0, 3)
  check(
    'bundled engine keeps its UTF-8 BOM (5.1 would mis-decode Chinese without it)',
    bom[0] === 0xef && bom[1] === 0xbb && bom[2] === 0xbf,
    [...bom].join(','),
  )
  const bundledMd = readFileSync(join(bundled, 'SKILL.md'), 'utf8')
  check('bundled SKILL.md is the real skill (name matches)', /^name:\s*skill-audit\s*$/m.test(bundledMd))

  const sample =
    'a "$env:USERPROFILE\\.dsh\\skills\\skill-audit\\scripts\\audit-skills.ps1" b <DSH_HOME>/skills/skill-audit/scripts/audit-skills.ps1 c'
  const rewritten = rewriteEnginePaths(sample, 'E:/x.ps1')
  check('rewrites the $env:USERPROFILE literal', !rewritten.includes('$env:USERPROFILE'), rewritten)
  check('rewrites the <DSH_HOME> literal', !rewritten.includes('<DSH_HOME>'), rewritten)
  check('replaces every occurrence', (rewritten.match(/E:\/x\.ps1/g) ?? []).length === 2, rewritten)
}

console.log('--- 13) apply() reports which engine won ---')
{
  const logs = []
  let liveTool
  apply(
    { ...ctx, tools: { register: (t) => { liveTool = t } }, logger: { info: (m) => logs.push(m), warn: () => {} } },
    { skillsRoot, powershell: PS }, // 不传 auditScript → 走自动解析
  )
  const line = logs.join('\n')
  check('startup log names the resolved engine source', /engine=.*\((config|user-skill|bundled|MISSING)\)/.test(line), line)
  check('startup log reports the fallback-skill verdict', /fallbackSkill=(registered|skipped-[a-z-]+)/.test(line), line)
  check('tool still registered without an explicit auditScript', liveTool?.name === 'skill_audit', String(liveTool?.name))
}

rmSync(root, { recursive: true, force: true })
console.log('')
console.log(failures === 0 ? 'ALL SMOKE TESTS PASSED' : `FAILED CHECKS: ${failures}`)
process.exit(failures === 0 ? 0 : 1)
