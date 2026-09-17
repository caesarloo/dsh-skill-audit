# @caesarloo/dsh-skill-audit

[English](#english) | [中文](#中文)

---

## English

A DeepSeek Harness plugin that **audits your skills the moment they change**: after a skill file is written or edited, or after skills are restored from a backup repository, it runs the skill audit and feeds the findings back to the model. It also registers a `skill_audit` tool for on-demand runs.

### What it does

The audit rules live in the `skill-audit` skill's engine: frontmatter contract (`name` / `description` / `whenToUse` / `version`), script usability (UTF-8 BOM + parseable by Windows PowerShell 5.1), `SKILL.md` reference integrity, credential leakage, machine-specific paths and dangerous command patterns.

- **Automatic** — audits after skill files are written or edited, and after `dsh_config_git_backup`'s `restore` / `backup`;
- **Speaks only when there is something to act on** — findings are injected as context only when `fail` / `warn` exist; a clean run stays silent and just writes a log;
- **Never blocks** — an audit cannot fail your tool call. The file is already written, so surfacing the problem to the model is the right move;
- **On demand** — the `skill_audit` tool.

### Install

```sh
dsh plugin --profile web add @caesarloo/dsh-skill-audit
```

**No prerequisite** — the package ships a fallback copy of the audit engine *and* of the skill itself, so a bare install is enough. If a `skill-audit` skill already exists in your skills root, the plugin uses that one instead.

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

The plugin registers the `skill-audit` skill at runtime **only when no copy exists in your skills root**. That guard is mandatory rather than polite: DSH ranks `project > runtime > user`, and a skills root is the *user* layer — an unconditional runtime registration would **shadow your own skill**, silently replacing the copy you edit.

A registered fallback is given the bundled directory as its resource base, so the relative script paths inside the skill body still resolve.

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

`@deepseek-ai/dsh-tools`, `@deepseek-ai/dsh-subprocess` and `@deepseek-ai/dsh-llm` are declared as **optional peerDependencies** and provided by the host; the package bundles none of them. This is deliberate: a second copy inside the profile would create two module instances and break tool registration. `dsh-llm` is used only to build the context message — if it is unavailable, the audit still runs and only the context injection is skipped. The skills service (`ctx.skills`) is used through a structural type rather than a package import, so registering the fallback skill introduces no further dependency.

### Boundaries

- Contains no audit logic itself: it carries a **snapshot** of the engine and relays its output. The editable source of truth stays in the `skill-audit` skill;
- Does not rewrite tool input and never blocks a tool call;
- Does not hook non-tool events (`SessionStart` / `Stop`);
- Does not watch the skills directory — it triggers after tool calls only.

### Keeping the bundled snapshot in sync (maintainers)

`skill/` is a byte-for-byte snapshot of the author's live `skill-audit` skill. Refresh it before publishing:

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

- **自动** —— 技能文件被写入 / 编辑之后，或 `dsh_config_git_backup` 的 `restore` / `backup` 之后自动审核；
- **有发现才提示** —— 只在存在 `fail` / `warn` 时把结论作为上下文回传给模型；全部通过时保持安静，只写审核日志；
- **不阻塞** —— 审核不会让你的工具调用失败。文件已经写入，把问题摆到模型面前才是正确做法；
- **可主动调用** —— `skill_audit` 工具。

### 安装

```sh
dsh plugin --profile web add @caesarloo/dsh-skill-audit
```

**无前置条件** —— 包内自带审核引擎与技能的回退副本，装上即可用。若你的技能根里已经有 `skill-audit` 技能，插件会**优先用你那份**。

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

插件**只在你的技能根里没有该技能时**才在运行时注册 `skill-audit`。这个保护是硬性要求而非客气：DSH 的层级是 `project > runtime > user`，而技能根属于 **user 层**——无条件注册会**遮蔽你自己的技能**，把你正在编辑的那份悄悄换掉。

注册的回退技能以包内目录作为资源基准（resource base），因此技能正文里的相对脚本路径仍然可解析。

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

`@deepseek-ai/dsh-tools`、`@deepseek-ai/dsh-subprocess`、`@deepseek-ai/dsh-llm` 声明为 **optional peerDependencies**，由宿主提供，本包不打包。这是刻意的：它们若与主包各装一份会形成两个模块实例，导致工具注册失败。`dsh-llm` 仅用于构造回传消息，缺失时插件降级为「审核照跑、不注入上下文」。技能服务（`ctx.skills`）通过**结构化类型**访问而非 import 包，因此注册回退技能不引入任何新依赖。

### 边界（明确不做）

- 本身不含审核逻辑：它携带引擎与技能的**快照**并回传其输出；可编辑的真源始终在 `skill-audit` 技能里；
- 不改写工具输入、不阻塞工具调用；
- 不覆盖 `SessionStart` / `Stop` 等非工具事件；
- 不监视技能目录的文件变化（只在工具调用后触发）。

### 维护内置快照（插件作者）

`skill/` 是作者本机 `skill-audit` 技能的逐字节快照。发布前刷新：

```sh
npm run sync-skill
```

它从 `<DSH_HOME>/skills/skill-audit/` 复制，并在引擎丢掉 UTF-8 BOM 时直接中止（否则 Windows PowerShell 5.1 会把中文注释按 GBK 解码、脚本解析失败）。

### License

MIT
