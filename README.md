# @caesarloo/dsh-skill-audit

让 **DSH 技能一改就自动被审核** 的插件：技能文件被改动、或技能从备份仓库恢复之后，自动跑一遍技能审核，并把结论回传给模型；另提供 `skill_audit` 工具供随时复验。

## 它做什么

审核内容由 `skill-audit` 技能的引擎执行，包含：frontmatter 契约（`name`/`description`/`whenToUse`/`version`）、技能内脚本的可用性（UTF-8 BOM + PowerShell 5.1 可解析）、`SKILL.md` 引用完整性、凭据泄漏、机器专属路径与危险命令模式。

- **自动**：技能被写入/编辑、或 `dsh_config_git_backup` 的 `restore`/`backup` 之后自动审核；
- **有发现才提示**：只在存在 `fail`/`warn` 时把结论作为上下文回传给模型；全部通过时保持安静，只写审核日志；
- **不阻塞**：审核不会让工具调用失败——文件已经写入，把问题摆到模型面前才是正确做法；
- **可主动调用**：`skill_audit` 工具。

## 安装

前置：本机已安装 `skill-audit` 技能（审核引擎在它里面，插件只负责触发与回传）。

```sh
dsh plugin --profile web add @caesarloo/dsh-skill-audit
```

装完**重启 dsh**（插件属于 bundle 层变更，不随热重载生效）。验证：

```powershell
dsh --profile web --dump-config | Select-String tool-skill-audit
```

## 使用

装好之后**无需任何操作**——改动技能时自动审核。需要主动复验时调用工具：

```
skill_audit()                    # 审核全部技能
skill_audit({ skill: 'a,b' })    # 只审指定技能（逗号分隔）
```

自动审核的触发范围：

| 你的操作 | 审核范围 |
|---|---|
| 用 `write` / `edit` 改某个技能的文件 | 只审**该技能**（快） |
| `dsh_config_git_backup` 的 `restore` / `backup` | **全量**（整批覆盖 / 入库前体检） |
| 用 shell 命令改写技能目录（命令行同时含 `skills` 与写操作） | **全量** |

提示强度是按场景分级的：

- 定向单技能改动 → 详列 `fail` 与 `warn`；
- 全量场景 → 只详列 `fail`，`warn` 压成一行汇总；
- 全量且只有 `warn` → **完全不提示**（背景噪音不打断你的操作）。

审核日志写在 `<DSH_HOME>/vet/skill-audits/`（`latest.json` 加时间戳档，保留最近 40 份）。

## 配置

一般无需配置。需要定制时在 profile 的 `cordis.patch.yml` 里给该条目加 `config`：

```yaml
- id: tool-skill-audit
  config:
    skillsRoot: '<技能根目录>'        # 缺省 <DSH_HOME>/skills
    auditScript: '<审核脚本路径>'      # 缺省 <skillsRoot>/skill-audit/scripts/audit-skills.ps1
    autoAudit: true                   # false = 关闭自动审核，只保留 skill_audit 工具
    powershell: '<PowerShell 路径>'    # 缺省 Windows 内置 powershell，其它平台 pwsh
    timeoutMs: 120000                 # 单次审核超时
    maxContextChars: 2000             # 回传上下文的字符上限
```

## 依赖约定

`@deepseek-ai/dsh-tools`、`@deepseek-ai/dsh-subprocess`、`@deepseek-ai/dsh-llm` 声明为 **optional peerDependencies**，由宿主提供，本包不打包。这是刻意的：它们若与主包各装一份会形成两个模块实例，导致工具注册失败。`dsh-llm` 仅用于构造回传消息，缺失时插件降级为"审核照跑、不注入上下文"。

## 边界（明确不做）

- 不实现审核规则本身（规则在 `skill-audit` 技能里）；
- 不改写工具输入、不阻塞工具调用；
- 不覆盖 `SessionStart` / `Stop` 等非工具事件；
- 不监视技能目录的文件变化（只在工具调用后触发）。

## License

MIT
