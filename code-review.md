# ModelProxy — Code Review

**Scope:** All Swift source files (30 files)
**Date:** 2026-03-07

---

## Summary

The codebase is well-architected for its scope. The proxy/UI separation is clean, the actor/MainActor concurrency model is used correctly, and the routing snapshot pattern handles hot-reloads elegantly. Findings below are prioritized: correctness issues first, then performance, then maintainability.

**Ratings**

| Dimension | Rating | Notes |
|---|---|---|
| Security | ✅ Good | Personal tool; known trade-offs documented |
| Performance | ⚠️ Fair | One avoidable hot-path allocation |
| Correctness | ⚠️ Fair | Two silent failures that leave clients hanging |
| Maintainability | ⚠️ Fair | Missing tests for most complex logic, a few DRY violations |

---

## Correctness

### C1 — Silent hang on malformed request sequence
**File:** `ProxyChannelHandler.swift:40`
**Severity:** Medium

If `.end` arrives and either `requestHead` or `bodyBuffer` is `nil`, the handler silently returns:

```swift
case .end:
    guard let head = requestHead, let body = bodyBuffer else { return }
```

The client receives no response and will hang until its own timeout fires. This can happen if the channel is reused after an error left state inconsistent, or if a non-standard HTTP client sends frames out of order. A better behavior would be to call `sendError` with `.badRequest` here.

---

### C2 — Vacuous `do {}` block
**File:** `ProxyForwarder.swift:89–95`
**Severity:** Low (code smell)

```swift
var upstreamRequest: HTTPClientRequest
do {
    upstreamRequest = HTTPClientRequest(url: finalURLString)
    upstreamRequest.method = head.method
    upstreamRequest.headers = upstreamHeaders
    upstreamRequest.body = .bytes(bodyData)
}
```

`HTTPClientRequest(url:)` does not throw. The `do {}` block is a no-op and is likely a refactor leftover. It adds visual noise suggesting something might throw when it doesn't.

---

### C3 — `routeAll` fallback-to-passthrough goes unlogged
**File:** `RoutingSnapshot.swift:95–103`
**Severity:** Low

When `unmappedPolicy == .routeAll` but the fallback vendor has been deleted, routing silently falls back to passthrough. Nothing is logged and no warning is surfaced. A user who intends all traffic to go to a vendor will have it silently leak through to the original upstream. A `Logger.proxy.warning` here would make the behavior visible.

---

### C4 — Port field saves on every valid keystroke
**File:** `ClientsTabView.swift:52–56`
**Severity:** Low

`onChange(of: portText)` fires `saveAndReload` on every keypress that produces a valid port (e.g., typing `8080` fires saves at `1`, `10`, `108`, `1080`, `8080`). The routing snapshot is updated five times for one user action. The port itself doesn't take effect until restart, so this isn't broken — but the excess saves and routing updates are wasteful. Using `.onSubmit` or debouncing would be cleaner.

---

## Performance

### P1 — `DateFormatter` created on every `add()` call
**File:** `TokenStatsStore.swift:33–38`
**Severity:** Medium

```swift
private static func todayString() -> String {
    let fmt = DateFormatter()           // allocated every call
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.locale = Locale(identifier: "en_US_POSIX")
    return fmt.string(from: Date())
}
```

`DateFormatter` is expensive to allocate. `todayString()` is called on every proxied request that has usage data. This should be a `nonisolated(unsafe) static let` (same pattern already used for `JSONEncoder.pretty` in `ConfigStore`).

---

### P2 — Non-SSE response body accumulated in memory for usage extraction
**File:** `ResponseRelay.swift:66–79`
**Severity:** Low (known trade-off)

For non-streaming responses, the entire body is copied into `bodyAccumulator: Data` to extract token counts. For most API responses this is small, but a large response (e.g., a file-generation endpoint) doubles peak memory. This is a deliberate trade-off (immediate forwarding + stats), but worth a comment explaining the constraint.

---

### P3 — Three separate `writeAndFlush` calls in `sendError`
**File:** `ProxyForwarder.swift:154–163`
**Severity:** Low

The error response writes head, body, and end as three separate `writeAndFlush` calls. These could be batched with `write`/`write`/`writeAndFlush` (flushing only once at the end) to avoid three round-trips through NIO's pipeline. Minor for an error path but straightforward to improve.

---

## Security

### S1 — API keys in plaintext `config.json`
**File:** `Vendor.swift`, `ConfigStore.swift`
**Severity:** Informational (acknowledged design decision)

The comment in `Vendor.swift` documents the decision: "API key stored in plaintext in config.json (personal-use tool; not Keychain by design)." This is a reasonable call for a personal tool. Worth noting: `config.json` is in `~/Library/Application Support/` which is readable by the user's other processes. If the use case expands (e.g., shared machines, enterprise deployment), Keychain storage would be the correct migration path.

---

### S2 — `@unchecked Sendable` on `ProxyChannelHandler`
**File:** `ProxyChannelHandler.swift:9`
**Severity:** Informational

The `@unchecked Sendable` conformance suppresses Swift 6's sendability checks. It's correct here because NIO guarantees that `channelRead` is always called on the same event loop thread, making mutable state (`requestHead`, `bodyBuffer`) safe without explicit synchronization. A brief comment explaining this invariant would prevent future contributors from removing it or from adding cross-thread state access thinking it's safe.

---

### S3 — No request body size limit
**File:** `ProxyChannelHandler.swift:36–37`
**Severity:** Informational

The body buffer accumulates without a size cap. A runaway client (or accidental misconfiguration) could exhaust memory. For a single-user local tool this is acceptable, but a cap (e.g., 100 MB) with a `413 Content Too Large` response would be good defensive practice.

---

## Maintainability

### M1 — `appSupportURL` duplicated across `ConfigStore` and `TokenStatsStore`
**File:** `ConfigStore.swift:14–20`, `TokenStatsStore.swift:21–27`
**Severity:** Low

Both services define the same `appSupportURL` static property. If the app ID or directory name changes, it must be updated in two places. A shared `AppPaths` enum or extension on `URL` would consolidate this.

---

### M2 — No tests for `ResponseRelay` usage extraction
**File:** `ModelProxyTests.swift`
**Severity:** Medium

The routing and model layers have good test coverage. But `ResponseRelay.extractUsageFromSSEChunk` and `extractUsageFromJSONBody` / `parseUsageDict` are the most complex logic in the proxy and the most likely to silently break when a vendor changes their response format. These are pure functions with no I/O — they're straightforward to unit test with fixture data. A few tests covering:

- Anthropic streaming (`message_start` + `message_delta` accumulation)
- OpenAI streaming (final chunk `usage`)
- Non-streaming JSON (Anthropic and OpenAI formats)
- Missing/malformed usage field (nil return)

...would provide a meaningful regression net.

---

### M3 — Routing rule deletion has no confirmation
**File:** `RoutingTabView.swift:136–139`
**Severity:** Low (UX inconsistency)

Deleting a vendor shows a confirmation dialog (`VendorsTabView.swift:67–92`). Deleting a routing rule does not — the "Delete" button fires immediately. Consistent behavior would confirm both, or confirm neither. Given that accidental deletion is recoverable only by reconfiguring manually, a confirmation for rules makes sense.

---

### M4 — `VendorEditSheet` accepts any base URL string without validation
**File:** `VendorEditSheet.swift:25, 57`
**Severity:** Low

The Save/Add button is enabled as long as `name` and `baseURL` are non-empty, but there's no format check on `baseURL`. An invalid URL (e.g., `"api.example.com"` without a scheme) will pass silently and fail at request time with a confusing error. A lightweight check (`URL(string: baseURL)?.scheme != nil`) would catch the most common mistake.

---

### M5 — `KnownAnthropicModels.all` requires manual maintenance
**File:** `KnownAnthropicModels.swift`
**Severity:** Informational

The list is the source of truth for the routing picker and deprecation warnings. The current list already has the `claude-haiku-4-5` / `claude-sonnet-4-6` / `claude-opus-4-6` names without date suffixes alongside the older `-20241022` names — which is correct for the new naming scheme. A comment noting the policy for when to add vs. remove entries (e.g., keep retired models for one release cycle to avoid false deprecation warnings on existing configs) would help maintainers.

---

## What's Working Well

**Architecture & concurrency model** — The `@MainActor` / NIO-thread boundary is respected throughout. `TrafficLog`, `TokenStatsStore`, and `ProxyServer` all live on the main actor; the proxy layer communicates back via `Task { @MainActor in ... }`. No data races apparent.

**Routing snapshot pattern** — `RoutingSnapshot` is immutable and captured at request time. `RequestRouter` (an actor) swaps it atomically on config change. In-flight requests see a consistent snapshot; the next request picks up the new one. Clean solution to the hot-reload problem.

**SSE streaming** — Chunks are forwarded immediately without buffering (`for try await chunk in upstreamResponse.body`), meeting the stated requirement.

**No body logging** — Request/response bodies are never logged or persisted, only the `model` field and status codes. Privacy constraints are honored.

**Redirect handling** — `redirectConfiguration: .disallow` on the upstream `HTTPClient` prevents accidental redirect-following to unintended hosts.

**Defensive config loading** — The two-migration pattern in `ConfigStore.loadOrCreateDefault()` and the fallback-to-defaults on corrupt JSON are well-handled. The `didResetFromCorrupt` flag surfacing a one-time UI alert is a nice touch.

**`so_reuseaddr` on server channel** — Prevents bind failures when the app restarts quickly after a crash. Good defensive practice.

**Test coverage for routing** — `RoutingSnapshot` resolve paths (mapped, passthrough, block, routeAll, fallback-deleted) are all tested. Codable round-trips cover all model types.
