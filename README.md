# @caesarloo/dsh-skill-audit

[English](#english) | [中文](#中文)

---

## English

A DeepSeek Harness plugin that **audits your skills the moment they change**: after a skill file is written or edited, or after skills are restored from a backup repository, it runs the skill audit and feeds the findings back to the model. It also registers a `skill_audit` tool for on-demand runs.

### What it does

The audit rules live in the `skill-audit` skill's engine: frontmatter contract (`name` / `description` / `whenToUse` / `version`), script usability (UTF-8 BOM + parseable by Windows PowerShell 5.1), `SKILL.md` reference integrity, credential leakage, machine-specific paths and dangerous command patterns.

- **Automatic** — audits after skill files are written or edited, and after a bulk restore / backup (any tool invoked with `mode: 'restore'` or `mode: 'backup'`);
- **Speaks only when there is something to act on** — findings are injected as context only when `fail` / `warn` exist; a clean run stays silent and just writes a log;
- **Never blocks** — an audit cannot fail your tool call. The file is already written, so surfacing the problem to the model is the right move;
- **On demand** — the `skill_audit` tool.

### Install

```sh
dsh plugin --profile web add @caesarloo/dsh-skill-audit
```

**No prerequisite** — the package ships the audit engine *and* the skill body, so a bare install is enough. If your skills root already holds a full `skill-audit` skill, the plugin leaves it alone and uses that one instead.

Restart dsh afterwards (bundle-level change, not hot-reloaded). Verify:

```powershell
dsh --profile web --dump-config | Select-String tool-skill-audit
```

### Engine resolution

| # | Source | Path | Notes |
|---|---|---|---|
| 1 | `config.auditScript` | whatever you set | Explicit. **If it is set but missing this is an error** — the plugin will not silently run a different engine. |
| 2 | your own skill | `<skillsRoot>/skill-audit/scripts/audit-skills.ps1` | Preferred when present: it is the editable working copy, so a rule change takes effect on the next audit with no rebuild. |
| 3 | bundled snapshot | `<package>/skill/scripts/audit-skills.ps1` | Fallback that makes a bare install work. |

The plugin registers the `skill-audit` skill at runtime **unless your skills root already holds a full copy (i.e. a `SKILL.md`)**. That guard is mandatory rather than polite: DSH ranks `project > runtime > user`, and a skills root is the *user* layer (`source: 'user-dsh'`) — an unconditional runtime registration would **shadow your own skill**.

The same guard draws the line between stable and evolving content:

| Content | Lives in | Cost of a change |
|---|---|---|
| Core flow — boundaries, trigger rules, finding table, waiver & extension contracts | the package (registered at runtime) | rebuild + republish |
| The audit **engine** — `<skillsRoot>/skill-audit/scripts/audit-skills.ps1` | your skills root, with **no `SKILL.md`**: it is the engine's home, not a skill | none — live on the next audit |
| **Machine-specific rules** — an `audit_extension` declared by a local skill | your skills root | none — live on the next audit |

So a bare install gets the whole core flow, while everything you actually keep editing stays on your side, editable without a rebuild or a restart.

A registered skill is given the bundled directory as its resource base, so the relative script paths inside the skill body still resolve.

### Usage

Nothing to do after installing — audits run automatically whenever you change skills. To re-check on demand:

```
skill_audit()                    # audit every skill
skill_audit({ skill: 'a,b' })    # audit specific skills (comma separated)
```

Trigger scope:

| Your action | Audit scope |
|---|---|
| `write` / `edit` on a skill file | that skill only (fast) |
| any tool invoked with `mode: 'restore'` or `mode: 'backup'` | everything (bulk overwrite / pre-commit check) |
| a shell command rewriting the skills directory | everything |

Bulk detection keys on the **call shape**, not on a tool name — so the plugin works with any backup plugin, and with none. If yours names its mode argument differently, list its tool name in `fullAuditTools`.

Reporting is tiered by scenario:

- single-skill edit → lists `fail` and `warn` in detail;
- bulk scope → lists only `fail`, with `warn` collapsed into one summary line;
- bulk scope with no `fail` → **completely silent** (background noise should not interrupt you).

Logs go to `<DSH_HOME>/vet/skill-audits/` (`latest.json` plus timestamped files, last 40 kept).

### Configuration

Usually none. To customize, add `config` to the entry in the profile's `cordis.patch.yml`:

| Key | Default | Meaning |
|---|---|---|
| `skillsRoot` | `<DSH_HOME>/skills` | Skills root directory |
| `auditScript` | auto: your skill → bundled snapshot | Audit engine script; set it to pin one (a missing explicit path is an error) |
| `autoAudit` | `true` | `false` disables automatic audits (the `skill_audit` tool stays available) |
| `powershell` | Windows PowerShell / `pwsh` | PowerShell executable |
| `timeoutMs` | `120000` | Per-audit timeout |
| `maxContextChars` | `2000` | Cap on injected context length |
| `fullAuditTools` | `[]` | Extra tool names to treat as bulk rewrites of the skills tree. Usually unnecessary: the generic rule already covers calls whose `mode` is `restore` or `backup`. |

### Dependencies

`@deepseek-ai/dsh-tools`, `@deepseek-ai/dsh-subprocess` and `@deepseek-ai/dsh-llm` are declared as **optional peerDependencies** and provided by the host; the package bundles none of them. This is deliberate: a second copy inside the profile would create two module instances and break tool registration. `dsh-llm` is used only to build the context message — if it is unavailable, the audit still runs and only the context injection is skipped. The skills service (`ctx.skills`) is used through a structural type rather than a package import, so registering the skill introduces no further dependency.

### Boundaries

- Contains no audit logic itself: it carries the skill body and the engine as **copies** and relays the engine's output. There are two editable sources of truth — the engine in your skills root, and machine-specific rules in a local skill's `audit_extension`;
- Does not rewrite tool input and never blocks a tool call;
- Does not hook non-tool events (`SessionStart` / `Stop`);
- Does not watch the skills directory — it triggers after tool calls only.

### Keeping the bundled snapshot in sync (maintainers)

The two halves of `skill/` have **different origins**: `SKILL.md` is *the* source of truth for the core flow (the author's skills root keeps only the engine, with no `SKILL.md`, so the bundled copy is the one original), while `scripts/audit-skills.ps1` is a byte-for-byte copy of the author's live engine and must be refreshed before publishing:

```sh
npm run sync-skill
```

It copies from `<DSH_HOME>/skills/skill-audit/` and aborts if the engine lost its UTF-8 BOM (Windows PowerShell 5.1 would then mis-decode the Chinese comments and fail to parse the script).

### License

MIT

---

## 中文

让 **DSH 技能一改就自动被审核** 的插件：技能文件被改动、或技能从备份仓库恢复之后，自动跑一遍技能审核，并把结论回传给模型；另提供 `skill_audit` 工具供随时复验。

### 功能

审核规则由 `skill-audit` 技能的引擎执行，包含：frontmatter 契约（`name` / `description` / `whenToUse` / `version`）、技能内脚本的可用性（UTF-8 BOM + Windows PowerShell 5.1 可解析）、`SKILL.md` 引用完整性、凭据泄漏、机器专属路径与危险命令模式。

- **自动** —— 技能文件被写入 / 编辑之后，或任何整批 restore / backup（以 `mode: 'restore'` 或 `mode: 'backup'` 调用的工具）之后自动审核；
- **有发现才提示** —— 只在存在 `fail` / `warn` 时把结论作为上下文回传给模型；全部通过时保持安静，只写审核日志；
- **不阻塞** —— 审核不会让你的工具调用失败。文件已经写入，把问题摆到模型面前才是正确做法；
- **可主动调用** —— `skill_audit` 工具。

### 安装

```sh
dsh plugin --profile web add @caesarloo/dsh-skill-audit
```

**无前置条件** —— 包内自带审核引擎与技能正文，装上即可用。若你的技能根里已有完整的 `skill-audit` 技能，插件不打扰它、直接用你那份。

装完**重启 dsh**（插件属于 bundle 层变更，不随热重载生效）。验证：

```powershell
dsh --profile web --dump-config | Select-String tool-skill-audit
```

### 引擎解析顺序

| 优先级 | 来源 | 路径 | 说明 |
|---|---|---|---|
| 1 | `config.auditScript` | 你指定的路径 | 显式指定。**指定了却不存在会直接报错**——不会偷偷换一个引擎跑。 |
| 2 | 你自己的技能 | `<skillsRoot>/skill-audit/scripts/audit-skills.ps1` | 存在时优先。这是**可编辑的工作副本**：改判据下一次审核即生效，无需重建。 |
| 3 | 包内快照 | `<package>/skill/scripts/audit-skills.ps1` | 回退副本，保证"装上就能用"。 |

插件**只在你的技能根里还没有完整副本（即没有 `SKILL.md`）时**才在运行时注册 `skill-audit`。这个保护是硬性要求而非客气：DSH 的层级是 `project > runtime > user`，而技能根属于 **user 层**（`source: 'user-dsh'`）——无条件注册会**遮蔽你自己的技能**。

同一条判定也是「稳定」与「常改」的分界线：

| 内容 | 住在哪 | 改一次的代价 |
|---|---|---|
| 核心流程——边界、触发规则、判据表、豁免与扩展点契约 | 包内（运行时注册） | 重建 + 重发 |
| 审核**引擎**——`<skillsRoot>/skill-audit/scripts/audit-skills.ps1` | 你的技能根，**没有 `SKILL.md`**：它是引擎的家，不是技能 | 无——下一次审核即生效 |
| **机器专属规则**——某个本机技能声明的 `audit_extension` | 你的技能根 | 无——下一次审核即生效 |

所以裸装即可拿到完整核心流程，而你真正会反复改的部分全都留在自己手里，不必重建、不必重启。

注册的技能以包内目录作为资源基准（resource base），因此技能正文里的相对脚本路径仍然可解析。

### 使用

装好之后**无需任何操作**——改动技能时会自动审核。需要主动复验时调用工具：

```
skill_audit()                    # 审核全部技能
skill_audit({ skill: 'a,b' })    # 只审指定技能（逗号分隔）
```

自动审核的触发范围：

| 你的操作 | 审核范围 |
|---|---|
| 用 `write` / `edit` 改某个技能的文件 | 只审**该技能**（快） |
| 任何以 `mode: 'restore'` 或 `mode: 'backup'` 调用的工具 | **全量**（整批覆盖 / 入库前体检） |
| 用 shell 命令改写技能目录 | **全量** |

「整批改写」判定的是**调用形态**而不是工具名——所以本插件配合任何备份插件都能工作，没有也不影响。若你所用工具的模式参数不叫 `mode`，把它的工具名列进 `fullAuditTools` 即可。

提示强度按场景分级：

- 定向单技能改动 → 详列 `fail` 与 `warn`；
- 全量场景 → 只详列 `fail`，`warn` 压成一行汇总；
- 全量且只有 `warn` → **完全不提示**（背景噪音不打断你的操作）。

审核日志写在 `<DSH_HOME>/vet/skill-audits/`（`latest.json` 加时间戳档，保留最近 40 份）。

### 配置

一般无需配置。需要定制时在 profile 的 `cordis.patch.yml` 里给该条目加 `config`：

| 配置键 | 缺省值 | 含义 |
|---|---|---|
| `skillsRoot` | `<DSH_HOME>/skills` | 技能根目录 |
| `auditScript` | 自动：用户态技能 → 包内快照 | 审核引擎脚本；显式指定可钉住（指定却不存在会报错） |
| `autoAudit` | `true` | `false` 关闭自动审核（`skill_audit` 工具仍可用） |
| `powershell` | Windows PowerShell / `pwsh` | PowerShell 可执行文件 |
| `timeoutMs` | `120000` | 单次审核超时 |
| `maxContextChars` | `2000` | 回传上下文的字符上限 |
| `fullAuditTools` | `[]` | 额外视为「整批改写技能目录」的工具名。通常不需要：通用规则已覆盖 `mode` 为 `restore` / `backup` 的调用。 |

### 依赖约定

`@deepseek-ai/dsh-tools`、`@deepseek-ai/dsh-subprocess`、`@deepseek-ai/dsh-llm` 声明为 **optional peerDependencies**，由宿主提供，本包不打包。这是刻意的：它们若与主包各装一份会形成两个模块实例，导致工具注册失败。`dsh-llm` 仅用于构造回传消息，缺失时插件降级为「审核照跑、不注入上下文」。技能服务（`ctx.skills`）通过**结构化类型**访问而非 import 包，因此注册技能不引入任何新依赖。

### 边界（明确不做）

- 本身不含审核逻辑：它携带技能正文与引擎的**副本**并回传其输出；可编辑的真源有两处——判据引擎在你的技能根，机器专属规则在本机技能的 `audit_extension`；
- 不改写工具输入、不阻塞工具调用；
- 不覆盖 `SessionStart` / `Stop` 等非工具事件；
- 不监视技能目录的文件变化（只在工具调用后触发）。

### 维护内置快照（插件作者）

`skill/` 里两部分的来源**不同**：`SKILL.md` 是**核心流程的真源**（作者本机的技能目录只留引擎、没有 SKILL.md，所以包内这份就是唯一原件）；`scripts/audit-skills.ps1` 是作者本机引擎的逐字节副本，发布前需刷新：

```sh
npm run sync-skill
```

它从 `<DSH_HOME>/skills/skill-audit/` 复制，并在引擎丢掉 UTF-8 BOM 时直接中止（否则 Windows PowerShell 5.1 会把中文注释按 GBK 解码、脚本解析失败）。

### License

MIT
