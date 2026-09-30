# Changelog

All notable changes to this package are documented in this file.
本文件记录本包的重要变更。

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
