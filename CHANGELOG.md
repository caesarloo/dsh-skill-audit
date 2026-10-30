# Changelog

All notable changes to this package are documented in this file.
本文件记录本包的重要变更。

## [0.2.10] - 2026-10-30

**Fix the self-triggered leak gate and build before tests / 修掉自身泄漏闸门误报，测试前先构建**

- The F3 note in `skill/scripts/audit-skills.ps1` used `%TEMP%\finmeta2026` as its YAML-escape example. That word is a
  machine-specific temp-directory convention (it matches the local-only rule in `.leak-patterns.local`), so the package's
  own `check-leaks` flagged itself: `npm test` and `prepublishOnly` were both blocked. The example is now the neutral
  `%TEMP%\foo` (still demonstrating that `\f` becomes a form feed); the rule logic is unchanged.
- Added `pretest: npm run build`, so `npm test` exercises the freshly built `dist/` instead of a possibly stale one.
- Re-verified on the DSH **0.2.1-rc.5** desktop host (2026-10-30): `skill_audit` passes the whole skill set (47 skills,
  `fail 0 / warn 0`); the `tools/post-execute` auto-trigger, `ctx.subprocess.spawn` → handle chain,
  `ctx.skills.register` and `createUserMessage` behave as before. The plugin-facing contract surface is byte-identical
  between 0.2.1-rc.3 and rc.5, so this release carries no runtime change.

- `skill/scripts/audit-skills.ps1` 的 F3 说明里，YAML 转义示例原本写成 `%TEMP%\finmeta2026`。该词是本机临时目录
  约定名（命中 `.leak-patterns.local` 的本机专属规则），于是本包**自己审出自己**：`check-leaks` 报命中、`npm test`
  与 `prepublishOnly` 双双被拦。现改为中性示例 `%TEMP%\foo`（仍演示 `\f` 变成换页符），判据逻辑不变。
- 新增 `pretest: npm run build`：`npm test` 现在测的是刚构建的 `dist/`，避免"改了 src 没重建、测的是旧产物"。
- 已在 DSH **0.2.1-rc.5** 桌面端复验（2026-10-30）：`skill_audit` 全量 47 个技能 `fail 0 / warn 0`；
  `tools/post-execute` 自动触发、`ctx.subprocess.spawn` → handle 链路、`ctx.skills.register`、`createUserMessage`
  均与复验时一致；0.2.1-rc.3 → rc.5 之间插件契约面逐字节零变化，本版无运行时功能变更。

## [0.2.9] - 2026-10-24

**DSH 0.2.1-rc.3 re-verification / DSH 0.2.1-rc.3 复验**

- Re-verified on the DSH 0.2.1-rc.3 desktop host: **no code changes were required**. `skill_audit`
  passes the whole skill set (43 skills, `fail 0 / warn 0`); the `tools/post-execute` auto-trigger
  still fires after skill writes and injects findings as context; `ctx.skills.register` still
  registers the bundled skill; the `ctx.subprocess.spawn` → `handle.done` →
  `collected.*.readFrom(0).text` chain is unchanged; `createUserMessage` with
  `source.kind: 'plugin:tool-skill-audit'` still satisfies the session-format-v4 rule.
- `engines.dsh` stays `>=0.2.0-rc.2 <0.3.0`. The README compatibility sections now name the
  verified runtime and spell out two things: the upper bound intentionally rejects a future DSH 0.3
  until this plugin is re-verified and republished, and an out-of-range host can be run with the
  plugin manager's **exact-version exemption** (stored in `profiles/<profile>/compatibility.json`)
  instead of editing the range. The README install/verify commands no longer hardcode the retired
  CLI `web` profile; they now show the profile-agnostic form and the desktop shape (Plugin page /
  bundled CLI).
- 已在 DSH 0.2.1-rc.3 桌面端复验：**无需改动代码**。`skill_audit` 全量通过（43 个技能 `fail 0 /
  warn 0`）；技能写入后 `tools/post-execute` 自动触发、结论注入上下文仍生效；`ctx.skills.register`
  仍能注册包内技能；`ctx.subprocess.spawn` → `handle.done` → `collected.*.readFrom(0).text` 链路
  不变；`createUserMessage` 配合 `source.kind: 'plugin:tool-skill-audit'` 仍满足会话格式 v4 规则。
- `engines.dsh` 保持 `>=0.2.0-rc.2 <0.3.0`。README 兼容段改为写明已验证的运行时，并讲清两点：
  上界会在 DSH 0.3 到来时**有意拒绝**，待本插件重新复验并发布新版后再放宽；若确实要在范围外的
  宿主上运行，用插件管理器的**精确版本豁免**（记录在 `profiles/<profile>/compatibility.json`），
  不要改版本范围。
- README 的安装/验证命令不再写死已退役的 CLI `web` profile：改为与 profile 无关的写法，并补充
  桌面端形态（插件页 / 桌面端自带 CLI）。

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
