// 发布前泄漏防线：源码 / 测试 / 脚本 / 内置技能 / README / 配置一律不得含本机指纹。
//
// 为什么需要它：这类问题**只能靠人记得查**，而实践已经证明人会漏——曾经漏过一次：
// 源码注释里把本机资产规模当作论据写进去，又随包发布给了所有人。
//
// 规则**自足**，刻意不依赖任何外部脚本或技能，分三类：
//   ① 从**运行环境**推导的本机指纹——当前用户名 / 家目录 / 计算机名 / 云盘同步根目录名。
//      它们不写死在源码里（写了就自相矛盾：扫描器自己成了泄漏源），一律运行时取。
//   ② 与机器无关的**形态**规则——家目录式绝对路径、带端口的回环地址、内网 IP、云盘厂商词、
//      以及"规模类计数"（`N 个技能` 这类会暴露本机资产数量的说法）。
//   ③ 由调用方补充的**本机专属**模式，来自 .gitignore 的 `.leak-patterns.local`
//      （组织名、约定目录名等）——该文件不进版本库，所以扫描器与被扫仓库都不必写出这些词。
//
// 为什么不让外部的扫描器代劳：发布物闸门不该在"运行者机器上恰好装了某个技能"时才生效，
// 也不该把另一个仓库的内部路径写进本仓库（对方一改名，这里就悄悄失效）。
//
// 注意：匹配**大小写敏感**（JS RegExp 默认如此）。刻意不开 `i` ——否则英文里形如
// "xxx-only" 的小写短语会被主机名前缀规则误伤。

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)))
// 工作区根目录 = 本仓库的上一级。运行时推导，故源码里没有这个路径的字面量。
const workspaceRoot = dirname(repoRoot)

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

/** 本机专属模式：一行一条正则，`#` 开头为注释，文件本身不进版本库（见 .gitignore）。 */
const localPatternsFile = join(repoRoot, '.leak-patterns.local')
const localPatterns = existsSync(localPatternsFile)
  ? readFileSync(localPatternsFile, 'utf8')
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter((l) => l && !l.startsWith('#'))
  : []

function buildRules() {
  const rules = []
  const add = (name, pattern) => {
    if (pattern) rules.push({ name, re: new RegExp(pattern) })
  }

  // 同一个绝对路径在源码里有三种写法：反斜杠、双反斜杠（JS / TS 字符串转义）、正斜杠。
  // 只匹配第一种，另外两种会**直接漏过** —— 实测漏过一次：某个公开仓库的测试脚本把一条
  // 双反斜杠写法的 Windows 绝对路径公开了很久，旧的单反斜杠规则一次都没拦住它。
  // （这段注释刻意不写出示例路径：写出来本扫描器就会命中自己。）
  // 路径类规则一律从这里生成。
  const SEP = '(?:\\\\{1,2}|/)+'
  const pathVariants = (p) =>
    p
      .split(/[\\/]+/)
      .filter(Boolean)
      .map(esc)
      .join(SEP)

  if (process.env.USERNAME) add('当前用户名', esc(process.env.USERNAME))
  if (process.env.USERPROFILE) add('当前家目录', pathVariants(process.env.USERPROFILE))
  if (process.env.COMPUTERNAME) add('当前计算机名', esc(process.env.COMPUTERNAME))

  // 云盘 / 同步根的**实际目录名**（含单位后缀，形如「<厂商> - <单位>」）比只列厂商词更精准：
  // 单位名正是最需要拦住的那部分。
  // 变量名与厂商词一律**拆开拼接**：本扫描器也在扫描范围内，写全就会自我命中——
  // 完整词面只存在于运行时，文件文本里没有。
  const SYNC_KEYS = ['One' + 'Drive', 'One' + 'DriveCommercial', 'One' + 'DriveConsumer', 'Drop' + 'box']
  for (const key of SYNC_KEYS) {
    const value = process.env[key]
    if (!value) continue
    const leaf = value.split(/[\\/]/).filter(Boolean).pop()
    if (leaf) add(`同步根目录名（${key}）`, esc(leaf))
  }

  add(
    '家目录式绝对路径',
    '[A-Za-z]:' + SEP + 'Users' + SEP + '(?!me|<user>|<用户名>)[A-Za-z0-9_.\\-]+',
  )
  add('回环地址带端口', '127\\.0\\.0\\.1:\\d+')
  add('内网 IP', '\\b(?:10|172\\.(?:1[6-9]|2\\d|3[01])|192\\.168)\\.\\d{1,3}\\.\\d{1,3}\\b')
  // 厂商词是公开常识、不指向具体机器，保留它可拦住"只写了厂商名而没写后缀"的情况。
  // 同样拆开拼接，理由见上（避免扫描器自我命中）。
  const VENDORS = ['One' + 'Drive', 'Drop' + 'box', '坚果' + '云', '百度' + '网盘']
  add('云盘 / 中转仓库', VENDORS.join('|'))
  // 规模类计数：会暴露本机资产数量（技能 / 插件 / 仓库各有多少），属于机器事实。
  add('规模类计数', '\\d+\\s*个\\s*(?:技能|插件|仓库)')
  add('工作区根目录', pathVariants(workspaceRoot))
  for (const p of localPatterns) add(`本机专属：${p}`, p)

  return rules
}

const TARGETS = ['src', 'test', 'scripts', 'skill', 'README.md', 'package.json', 'cordis.patch.yml']

function collect(p) {
  if (!existsSync(p)) return []
  if (statSync(p).isFile()) return [p]
  return readdirSync(p).flatMap((entry) => collect(join(p, entry)))
}

const rules = buildRules()
const files = TARGETS.map((t) => join(repoRoot, t)).flatMap(collect)

console.log(
  `[check-leaks] 扫描 ${files.length} 个文件 / ${rules.length} 条规则` +
    `（其中本机专属 ${localPatterns.length} 条）：` +
    TARGETS.filter((t) => existsSync(join(repoRoot, t))).join(', '),
)

let hits = 0
for (const file of files) {
  const text = readFileSync(file, 'utf8')
  for (const rule of rules) {
    const matches = text.match(new RegExp(rule.re.source, 'g'))
    if (!matches) continue
    hits++
    const line = text.slice(0, text.search(rule.re)).split('\n').length
    const sample = [...new Set(matches)].slice(0, 3).join(' / ')
    console.error(
      `  ✗ ${relative(repoRoot, file)}:${line}  [${rule.name}]  ${matches.length} 处：${sample}`,
    )
  }
}

if (hits > 0) {
  console.error(`\n[check-leaks] 发现 ${hits} 类本机指纹命中 —— 发布前必须清除。`)
  process.exit(1)
}
console.log('  ✓ 无本机指纹命中')
