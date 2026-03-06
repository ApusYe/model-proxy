# ModelProxy Development Guide

**Project brief:** docs/01-discovery/project-brief.md
**Architecture:** docs/02-architecture/README.md
**AI context:** docs/00-AI-CONTEXT.md

---

## Global Constraints

- **Tech stack:** macOS 14+ (Sonoma), Swift 6, SwiftUI, SwiftNIO + NIOHTTP1
- **Upstream HTTP client:** AsyncHTTPClient (see DP-001)
- **Persistence:** `~/Library/Application Support/ModelProxy/config.json`; no SwiftData, no Core Data
- **Coding conventions:**
  - Menu bar: `MenuBarExtra`, no `WindowGroup`
  - Settings: SwiftUI `Settings` scene
  - Config models: `@Observable` + JSON `Codable`
  - Proxy layer: pure NIO, no SwiftUI dependencies
- **Prohibited:**
  - Modifying API request/response content (except model field replacement for mapped models)
  - Storing or logging request/response bodies
  - Listening on non-localhost interfaces
- **Required:**
  - All proxy-side network I/O through SwiftNIO
  - SSE relay must forward chunks immediately — no buffering
  - API keys in config.json, not Keychain

---

## Phase 1: Project Scaffold and Config Models

**Status:** Completed — 2026-03-06

**Goal:** Xcode project is set up with all data models defined, config persistence working, and the app launches as a menu bar app with an empty popover.

**Depends on:** None

**Scope:**
- Xcode project creation (Swift 6, macOS 14+, no default window)
- Package dependencies: SwiftNIO, NIOHTTP1, AsyncHTTPClient
- `AppConfig` model: top-level container, JSON Codable, `@Observable`
- `Vendor` model: name, base URL, API key
- `ClientConfig` model: port, model mappings (source model -> target model + vendor ID)
- `TokenStats` model: in-memory accumulation by vendor/model; daily JSON persistence structure
- `ConfigStore`: load/save `config.json` to Application Support; create default config on first launch
- App entry: `ModelProxyApp.swift` with `MenuBarExtra` + empty `StatusPopover` placeholder
- SwiftUI `Settings` scene wired but empty

**Known issues (to fix in Phase 3):**
- `ClientConfig` has unnecessary per-client `modelMappings`; should be simplified to only `clientName` + `port` + `defaultUpstream`, with modelMappings promoted to global on `AppConfig`
- `Vendor.modelPatterns` field exists but is never used in routing (dead code)
- ContentView.swift and Item.swift are Xcode template leftovers (should be deleted)

**Key files:**
- `ModelProxy/App/ModelProxyApp.swift`
- `ModelProxy/Models/AppConfig.swift`
- `ModelProxy/Models/Vendor.swift`
- `ModelProxy/Models/ClientConfig.swift`
- `ModelProxy/Models/TokenStats.swift`
- `ModelProxy/Services/ConfigStore.swift`
- `ModelProxy/Views/StatusPopover.swift` (placeholder)

---

## Phase 2: Proxy Server Core (Routing and Forwarding)

**Status:** Completed — 2026-03-06

**Goal:** The proxy server starts on localhost, intercepts Anthropic-format requests, routes them by model ID to the correct vendor, and relays responses including SSE streaming — verified by sending real requests from curl.

**Depends on:** Phase 1 (config models, Vendor/ClientConfig)

**Scope:**
- `ProxyServer`: SwiftNIO + NIOHTTP1 HTTP server, bind to `127.0.0.1:<port>`, start/stop lifecycle
- `RequestRouter`: parse incoming request body JSON, extract `model` field, look up in modelMappings
  - **If mapped**: route to the configured vendor endpoint, replace API key, replace model field in request body
  - **If not mapped**: pure passthrough — forward the entire request as-is to the client's `defaultUpstream`, don't touch headers, API key, or body
- `ResponseRelay`: stream response bytes from upstream back to client NIO channel; handle both non-streaming JSON responses and SSE (`text/event-stream`) without buffering
- `ProxyServer` error handling: upstream unreachable, malformed request
- Wire `ProxyServer` start/stop to app lifecycle in `ModelProxyApp`

**Routing logic (from crystal D-001 through D-005):**
- Authentication: unified header replacement (both `x-api-key` and `Authorization: Bearer`)
- baseURL: replace `https://api.anthropic.com` with vendor's baseURL for mapped models
- Model field: replace `model` in request JSON body with `targetModel` for mapped models
- Unmapped models: transparent passthrough to client's `defaultUpstream`, proxy does nothing

**Architecture decisions:**
- DP-001: AsyncHTTPClient chosen (NIO-native, back-pressure compatible)
- SSE relay: forward raw bytes as-is (pure proxy, no frame parsing)
- Port conflict: fail and surface error

**Key files:**
- `ModelProxy/Proxy/ProxyServer.swift`
- `ModelProxy/Proxy/ProxyChannelHandler.swift`
- `ModelProxy/Proxy/ProxyForwarder.swift`
- `ModelProxy/Proxy/RequestRouter.swift`
- `ModelProxy/Proxy/ResponseRelay.swift`
- `ModelProxy/Proxy/RoutingSnapshot.swift`

**Acceptance criteria:**
- [ ] Mapped model: curl request with a mapped model reaches the configured vendor endpoint with vendor's API key and replaced model name
- [ ] Unmapped model: curl request with an unmapped model is passed through to api.anthropic.com unchanged (original headers, original API key, original body)
- [ ] SSE streaming response: curl receives `data:` lines progressively, not buffered
- [ ] Non-SSE response: full JSON body returned correctly
- [ ] Proxy server stops cleanly when app quits
- [ ] Port conflict at startup produces a clear error

**Review checklist:**
- [ ] /execution-review
- [ ] /feature-review (proxy round-trip is the core user journey)

---

## Phase 3: Settings UI (Vendors + Model Mappings + Clients)

**Goal:** Users can manage vendors, configure model mappings, set per-client ports and default upstreams, and copy env export commands through the Settings window. Config changes take effect on the next request without restarting the proxy.

**Depends on:** Phase 1 (config models, ConfigStore), Phase 2 (ProxyServer needs updated routing after config change)

**Scope:**

### Model Refactor (prerequisite)
- Simplify `ClientConfig`: keep only `clientName`, `port`, `defaultUpstream` (per-client default upstream URL); remove per-client `modelMappings`
- Add `modelMappings: [ModelMapping]` to `AppConfig` (global, shared across all clients)
- Remove `Vendor.modelPatterns` field (dead code, never used in routing)
- `ModelMapping` struct: `sourceModel` (Anthropic model ID) + `targetModel` (vendor model name) + `targetVendorID`
- Each client has its own port (proxy uses port to identify tool origin and determine `defaultUpstream` for unmapped models)
- Default upstream per client: Claude Code -> `https://api.anthropic.com`, Codex -> its default endpoint
- Update `RoutingSnapshot` to build from new `AppConfig` structure (global mappings + per-client defaultUpstream)
- Update `ConfigStore` with migration for existing config.json
- Delete ContentView.swift and Item.swift (Xcode template leftovers)

### Settings Window
- `SettingsView`: tabbed settings window (General / Vendors / Routing)
- **Clients tab:**
  - Per-client list (Claude Code, Codex); each client shows:
    - Port: numeric input with validation (1024-65535)
    - Default upstream: URL input (Claude Code defaults to `https://api.anthropic.com`)
    - Env export: read-only text showing complete command (e.g., `export ANTHROPIC_BASE_URL=http://localhost:8080 && claude`), with copy button (brief "Copied" confirmation)
  - Proxy listens on all configured client ports simultaneously
- **Vendors tab:**
  - Vendor list: show all vendors with name and endpoint
  - Add/edit vendor: name, base URL, API key (masked by default with reveal toggle)
  - Delete vendor with confirmation
- **Routing tab:**
  - Model mapping list: each row shows source model (Anthropic) -> target model + vendor
  - Source model: picker from known Anthropic models (claude-haiku-4-5, claude-sonnet-4-6, claude-opus-4-6, etc.)
  - Target model: free-text input (user enters vendor model name)
  - Target vendor: picker from configured vendors
  - Add/delete mappings

### Hot Reload
- Config changes auto-save via `ConfigStore`
- `RequestRouter` picks up config changes via atomic snapshot swap: new requests use updated routing, in-flight requests continue with old snapshot
- No server restart, no connection drop

**User-visible changes:**
- Settings 窗口通过 popover 底部的 gear icon 或 "Settings..." 按钮打开
- Clients 标签页：每个工具（Claude Code / Codex）独立配置端口和默认上游；每个工具有一键复制 env export 命令（含工具启动命令，可直接粘到 bash_profile 做 alias）
- Vendors 标签页：vendor 增删改（名称、endpoint、API key）
- Routing 标签页：全局模型映射管理（Anthropic 模型 -> vendor 模型）
- 保存后代理下一次请求即用新配置，无需重启

**Architecture decisions:**
- DP-002: Anthropic model picker (hybrid) — picker for source models, free-text for vendor models
- DP-003: Hot reload via atomic config snapshot swap

**Key files:**
- `ModelProxy/Models/AppConfig.swift` (refactored)
- `ModelProxy/Models/Vendor.swift` (simplified)
- `ModelProxy/Models/ModelMapping.swift` (new)
- `ModelProxy/Models/ClientConfig.swift` (simplified: only clientName + port + defaultUpstream)
- `ModelProxy/Views/SettingsView.swift`
- `ModelProxy/Views/VendorListView.swift`
- `ModelProxy/Views/VendorEditSheet.swift`
- `ModelProxy/Views/RoutingView.swift`
- `ModelProxy/Services/ConfigStore.swift` (migration)
- `ModelProxy/Proxy/RoutingSnapshot.swift` (updated)
- `ModelProxy/Proxy/RequestRouter.swift` (hot reload)

**Acceptance criteria:**
- [ ] Adding a vendor and mapping: new vendor appears in list, a subsequent proxy request for the mapped model reaches the new vendor endpoint
- [ ] Editing vendor API key: updated key is used immediately on next request (no restart)
- [ ] Deleting a vendor: removed from list; its mappings are also removed or show warning
- [ ] Port change: proxy picks up new port (may require restart of listener, but transparent to user)
- [ ] Proxy listens on all configured client ports simultaneously (e.g., 8080 for Claude Code, 8081 for Codex)
- [ ] Copy button places complete command on clipboard (e.g., `export ANTHROPIC_BASE_URL=http://localhost:8080 && claude`)
- [ ] Config survives app restart
- [ ] API key field does not appear in plain text in any log or console output

**Review checklist:**
- [ ] /execution-review
- [ ] /ui-review
- [ ] /feature-review (vendor CRUD + routing config is a complete user journey)

---

## Phase 4: Menu Bar Status Popover (Traffic Monitor)

**Goal:** The menu bar popover shows proxy status, start/stop toggle, Settings entry, and a live-updating list of recent requests.

**Depends on:** Phase 2 (ProxyServer), Phase 3 (Vendor names, Settings window)

**Scope:**
- `StatusPopover` full implementation:
  - Proxy status indicator: green dot (running) / red dot (stopped/error) with port number
  - Start/Stop toggle button
  - Settings entry: gear icon or "Settings..." button, opens Settings window
  - "Quit ModelProxy" at bottom
- `TrafficLog` model: ring buffer of recent 50 requests (model, matched vendor name, HTTP status code, timestamp)
- `ProxyServer` publishes request events to `TrafficLog` after routing decision (no request/response body)
- Traffic list view: scrollable, auto-scrolls to newest, each row shows model name / vendor / status code / relative time
- Menu bar icon: consider `network` or similar; current `arrow.triangle.2.circlepath` semantics unclear

**User-visible changes:**
- 菜单栏图标点击弹出 popover
- 顶部：代理状态（绿色圆点 "Running on :8080" / 红色圆点 "Stopped" / 错误信息）
- Start/Stop 按钮
- 请求列表：每行显示模型名称、路由目标 vendor、HTTP 状态码、相对时间
- 底部：Settings 按钮 + Quit 按钮

**Key files:**
- `ModelProxy/Views/StatusPopover.swift`
- `ModelProxy/Models/TrafficLog.swift`
- `ModelProxy/Proxy/ProxyServer.swift` (event publishing)

**Acceptance criteria:**
- [ ] Popover shows correct status immediately on open
- [ ] Stop button stops the proxy; curl requests refused
- [ ] Start button restarts the proxy; curl requests succeed
- [ ] Settings button opens Settings window
- [ ] Each request appears in the list within 1 second
- [ ] List shows at most 50 entries, does not grow unbounded
- [ ] No request/response body content in traffic log

**Review checklist:**
- [ ] /execution-review
- [ ] /ui-review
- [ ] /design-review

---

## Phase 5: Token Statistics

**Goal:** Token usage is extracted from API responses and displayed in the popover and Settings as aggregated totals.

**Depends on:** Phase 2 (ResponseRelay), Phase 4 (StatusPopover structure)

**Scope:**
- `ResponseRelay` extracts `usage` field: non-streaming from JSON; streaming from final SSE event
- `TokenStats` accumulation: in-memory, keyed by vendor + model; input tokens, output tokens
- `TokenStatsStore`: persist daily totals to JSON; load on startup
- Stats summary in popover: compact today-total (e.g., "Today: 12,450 tokens")
- Stats detail in Settings: table per vendor/model

**User-visible changes:**
- popover 显示今日 token 摘要
- Settings 新增 Statistics 标签页

**Key files:**
- `ModelProxy/Proxy/ResponseRelay.swift` (usage extraction)
- `ModelProxy/Models/TokenStats.swift`
- `ModelProxy/Services/TokenStatsStore.swift`
- `ModelProxy/Views/StatusPopover.swift` (stats summary)
- `ModelProxy/Views/StatsView.swift`

**Acceptance criteria:**
- [ ] Non-streaming request: token counts increment correctly
- [ ] Streaming request: token counts increment (SSE final event parsed)
- [ ] Stats persist across app restarts
- [ ] Popover shows correct today-total
- [ ] Stats table in Settings shows per-vendor/model breakdown
- [ ] Zero stats shows placeholder, not blank

**Review checklist:**
- [ ] /execution-review
- [ ] /ui-review
- [ ] /feature-review

---

## Phase 6: Launch at Login and Final Polish

**Goal:** App launches at login via `SMAppService`, all edge cases handled, ready for daily use.

**Depends on:** All previous phases

**Scope:**
- `SMAppService` integration: register/unregister login item; Settings General tab toggle
- Menu bar icon state:
  - Normal: default icon
  - Proxy error (port conflict, vendor unreachable): red badge
  - Config issue (deprecated Anthropic model in mappings): yellow badge
- Popover error display: when icon shows badge, popover top shows error/warning message
- Edge cases:
  - config.json missing/corrupt at launch: reset to defaults with notification
  - Upstream vendor unreachable: return HTTP error to client, show in traffic list
- Deprecation detection: on launch, check configured Anthropic models against known list; flag stale mappings
- Code cleanup: remove debug logging, ensure no API keys in console
- Accessibility: VoiceOver labels
- Menu bar icon: finalize template image asset (light/dark compatible)

**User-visible changes:**
- Settings General 标签页新增"登录时启动"开关
- 菜单栏图标状态：正常/错误(红)/警告(黄)
- vendor 不可达时流量列表显示错误状态
- 过期模型映射有黄色警告提示

**Key files:**
- `ModelProxy/Services/LoginItemService.swift`
- `ModelProxy/Views/SettingsView.swift` (General tab updated)
- `ModelProxy/Proxy/ProxyServer.swift` (error surface)
- `Assets.xcassets` (menu bar icon)

**Acceptance criteria:**
- [ ] Launch at Login toggle works (on/off verified by log out/in)
- [ ] Port conflict: popover shows error, red badge on icon
- [ ] Missing config.json: app starts with defaults, no crash
- [ ] Upstream 503: traffic list shows 503, client receives proper error
- [ ] No API key in Console.app logs
- [ ] Menu bar icon renders correctly in light and dark mode
- [ ] Deprecated model mapping: yellow badge + popover warning

**Review checklist:**
- [ ] /execution-review
- [ ] /ui-review
- [ ] /feature-review

---

## Decisions

### [DP-001] Upstream HTTP client library

**Chosen:** AsyncHTTPClient

**Rationale:**
1. NIO-native, stays on event loops, no thread pool context switches
2. Native backpressure support prevents memory buildup for streaming
3. Entire request lifecycle within Swift memory model

---

### [DP-002] Model routing configuration: Anthropic picker + vendor free-text

**Design:**
- **Source side** — UI dropdown picker showing known Claude models (claude-haiku-4-5, claude-sonnet-4-6, claude-opus-4-6, etc.)
- **Target side** — user manually enters vendor model name + selects vendor from configured list
- **Unmapped models** — pure passthrough to client's `defaultUpstream`, proxy does nothing
- **Deprecation detection** (Phase 6) — on launch, check if configured source models still exist in known list

**Chosen:** Hybrid approach — picker for Anthropic models, free-text for vendor models

---

### [DP-003] Hot reload on config change

**Design:**
- `RequestRouter` holds atomic reference to current routing config (immutable snapshot)
- On config save, swap snapshot; in-flight requests continue with old snapshot, new requests use new
- No server restart, no connection drop

**Chosen:** Graceful config swap

---

## Changelog

### 2026-03-06: Phase 3/4 Consolidation

**What changed:**
- Old Phase 4 (Client Configuration UI) deleted — per-client config concept was unnecessary
- Model mapping UI, port config, and env export merged into Phase 3
- Old Phases 5/6/7 renumbered to 4/5/6
- `ClientConfig` simplified: keep only `clientName` + `port` + `defaultUpstream`; per-client `modelMappings` removed, promoted to global on `AppConfig`
- Each client has its own port (proxy identifies tool origin by port, determines `defaultUpstream` for unmapped models)
- `Vendor.modelPatterns` to be removed in Phase 3 (dead code)
- Routing description corrected: unmapped models are pure passthrough to client's `defaultUpstream` (proxy touches nothing)
- StatusPopover must have Settings entry (added to Phase 4 scope)
- StatusPopover must have Start button (not just Stop)

**Why:**
- Model mappings are a global strategy (Opus->X, Sonnet->Y), not per-client. But different tools have different default upstreams, so per-client port + defaultUpstream is needed.
- `Vendor.modelPatterns` was never used in routing; actual routing uses `modelMappings`.
- Unmapped models should be fully transparent — the proxy is a pipe, not a manager. Passthrough target is per-client, not hardcoded.
