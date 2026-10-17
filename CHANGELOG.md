# Changelog

All notable changes to this package are documented in this file.
本文件记录本包的重要变更。

## [0.2.8] - 2026-10-17

**DSH 0.2.1 compatibility declaration / DSH 0.2.1 兼容声明**

- Declare `engines.dsh` (`>=0.2.0-rc.2 <0.3.0`) and `dsh.manifestVersion: 1`. Since DSH 0.2.1 the
  host decides plugin compatibility by `engines.dsh` **first** and ignores `peerDependencies` when
  it is declared; the plugin manager reads the same fields before installing and refuses an
  unsatisfied package with `incompatible-version`. Declaring the range makes the accepted host line
  explicit instead of relying on pre-release matching of peer ranges; `manifestVersion: 1` declares
  the package-metadata format.
- No source changes were required for DSH 0.2.1-rc.2 (verified on the 0.2.1-rc.2 desktop host):
  `skill_audit` runs (29 skills, `fail 0 / warn 0`); the `tools/post-execute` auto-trigger still
  fires after a skill write and injects findings as context; `ctx.skills.register` still exposes the
  bundled skill; the `ctx.subprocess.spawn` → `handle.done` → `collected.*.readFrom(0).text` chain is
  unchanged; and `createUserMessage` with `source.kind: 'plugin:tool-skill-audit'` still satisfies
  the session-format-v4 producer-owned source-kind rule.
- 声明 `engines.dsh`（`>=0.2.0-rc.2 <0.3.0`）与 `dsh.manifestVersion: 1`。DSH 0.2.1 起宿主**优先按
  `engines.dsh` 判定**插件兼容性，声明了该字段就忽略 `peerDependencies`；插件管理器在安装前也读
  这两个字段，不满足时报 `incompatible-version`。把可接受的宿主线显式化，不再依赖 peer 范围的
  「预发布参与匹配」语义；`manifestVersion: 1` 声明包元数据格式。
- 0.2.1-rc.2 下**无需改动代码**（已在桌面端 0.2.1-rc.2 实测）：`skill_audit` 正常（29 技能
  `fail 0 / warn 0`）；技能写入后 `tools/post-execute` 自动触发仍生效并把结论注入上下文；
  `ctx.skills.register` 仍能注册包内技能；`ctx.subprocess.spawn` → `handle.done` →
  `collected.*.readFrom(0).text` 链路不变；`createUserMessage` 配合
  `source.kind: 'plugin:tool-skill-audit'` 仍满足会话格式 v4 的 producer-owned source kind 规则。

## [0.2.7] - 2026-10-02

**New criterion F3: YAML escapes in frontmatter / 新增判据 F3：frontmatter 的 YAML 转义**

- New static criterion `F3`: inside **double-quoted** YAML scalars of `SKILL.md` frontmatter, an
  illegal backslash escape (e.g. `\w`, `\l`, `\d`) is reported as **fail**, and a legal but
  control-class escape (`\f`, `\t`, `\n`, `\r`, `\b`, `\v`, `\0`, `\a`, `\e`, `\N`, `\_`, `\L`, `\P`)
  as **warn**. The host registers skills with a strict YAML parser, so an illegal escape makes the
  whole skill fail to register **silently** — no error, no log, it simply disappears from the
  runtime skill catalog. Two skills on the author's machine had vanished this way while the audit
  still reported `fail 0 / warn 0`. Single-quoted and plain scalars are deliberately not scanned
  (a backslash there is a literal). Literal backslashes must be written `\\`.
- `skill/SKILL.md`: criteria table gains the F3 row and the `audit:ignore` code list is completed
  (`F2/F3/R2/E1/M1`). Skill document version `1.1.2 → 1.1.3`.
- 新增静态判据 `F3`：`SKILL.md` frontmatter 的**双引号标量**内，非法反斜杠转义（如 `\w`、`\l`、`\d`）
  报 **fail**；合法但属控制类的转义（`\f`、`\t`、`\n`、`\r`、`\b`、`\v`、`\0`、`\a`、`\e`、`\N`、`\_`、`\L`、`\P`）
  报 **warn**。宿主用严格 YAML 解析器注册技能，非法转义会让整条技能**静默注册失败**——不报错、不留日志，
  直接从运行时技能目录里消失（作者机器上曾有两个技能这样失效，而当时审核报的是 `fail 0 / warn 0`）。
  单引号串与裸标量刻意不扫（其中反斜杠是字面字符）。字面反斜杠应写 `\\`。
- `skill/SKILL.md`：判据表新增 F3 行、`audit:ignore` 的代码列表补全（`F2/F3/R2/E1/M1`）；
  技能正文版本 `1.1.2 → 1.1.3`。

## [0.2.6] - 2026-09-30

**DSH 0.2.0 compatibility / DSH 0.2.0 兼容**

- Peer range moved to the 0.2.0 host line: `@deepseek-ai/dsh-llm`, `@deepseek-ai/dsh-subprocess`
  and `@deepseek-ai/dsh-tools` are now declared as `^0.2.0-rc.2` (previously `^0.1.5-rc.2`).
- devDependencies aligned with the same line, and `@deepseek-ai/cordis` pinned to `~4.0.4`.
- 适配 DSH 0.2.0：宿主自 0.2.0 起会拒绝装配 peer 不兼容的插件（启动时报 `skipping profile bundle`）。
  本次把 `@deepseek-ai/dsh-llm`、`@deepseek-ai/dsh-subprocess`、`@deepseek-ai/dsh-tools` 的 peer 范围
  收敛到 `^0.2.0-rc.2`，devDependencies 同步，`@deepseek-ai/cordis` 对齐 `~4.0.4`。
- No source changes were required: `defineTool`, `ctx.tools.register`, `ctx.subprocess.spawn`,
  the `tools/post-execute` decision shape (`additionalContexts`), `ctx.skills.register`, and the
  producer-owned `createUserMessage` source kind (`plugin:tool-skill-audit`) all match the 0.2.0 host.
- 代码无需改动：`defineTool`、`ctx.tools.register`、`ctx.subprocess.spawn`、`tools/post-execute`
  的 `additionalContexts`、`ctx.skills.register`，以及生产者自有 kind（`plugin:tool-skill-audit`）
  均与 0.2.0 一致。
