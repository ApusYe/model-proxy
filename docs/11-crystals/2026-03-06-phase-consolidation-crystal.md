# Decision Crystal: Phase Consolidation and Model Simplification

**Date:** 2026-03-06

## Initial Idea

用户质疑 Phase 4 (Client Configuration UI) 的必要性：
1. 为什么需要配置 client？Claude Code / Codex 自己有自己的配置！
2. 所谓映射，就是映射 Claude 的 Opus/Sonnet/Haiku 到其它的，比如 Qwen，未配置模型不参与 proxy，直接让人家透传就行，你管什么原始不原始的 APIKEY？
3. 要求全局评估整个 App 的设计是否合理，包括计划、实现、UI 布局。

## Discussion Points

1. **Per-client 配置过度设计**：原始设计 `ClientConfig` 包含独立的 `modelMappings`，让每个 client 有独立映射。用户指出：模型映射是全局的（Opus→X, Sonnet→Y），不因调用方不同而不同。决定：映射提升到 `AppConfig` 全局，`ClientConfig` 简化为只保留 `clientName`、`port`、`defaultUpstream`。

2. **保留 per-client 端口和默认上游**：proxy 需要区分 Claude Code 和 Codex，因为两者的默认上游地址不同（Claude Code → api.anthropic.com，Codex → 其默认 endpoint）。每个 client 一个 port，proxy 通过端口识别工具来源，决定未映射请求的透传目标。

3. **Vendor.modelPatterns 是死代码**：代码审计发现 `Vendor.modelPatterns` 从未参与路由决策。实际路由使用 `modelMappings`（精确映射）。决定：删除 `modelPatterns` 字段。

4. **未映射模型的处理**：原计划用 "preserve the original API key" 措辞，暗示 proxy 在"处理" API key。用户指出：未映射模型 proxy 什么都不该碰，原来发哪就发哪。透传目标不能硬编码 api.anthropic.com，应由 client 的 `defaultUpstream` 决定。

5. **Phase 4 合并到 Phase 3**：Phase 4 的有用内容（端口配置、环境变量导出、模型映射 UI）并入 Phase 3，Phase 4 整体删除。后续 Phase 顺移编号。

6. **StatusPopover 缺失入口**：MenuBarExtra `.window` 模式下没有标准 App 菜单。popover 没有 Settings 入口，没有 Start 按钮。决定：补齐 Settings 入口和 Start/Stop 双向操作。

7. **Settings 窗口设计**：macOS HIG 要求 Settings 使用 `Form` 容器、auto-save（无 Save 按钮）、TabView 分区。

## Rejected Alternatives

- **Per-client 模型映射（独立 modelMappings per client）**：拒绝 — 模型映射是全局策略，不因调用方而异
- **完全删除 ClientConfig**：拒绝 — 不同工具有不同的默认上游地址，需要 per-client 端口来区分工具来源
- **Vendor.modelPatterns 作为路由机制**：拒绝 — 精确映射更明确，pattern matching 引入歧义且从未实际使用
- **未映射模型硬编码转发到 api.anthropic.com**：拒绝 — 透传目标应由 client 的 defaultUpstream 决定，不同工具默认上游不同

## Decisions (machine-readable)

- [D-001] 简化 `ClientConfig`：只保留 `clientName`、`port`、`defaultUpstream`（默认上游地址）；删除 per-client `modelMappings`，映射提升到 `AppConfig` 全局
- [D-002] 删除 `Vendor.modelPatterns` 字段（死代码，从未参与路由）
- [D-003] 未映射模型 = 纯透传：proxy 不碰 headers、API key、body；透传目标由该 client 的 `defaultUpstream` 决定（Claude Code 默认 `https://api.anthropic.com`，Codex 按其默认 endpoint 配置）
- [D-004] 原 Phase 4 (Client Configuration UI) 删除，有用功能（端口配置、env export、模型映射 UI）并入 Phase 3
- [D-005] Phase 编号顺移：原 5->4, 6->5, 7->6
- [D-006] StatusPopover 必须包含 Settings 入口（gear icon 或 "Settings..." 按钮）
- [D-007] StatusPopover 必须有 Start 和 Stop 双向操作（不能只有 Stop）
- [D-008] Settings 窗口使用 macOS 规范：`Form` 容器、auto-save（无 Save 按钮）、TabView 分区
- [D-009] 每个 client 一个 port（proxy 同时监听所有 client port，用于区分工具来源，决定默认上游），模型映射全局共享
- [D-010] Env export 生成完整可执行命令（含工具启动命令，如 `export ANTHROPIC_BASE_URL=http://localhost:8080 && claude`），用户可直接粘到 bash_profile 做 alias

## Constraints

- Phase 3 开始前必须先完成模型重构（D-001, D-002），作为 Phase 3 的前置步骤
- 清理 Xcode 模板残留文件（ContentView.swift, Item.swift）纳入 Phase 3
- Settings 窗口变更即时生效，不允许有 Save 按钮
- `defaultUpstream` 必须可配置，不可硬编码

## Scope Boundaries

- IN: 简化 ClientConfig（保留 port + defaultUpstream，删除 per-client modelMappings）（用户明确要求）
- IN: 模型映射提升为全局（用户明确要求）
- IN: 未映射模型纯透传，透传目标按工具区分（用户明确要求）
- IN: 全局审计 App 设计合理性（用户明确要求）
- OUT: 前缀匹配 (prefix matching)（当前只做精确匹配，未列入任何 Phase scope）

## Source Context

- Design doc: none
- Design analysis: none
- Key files discussed:
  - `docs/06-plans/dev-guide.md` (已更新)
  - `docs/11-crystals/2026-03-06-proxy-routing-crystal.md` (已有 routing crystal)
  - `ModelProxy/Models/ClientConfig.swift`
  - `ModelProxy/Models/AppConfig.swift`
  - `ModelProxy/Models/Vendor.swift`
  - `ModelProxy/Views/StatusPopover.swift`
  - `ModelProxy/App/ModelProxyApp.swift`
  - `ModelProxy/Proxy/RoutingSnapshot.swift`
  - `ModelProxy/Proxy/ProxyForwarder.swift`
