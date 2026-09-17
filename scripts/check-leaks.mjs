// 发布前泄漏防线：源码 / 测试 / 脚本 / 内置技能 / README 一律不得含本机指纹。
//
// 为什么需要它：这类问题**只能靠人记得查**，而实践已经证明人会漏——2026-09-17 就漏过一次：
// 源码注释里把本机资产规模当成论据写进去，又随包发布给了所有人。
//
// 判据真源**不在本仓库**：规则在 {local-skill} 技能的 scripts/fingerprint-scan.ps1，
// 这里只负责"挑文件 + 传参数"。否则同一套规则会变成两份、必然漂移。
//
// 本文件自身不含机器信息：工作区根目录在运行时从仓库位置推导，
// 本机专属模式（组织名、临时目录约定名等）放在 .gitignore 的 .leak-patterns.local 里。
//
// 扫描器不存在时**跳过并告警**而不是失败：它是作者侧的守门人，第三方克隆本仓库时不必具备。

import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)))

const scanner =
  process.env.DSH_LEAK_SCANNER ??
  join(homedir(), '.dsh', 'skills', '{local-skill}', 'scripts', 'scan-fingerprints.ps1')

if (!existsSync(scanner)) {
  console.warn(`[check-leaks] 跳过：找不到指纹扫描器 ${scanner}`)
  console.warn('[check-leaks] 装上 {local-skill} 技能，或用 DSH_LEAK_SCANNER 指定路径。')
  process.exit(0)
}

// 工作区根目录 = 本仓库的上一级。运行时推导，故源码里没有这个路径的字面量。
const workspaceRoot = dirname(repoRoot)

/** 本机专属模式：一行一条正则，文件本身不进版本库（见 .gitignore）。 */
const localPatternsFile = join(repoRoot, '.leak-patterns.local')
const localPatterns = existsSync(localPatternsFile)
  ? readFileSync(localPatternsFile, 'utf8')
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter((l) => l && !l.startsWith('#'))
  : []

const targets = ['src', 'test', 'scripts', 'skill', 'README.md', 'package.json', 'cordis.patch.yml']
  .map((t) => join(repoRoot, t))
  .filter((t) => existsSync(t))

// 多条额外模式合成一条交替正则，只传一个 -ExtraPattern：
// 避免依赖 `-File` 模式下重复命名参数的绑定行为（该模式下 argv 有一串已知怪癖）。
const extra = [workspaceRoot, ...localPatterns].map((p) => `(?:${p})`)
// -File 模式下 -Path a,b,c 不会拆成数组 → 按逗号拼接是本仓库既有的约定写法。
const argv = [
  process.platform === 'win32' ? 'powershell' : 'pwsh',
  '-NoProfile',
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  scanner,
  '-Path',
  targets.join(','),
]
if (extra.length > 0) argv.push('-ExtraPattern', extra.join('|'))

console.log(
  `[check-leaks] 扫描 ${targets.length} 个目标（${localPatterns.length} 条本机专属模式）：` +
    targets.map((t) => relative(repoRoot, t)).join(', '),
)
const result = spawnSync(argv[0], argv.slice(1), { stdio: 'inherit' })
if (result.error) {
  console.error(`[check-leaks] 无法启动扫描器：${String(result.error)}`)
  process.exit(1)
}
process.exit(result.status ?? 1)
