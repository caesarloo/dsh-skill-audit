// 把用户态 skill-audit 技能（规则真源）快照进本插件包的 skill/ 目录。
//
// 为什么需要它：插件要"装上就能用"，就必须自带一份回退技能与引擎（否则新用户拿不到那个
// 前置技能——它没有任何分发渠道）。但规则的**真源**始终是用户态技能
// <DSH_HOME>/skills/skill-audit/：在那里改判据立即生效、无需重建重发重启，且
// sync.ps1 的 restore 收尾与手工兜底命令都按普通文件路径找它。三层的分工见
// skill-audit 技能 §2.0。本脚本负责"把真源快照进包里"，发布前跑一次：
//
//   npm run sync-skill
//
// 逐字节复制（copyFileSync）：审核引擎必须保住 UTF-8 BOM，否则 Windows PowerShell 5.1
// 会把中文按 GBK 解码而解析失败（skill-audit §五 的 S1 判据）。

import { createHash } from 'node:crypto'
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const dshHome =
  process.env.DSH_HOME ?? join(process.env.USERPROFILE ?? process.env.HOME ?? '.', '.dsh')
const srcSkill = join(dshHome, 'skills', 'skill-audit')
const dstSkill = join(repoRoot, 'skill')

if (!existsSync(join(srcSkill, 'SKILL.md'))) {
  console.error(`找不到真源技能：${srcSkill}`)
  console.error('本脚本只在"装有用户态 skill-audit 技能"的开发机上运行；包里 skill/ 是它的快照。')
  process.exit(1)
}

/** 递归收集技能内的文件（排除运行期产物）。 */
function collect(dir) {
  const out = []
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules' || entry === '.git') continue
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) out.push(...collect(full))
    else out.push(full)
  }
  return out
}

const sha256 = (p) => createHash('sha256').update(readFileSync(p)).digest('hex')
const files = collect(srcSkill)

// 真镜像：先清空快照目录再复制。**只复制不删除是错的**——真源里删掉的文件会永远留在包里
// 并继续发布出去（2026-09-17 删 hook-post-tool.ps1 时就会踩到）。
rmSync(dstSkill, { recursive: true, force: true })
mkdirSync(dstSkill, { recursive: true })

let copied = 0
for (const from of files) {
  const rel = relative(srcSkill, from)
  const to = join(dstSkill, rel)
  mkdirSync(dirname(to), { recursive: true })
  copyFileSync(from, to)
  console.log(`synced  ${rel.padEnd(34)} sha256=${sha256(to).slice(0, 16)}…`)
  copied++
}

// 引擎的 BOM 必须在快照里也成立（否则回退副本在 5.1 下直接跑不起来）。
const engine = join(dstSkill, 'scripts', 'audit-skills.ps1')
if (existsSync(engine)) {
  const head = readFileSync(engine).subarray(0, 3)
  const hasBom = head[0] === 0xef && head[1] === 0xbb && head[2] === 0xbf
  if (!hasBom) {
    console.error('快照里的 audit-skills.ps1 没有 UTF-8 BOM —— 5.1 下会解析失败，已中止。')
    process.exit(1)
  }
  console.log('verified  scripts/audit-skills.ps1  UTF-8 BOM present')
}

console.log(`\n${copied} 个文件\n真源: ${srcSkill}\n快照: ${dstSkill}`)
