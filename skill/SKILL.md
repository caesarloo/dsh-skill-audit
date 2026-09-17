---
name: skill-audit
category: quality
description: "DSH 技能的审核通道：以确定性脚本对技能做静态体检——frontmatter 契约、脚本可用性（UTF-8 BOM + PowerShell 5.1 可解析）、SKILL.md 引用完整性、敏感信息与凭据泄漏、机器专属路径、危险命令模式；并提供技能被修改或从 dsh 仓库恢复后自动执行审核的钩子通道（审核结论作为上下文回传给模型）。当技能被新建/修改/从备份恢复、技能里的脚本改过、多机同步技能之后，或需要回答『这个技能是否可用、有没有把密钥写进去、引用的脚本还在不在』时使用。触发词：技能审核、skill audit、审核技能、技能体检、技能改动后检查、恢复技能后检查、技能脚本没BOM、技能引用失效、技能泄漏密钥。"
whenToUse: "技能新增或修改之后（尤其改了 SKILL.md 或技能内脚本）；用 dsh_config_git_backup 从仓库恢复、或手工跑 sync.ps1 -Mode restore 之后；跨机同步技能之后；排查『技能加载了却不管用』（脚本跑不起来、引用文件缺失）时；提交技能进备份仓库之前做入库前体检。"
last_updated: 2026-09-17
version: 1.0.0
created_by: agent
metadata:
  hermes:
    tags: [skill, audit, quality, 技能审核, 静态检查, BOM, frontmatter, 凭据泄漏, 钩子, hooks]
    related_skills: [{local-skill}, {local-skill}, {local-skill}, {local-skill}]
---

# 技能审核（skill-audit）

技能是**给模型看的指令 + 给机器跑的脚本**。它坏掉的方式和插件不同：插件崩了会报错，技能坏掉往往**静默**——frontmatter 写错导致模型根本看不到它、脚本丢了 BOM 导致 5.1 下跑不起来、SKILL.md 引用了已删除的脚本、密钥被顺手写进技能正文随备份进了 git。本技能就是把这些"没人报错的坏"变成**报错的检查**。

## 一、与相邻技能的边界

| 问题 | 归属 |
|---|---|
| 技能是否**可用、自洽、安全**（本技能） | `skill-audit` |
| 插件是否**恶意/可信**（静态评分 + 源码调查 + 健康档案） | `{local-skill}` |
| 插件能否**装配成功**（bundle 装配、registry 可达性、boot 验证） | `{local-skill}` |
| 技能/插件**在多机间怎么搬**（backup/restore、分叉合并） | `{local-skill}` |
| 技能**该不该转成插件** | `{local-skill}` |

一句话：`{local-skill}` 回答"这个插件坏不坏"，`skill-audit` 回答"这个技能能不能用、干不干净"。两者的档案都落仓库 `vet/` 下，互不覆盖。

## 二、自动通道

### 2.0 三层分工（加判据前先看这张表，别放错层）

| 层 | 手里有什么 | 该放什么 | 改动代价 |
|---|---|---|---|
| `~/.dsh/AGENTS.md`（全局指令） | 每次会话**无条件加载** | **写之前**的约定：该怎么写技能、什么时候必须审核 | 立即生效，无需重启 |
| 审核引擎 `scripts/audit-skills.ps1` | 只有**文件系统**（技能目录里的字节） | 一切**静态可判定**的判据（frontmatter、BOM、引用、凭据、危险命令） | 改完即生效；插件与 sync.ps1 同时受益 |
| 审核插件 `@caesarloo/dsh-skill-audit` | **进程内活状态**（已解析的技能目录、触发时机、上下文预算） | 只放**需要活状态**的检查，以及"触发 + 回传"编排 | 要重建 `dist/` + 重装 + 重启 dsh |

**为什么判据不写进插件**：插件刻意不含任何规则（`src/index.ts` 只做 `parseReport` 与格式化回传）。规则若在插件里也存一份，就有了**两个真源**——改 `.ps1` 立即生效、改插件要重建重发重启，两者必然漂移。

**什么才该进插件**：静态层**拿不到**的信息。典型就是"这个技能名到底能不能解析"——技能名可以由插件在运行时注册（磁盘上没有 SKILL.md，如 `@jieai/dsh-plugin-vet` 注册的 `{local-skill}`），`.ps1` 查不到，只有进程内的技能目录知道。F2 因此**刻意不查存在性**（2026-09-17 实测：一上线就误报）。

技能被修改或从仓库恢复后**自动执行**，无需任何人记得去跑。两条通道，分工明确：

### 2.1 主通道：`@caesarloo/dsh-skill-audit` 插件（覆盖"技能被修改"）

插件在 harness 进程内监听 `tools/post-execute`，用 **`ctx.subprocess`（host 层）** 跑本技能的审核脚本，把结论作为上下文回传给模型。

- **触发规则**：**写入类文件工具**（`write`/`edit`/`multi_edit`/`notebook_edit`/`apply_patch` …）命中 `<DSH_HOME>/skills/<技能>/` → 只审该技能；`dsh_config_git_backup` 的 `restore`/`backup` → 全量；`pwsh` 等 shell 的命令行同时含 `skills` 与写操作迹象（`Set-Content`/`Copy-Item`/`Remove-Item`/`robocopy` …）→ 全量；其它 → 静默。**只读工具（`read`/`glob`/`grep`）刻意不触发**——它们同样携带 `file_path` 却不改内容；不加这条白名单，每读一次技能文件就会注入一次审核上下文（2026-09-17 实测后收紧）。
- **审的是新内容**：在 `post-execute`（**写入之后**）执行——对比 `pre-execute` 只能审到旧文件（第三方 `dsh-skill-authoring` 的 pre-execute + 跳过 edit 就是这个缺陷）。
- **上下文分级**：定向单技能（`write`/`edit`）详列 fail + warn；**全量场景**（restore/backup、shell 批量改写）只详列 fail、warn 压成一行汇总（warn 多时逐条列会把上下文挤爆）；**全量且只有 warn 时完全不注入**（背景噪音不打断写入）；全部通过同样保持安静，只写 `~/.dsh/vet/skill-audits/latest.json`（时间戳档保留 40 份）。
- **不阻塞**：任何异常都被吞掉并委托 `next()`，绝不影响工具调用本身。
- **主动调用**：`skill_audit` 工具（不带参数 = 全量；`skill: 'a,b'` = 定向）。
- **源码 / 安装**：独立项目 `dsh-skill-audit`（npm 包 `@caesarloo/dsh-skill-audit`，自建 git 仓库、**不进 dsh 同步面**）；安装 = `dsh plugin --profile web add @caesarloo/dsh-skill-audit`（开发时用 `add <项目目录>` 走 link）。
- **引擎单一真源**：插件不含审核规则，只负责"触发 + 回传"；规则始终在本技能的 `scripts/audit-skills.ps1`。
- **必须重启 dsh 的三种情形**：① 装新 bundle（含本插件首次安装）；② 改 `cordis.patch.yml` 的 `insert` —— `patchReload: live` **不会**把新增条目应用到运行中的进程（2026-09-17 实测：改完 patch 等 10 秒再改技能，钩子依旧未被调用）；③ **改插件源码并重建 `dist/`** —— HMR 不监视 link 项目的 `dist/`（2026-09-17 实测：改完重建、进程仍走旧逻辑，`read` 依旧触发审核）。

> **为什么不用 hooks.json + 钩子桥接（重要，别再走回头路）**：DSH 自带的 `@deepseek-ai/dsh-hooks-claude-code`、以及所有第三方同类 hooks 插件（`dsh-hooks-plugin`、`dsh-plugin-hooks`）都通过 **`ctx.shell`** 执行钩子命令。本机没有可用的沙箱 runner（Windows ACL 后端未挂载）时，执行器**按设计 fail-closed**，命令根本不会启动——会话日志里表现为 `hook/invoked` 有记录、`hook/result` 恒为 `sandbox mode "workspace-write" ... no sandbox backend is usable`（2026-09-17 实测 180 条全部如此）。**此时 hooks.json 配得再对也没用：这不是配置问题，是接缝限制。** 绕开它的唯一办法是走 host 层（`ctx.subprocess`），这正是本插件采用的路线。**钩子入口脚本已于 2026-09-17 删除**（含插件包内快照）：既然这条路线已被证明走不通、host 层插件也已能工作，「沙箱后端将来可用时再复活」的理由就不成立了，留着它等于自相矛盾。本机那份 `~/.dsh/hooks.json`（不入备份仓库）留作**配置形状的记录**；patch 里的桥接条目仍注释停用。脚本本体可从 git 历史 `5ba562c` 取回。

### 2.2 副通道：`sync.ps1` 的 restore 挂点（覆盖"从 dsh 恢复"）

备份仓库里的 `sync.ps1` 在 restore 成功收尾时直接调用 `audit-skills.ps1`（`if ($Mode -eq 'restore' -and -not $DryRun)` 段），覆盖**插件看不到的场景**：不经 dsh 的手工/脚本 restore、以及 `install.ps1` 的新机引导（那时插件通常还没装）。它不改变 sync.ps1 的退出码——还原已经成功，fail 项属于后续修复项。

## 三、手工通道（agent 执行）

钩子只做**确定性静态检查**；下列情况要人（agent）读内容判断：

1. 技能语义是否正确、步骤是否最新（脚本已改但 SKILL.md 没跟上）；
2. 触发词是否覆盖真实说法（模型是否会在对的场景加载它）；
3. 记录是否过期（引用了已卸载的插件、已改名的工具、已废弃的路径）。

```powershell
# 全量体检（人读）
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\skills\skill-audit\scripts\audit-skills.ps1"

# 只审某几个技能
... -Skill {local-skill},{local-skill}

# 机器消费（JSON）
... -Json
```

退出码：`0` 无 fail；`1` 有 fail；`2` 参数/路径错误。

深度审核做完后，把结论落成档案（仓库自有资产，随 git 传播）：

```
<备份仓库>\vet\skill-audits\<技能名>-<yyyyMMdd-HHmmss>.md
```

档案内容：审核时间、静态结论、人工核对的语义项、结论（可用 / 需修 / 建议重写）、遗留风险。

## 四、审核项与判据

| 代码 | 检查 | 级别 | 判据 |
|---|---|---|---|
| F1 | frontmatter 契约 | fail/warn | `name`、`description` 必填；`name` 必须 kebab-case 且与目录名一致；缺 `whenToUse`/`version`/`last_updated` → warn |
| S1 | 脚本可用性 | fail | 技能内每个 `.ps1` 必须 UTF-8 **with BOM**，且 `Parser::ParseFile` 报错数为 0。无 BOM 的中文脚本在 Windows PowerShell 5.1 下按 GBK 解码 → 解析失败（`Missing closing ')'`），**更新过来即不可用**（2026-09-17 {local-skill} 实例） |
| R1 | 引用完整性 | fail/warn | SKILL.md 里 `scripts/xxx.ps1` 这类相对引用必须真实存在。**子目录存在而文件缺失 → fail**（真断裂）；**引用落在同根下的另一个技能里 → warn「跨技能引用」**（应改为点名技能名 + `related_skills`，见 §5.1）；**连子目录都没有 → warn**（运行时生成或外部来源） |
| R2 | 脚本被引用 | info | 技能内脚本未被 SKILL.md 提及（可能是死资产，也可能是刻意留的工具） |
| F2 | 依赖声明 | warn | `metadata.hermes.related_skills` 的**自依赖 / 重复项**。**存在性刻意不查**：技能名可由插件运行时注册（磁盘无 SKILL.md），静态脚本查不到 → 查了必误报（2026-09-17 实测）。悬空声明检测需活的技能目录，属插件侧（§2.0） |
| E1 | 审核扩展 | warn | `audit_extension` 声明的扩展缺失 / 无 BOM / 解析失败 / 执行抛错 → 记在**声明该扩展的技能**上；抛过错的扩展立即停用且只报一次（见 §4.1） |
| M1 | 豁免标记契约 | warn | `audit:ignore` 标记缺代码、或理由不足 8 字符 → 标记不生效并报 M1（防止"随手加个标记消音"） |
| X1 | 敏感信息 | fail | 命中 OpenAI/GitHub/npm/AWS 特征串、私钥块、明文口令或 token 赋值 |
| X2 | 机器专属路径 | info | 硬编码 `C:\Users\<具体用户名>`（通用写法 `$env:USERPROFILE`/`%TEMP%` 不算） |
| X3 | 危险命令 | info | 递归强删、`rm -rf`、`reg delete`、格式化等模式（确认用途，常见于快照清理） |

**为什么 X2/X3 只记 info**：本机技能按约定会写自己的绝对路径（钩子、快照目录），危险命令也确有正当用途（清理恢复快照）。把它们当 fail 会让审核天天报警，最后被无视——**审核一旦有噪音就会失去意义**。

### 4.1 扩展点：由本地其他技能补充审核（`audit_extension`）

核心判据的真源永远是本技能的 `scripts/audit-skills.ps1`；但**本地其他技能可以追加自己的检查**，用来承载领域专属规则（例：某技能要求正文必须维护版本历史表）。声明写在**提供扩展的那个技能**的 frontmatter 里，脚本路径相对该技能目录：

```yaml
metadata:
  hermes:
    audit_extension: "scripts/<扩展脚本名>.ps1"
```

扩展脚本需定义 `Get-SkillAuditFindings`，引擎会对**每个被审技能**调用它一次：

```powershell
function Get-SkillAuditFindings {
    param([string]$SkillName, [string]$SkillDir, [string]$SkillsRoot)
    if ($SkillName -ne 'my-skill') { return @() }
    return @([pscustomobject]@{
        code = 'MY1'; level = 'warn'
        message = '自定义检查未通过'
        file = 'SKILL.md'; target = 'my-skill'
    })
}
```

三条硬约束（均经探针实测）：

1. **只增不减**：扩展只能追加发现，不能移除或降级核心判据——「判据单一真源」不因扩展点而松动，新判据各有各的家。
2. **出错不拖垮审核**：缺文件 / 无 BOM / 解析失败 / 执行抛错 → 记一条 `E1` warn 到**声明它的技能**上，审核照常跑完；抛过错的扩展会被**立即停用且只报一次**（否则一个坏扩展会作用于每个被审技能，把报告刷爆——2026-09-17 探针实测）。
3. **零影响**：没有任何技能声明 `audit_extension` 时本机制完全不参与，行为与引入前一致。

扩展返回的 `level` 只认 `fail` / `warn` / `info`，其它值降级为 `warn`——不允许自造级别绕过 status 判定。扩展产物照常参与豁免（形式与理由要求见 §5.1）。审核输出会标出来源（形如 `MY1 @my-skill`），表头列出本次加载的扩展，JSON 报告含 `extensions` 字段。

## 五、处置流程

1. `fail` **必须修**：S1 用 BOM 安全编辑法补 BOM（见 `{local-skill}` §7.1：`ReadAllText` → `Replace` → `WriteAllText($path,$text,UTF8Encoding($true))`，别让编辑工具剥掉 BOM）；F1 补 frontmatter；R1 改引用或补文件；X1 移出密钥**并轮换**（先轮换再清理，见 `{local-skill}` §六）。
2. `warn` 评估后处理：多为缺元数据，补上即可；确属误报的走下面的豁免标记。
3. 修完重跑审核直到 `fail 0`（warn 也应为 0，否则噪音会掩盖将来真出现的问题）。
4. 技能改动入库：`dsh_config_git_backup(mode=backup)` → `git push`（改动`skills/` 属同步面，两侧必须一致）。

### 5.1 误报处置（先解耦，豁免是最后手段）

R1 的 warn 分支针对的是"引用了**不属于本技能**、或**尚未生成**的文件"。按下面顺序处置：

1. **属于别的技能 → 只写技能名 + 声明依赖**。正文提到对方时只出现技能名（如"见 **{local-skill}** 技能"），并在 frontmatter 的 `metadata.hermes.related_skills` 里登记。**绝不要在正文抄别的技能的内部文件路径**——对方一改脚本名，你的引用就悄悄过期，而且 R1 会为此长期报警（2026-09-17 实测的 6 条 R1 warn 全部属于这一类，已按本原则改写）。**这条已由引擎自动检查**：引用落在同根下别的技能里时，R1 直接报「跨技能引用」并给出修法（§四 R1 行）；反向的悬空声明由 F2 检查。
2. **属于外部来源 / 运行时生成 → 用文字描述，不留路径 token**。例如"本技能目录下的 `references` 缓存（文件名固定 `core.md`）"——描述照旧精确，但不再是一个会被误判成"本技能资产"的引用。
3. **前两条都不适用 → 才用 `audit:ignore` 标记**，就地写明例外与理由：

```markdown
<!-- audit:ignore R1 references/<文件名>.md 该文件属于 xxx 技能 / 由某 CLI 运行时生成，非本技能资产 -->
```

（示例刻意用占位符写：R1 对含 `xxx`、`<…>` 的 token 主动跳过，所以这段示例不会自己制造 warn。）

- **形式**：`<!-- audit:ignore <代码> <目标> <理由> -->`；代码为 `F1/S1/R1/X1/X2/X3` 之一，或 `*`（全部）。
- **目标**：`R1` 填相对引用（如 `references/xxx.md`，斜杠两种写法等价）；**其它代码**填文件名（`SKILL.md` 或脚本名）。
- **`fail` 级不可豁免**：§五「fail 必须修」是硬线，标记只用来消解 `warn`/`info` 的误报。引擎里 `Test-Waived` 对 fail 直接返回 false——否则"真断裂仍是 fail"这条保证会被一个标记悄悄绕过（2026-09-17 用探针实测：真断裂挂上有效标记仍报 fail）。
- **理由不足 8 字符**（或缺代码）→ 标记**不生效**并报 `M1`，避免随手消音。
- **为什么不是"放宽脚本"**：放宽会同时放过所有技能；豁免标记是**逐条、带理由、随技能进 git 可审计**的，正好落实"例外被显式记录"。这也是本节此前的缺口——早就要求"写明例外与理由"，但写了并不生效，规则与实现脱节，结果只剩两条歪路：忍受常驻噪音（久了审核被无视），或改写措辞回避正则（那是掩盖检测，更糟）。豁免标记把"写明例外"变成可执行的正解。

> **⚠️ 反例一：新建空目录消 warn（会自伤）**。为了消掉 R1 的 warn 而**新建空的 `scripts/`、`references/` 目录**或放个 `.gitkeep`，会命中 R1 的第二分支"子目录存在但文件缺失"，把 warn **直接升级成 fail**（2026-09-17 实测：`references/` 一建，`fail=0` → `fail=1`）。空目录不是豁免。
>
> **⚠️ 反例二：改写措辞回避正则**。把 `references/xxx.md` 这类真实引用改写成"references 子目录下的 xxx.md"确实能让正则不匹配，但那是**掩盖检测**——文本变含糊，且将来真断裂也一起被藏起来。判据存在的意义是发现断裂，不是让文本绕过它。
>
> （自查约定：本文件正文举例一律用 `xxx` / `<名>` 占位符——R1 对这些占位符**主动跳过**，所以文档里的示例不会自己制造 warn；真实引用才写全路径。）

## 六、脚本资产

| 脚本 | 用途 | 主要参数 |
|---|---|---|
| `scripts/audit-skills.ps1` | 静态审核引擎（本技能唯一的判据真源，插件与 sync.ps1 都调它） | `-Skill <名,...>`、`-SkillsRoot <目录>`、`-Json`、`-NoLog` |

两个脚本都必须带 UTF-8 BOM（由 `powershell` 5.1 执行且含中文）。审核引擎另在开头把 `[Console]::OutputEncoding` 设为 UTF-8——否则 5.1 按控制台代码页（GBK）写 stdout，插件侧 Node 按 UTF-8 解码就是乱码（2026-09-17 实测踩坑）。

自动触发的**实现**不在本技能目录里（避免与 dsh 同步面耦合）：它是独立项目 `dsh-skill-audit`（npm `@caesarloo/dsh-skill-audit`），含源码、冒烟测试与 README。

## 七、故障排查

| 症状 | 原因 / 处理 |
|---|---|
| 改了技能但没收到审核上下文 | ① 通过时**本来就不输出**（只看 `~/.dsh/vet/skill-audits/latest.json`）；② 路径没落在 `skills\<技能>\` 下（改技能内的脚本同样命中；改技能外的文件不命中）；③ 插件未装或**装/改 patch 后没重启 dsh** |
| 插件到底有没有被装载 | `dsh --profile web --dump-config \| Select-String tool-skill-audit`；没有条目就是没装/没装配 |
| 审核结论中文乱码 | 引擎已显式设 `[Console]::OutputEncoding = UTF8`；若仍有乱码，检查是否用了旧版脚本（该行是 2026-09-17 加的） |
| 审核脚本跑不起来（BOM/语法） | `audit-skills.ps1` 自己的 BOM 被编辑工具剥了——用 §五 的 BOM 安全编辑法补回 |
| `skill_audit` 工具报"审核脚本不存在" | 引擎路径不对：插件默认找 `<DSH_HOME>/skills/skill-audit/scripts/audit-skills.ps1`，可用 patch 的 `auditScript` 覆盖 |
| 想审的技能不在默认根 | 用 `-SkillsRoot`（手工）或插件的 `skillsRoot` 配置（项目级技能在 `<项目>/.dsh/skills`，不是用户根） |
| 又想去用 hooks.json | **别走回头路**：钩子桥接与所有第三方同类 hooks 插件都走 `ctx.shell`，本机沙箱 runner 不可用时会以 `SANDBOX_UNAVAILABLE` 拒绝执行（详见 §2.1 的说明与实测） |
