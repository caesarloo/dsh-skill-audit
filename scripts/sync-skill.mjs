// 把用户态引擎（判据真源）同步进本插件包的 skill/ 目录。
//
// 分层（2026-09-17 定）：包里 skill/ 的两半来源**不同**，本脚本只负责其中一半。
//   · skill/SKILL.md ——**核心流程的真源就在包里**（边界、触发规则、判据表、豁免与扩展点契约）。
//     这部分不常改，随版本发布；作者本机的技能目录只留引擎、**没有 SKILL.md**，所以包内这份
//     是唯一原件，本脚本绝不生成、覆盖或删除它。
//   · skill/scripts/audit-skills.ps1 —— 判据引擎的逐字节副本。引擎是**常改**的真源，住在
//     <DSH_HOME>/skills/skill-audit/scripts/：在那里改判据立即生效、无需重建重发重启，且
//     sync.ps1 的 restore 收尾与手工兜底命令都按普通文件路径找它。本脚本把它的副本放进包里，
//     发布前跑一次：
//
//   npm run sync-skill
//
// 逐字节复制（copyFileSync）：审核引擎必须保住 UTF-8 BOM，否则 Windows PowerShell 5.1
// 会把中文按 GBK 解码而解析失败（skill-audit 技能的 S1 判据）。

import { createHash } from 'node:crypto'
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const dshHome =
  process.env.DSH_HOME ?? join(process.env.USERPROFILE ?? process.env.HOME ?? '.', '.dsh')
const srcSkill = join(dshHome, 'skills', 'skill-audit')
const srcEngine = join(srcSkill, 'scripts', 'audit-skills.ps1')
const dstSkill = join(repoRoot, 'skill')
const dstEngine = join(dstSkill, 'scripts', 'audit-skills.ps1')

if (!existsSync(srcEngine)) {
  console.error(`找不到判据真源：${srcEngine}`)
  console.error('本脚本只在"技能目录里留有引擎"的开发机上运行；包里 skill/scripts/ 是它的副本。')
  process.exit(1)
}
if (!existsSync(join(dstSkill, 'SKILL.md'))) {
  console.error(`包里缺少核心流程真源：${join(dstSkill, 'SKILL.md')}`)
  console.error('它的真源就在包内，不是本脚本生成的——缺失说明仓库本身不完整。')
  process.exit(1)
}

// 真镜像 scripts/：先清空再复制。**只复制不删除是错的**——引擎真源里删掉的脚本会永远留在
// 包里并继续发布出去（2026-09-17 删 hook-post-tool.ps1 时就会踩到）。
rmSync(join(dstSkill, 'scripts'), { recursive: true, force: true })
mkdirSync(dirname(dstEngine), { recursive: true })
copyFileSync(srcEngine, dstEngine)
console.log(`synced   scripts/audit-skills.ps1   sha256=${createHash('sha256').update(readFileSync(dstEngine)).digest('hex').slice(0, 16)}…`)

// 包内 skill/ 只允许这两项。多出来的东西说明有残留，必须显式处理而不是默默发布出去。
const ALLOWED_TOP = new Set(['SKILL.md', 'scripts'])
const extra = readdirSync(dstSkill).filter((entry) => !ALLOWED_TOP.has(entry))
if (extra.length > 0) {
  console.error(`skill/ 下出现预期之外的内容：${extra.join('、')}`)
  console.error('包内 skill/ 只应有 SKILL.md（核心流程真源）与 scripts/audit-skills.ps1（引擎副本）。')
  process.exit(1)
}

// 引擎的 BOM 必须在副本里也成立（否则新机上直接跑不起来）。
const head = readFileSync(dstEngine).subarray(0, 3)
const hasBom = head[0] === 0xef && head[1] === 0xbb && head[2] === 0xbf
if (!hasBom) {
  console.error('副本 audit-skills.ps1 没有 UTF-8 BOM —— 5.1 下会解析失败，已中止。')
  process.exit(1)
}
console.log('verified scripts/audit-skills.ps1  UTF-8 BOM present')

console.log(`\n引擎真源: ${srcEngine}\n包内副本: ${dstEngine}\n（SKILL.md 不动——它本身就是真源）`)
