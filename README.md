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

Prerequisite: the `skill-audit` skill (the audit engine) must be installed — this plugin only triggers it and relays the results.

```sh
dsh plugin --profile web add @caesarloo/dsh-skill-audit
```

Restart dsh afterwards (bundle-level change, not hot-reloaded). Verify:

```powershell
dsh --profile web --dump-config | Select-String tool-skill-audit
```

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
| `dsh_config_git_backup` `restore` / `backup` | everything (bulk overwrite / pre-commit check) |
| a shell command rewriting the skills directory | everything |

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
| `auditScript` | `<skillsRoot>/skill-audit/scripts/audit-skills.ps1` | Audit engine script |
| `autoAudit` | `true` | `false` disables automatic audits (the `skill_audit` tool stays available) |
| `powershell` | Windows PowerShell / `pwsh` | PowerShell executable |
| `timeoutMs` | `120000` | Per-audit timeout |
| `maxContextChars` | `2000` | Cap on injected context length |

### Dependencies

`@deepseek-ai/dsh-tools`, `@deepseek-ai/dsh-subprocess` and `@deepseek-ai/dsh-llm` are declared as **optional peerDependencies** and provided by the host; the package bundles none of them. This is deliberate: a second copy inside the profile would create two module instances and break tool registration. `dsh-llm` is used only to build the context message — if it is unavailable, the audit still runs and only the context injection is skipped.

### Boundaries

- Does not implement the audit rules themselves (they live in the `skill-audit` skill);
- Does not rewrite tool input and never blocks a tool call;
- Does not hook non-tool events (`SessionStart` / `Stop`);
- Does not watch the skills directory — it triggers after tool calls only.

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

前置：本机已安装 `skill-audit` 技能（审核引擎在它里面，插件只负责触发与回传）。

```sh
dsh plugin --profile web add @caesarloo/dsh-skill-audit
```

装完**重启 dsh**（插件属于 bundle 层变更，不随热重载生效）。验证：

```powershell
dsh --profile web --dump-config | Select-String tool-skill-audit
```

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
| `dsh_config_git_backup` 的 `restore` / `backup` | **全量**（整批覆盖 / 入库前体检） |
| 用 shell 命令改写技能目录 | **全量** |

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
| `auditScript` | `<skillsRoot>/skill-audit/scripts/audit-skills.ps1` | 审核引擎脚本 |
| `autoAudit` | `true` | `false` 关闭自动审核（`skill_audit` 工具仍可用） |
| `powershell` | Windows PowerShell / `pwsh` | PowerShell 可执行文件 |
| `timeoutMs` | `120000` | 单次审核超时 |
| `maxContextChars` | `2000` | 回传上下文的字符上限 |

### 依赖约定

`@deepseek-ai/dsh-tools`、`@deepseek-ai/dsh-subprocess`、`@deepseek-ai/dsh-llm` 声明为 **optional peerDependencies**，由宿主提供，本包不打包。这是刻意的：它们若与主包各装一份会形成两个模块实例，导致工具注册失败。`dsh-llm` 仅用于构造回传消息，缺失时插件降级为「审核照跑、不注入上下文」。

### 边界（明确不做）

- 不实现审核规则本身（规则在 `skill-audit` 技能里）；
- 不改写工具输入、不阻塞工具调用；
- 不覆盖 `SessionStart` / `Stop` 等非工具事件；
- 不监视技能目录的文件变化（只在工具调用后触发）。

### License

MIT
