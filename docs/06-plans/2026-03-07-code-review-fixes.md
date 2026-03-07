# Code Review Fixes Plan

**Source:** `code-review.md` (2026-03-07)
**Scope:** 11 actionable fixes (C1–C4, P1, P2, P3, M1–M4) + 2 informational comments (S2, M5)

---

## Phase 1 — Correctness (C1–C4)

### Task 1.1 — C1: Send 400 on malformed request sequence
**File:** `ModelProxy/Proxy/ProxyChannelHandler.swift:39-41`
**Change:** Replace the silent `return` with an error response when `.end` arrives without accumulated head/body.
**Implementation:**
- When guard fails, call `ProxyForwarder.sendError(channel:status:message:)` with `.badRequest`
- Reset `requestHead`/`bodyBuffer` to nil after sending error (same as normal path)
- Need channel reference: use `context.channel`

**Verify after:** Build succeeds; unit test not feasible (NIO channel setup), manual test with malformed request optional.

### Task 1.2 — C2: Remove vacuous `do {}` block
**File:** `ModelProxy/Proxy/ProxyForwarder.swift:89-95`
**Change:** Remove the `do { }` wrapper, keep the 4 assignment lines at the same scope level.

**Verify after:** Build succeeds.

### Task 1.3 — C3: Log warning when routeAll falls back to passthrough
**File:** `ModelProxy/Proxy/RoutingSnapshot.swift:91-103`
**Change:** Add `import OSLog` and a `Logger.proxy.warning(...)` before the fallback passthrough return in the `.routeAll` case where `fallbackTarget` is nil.
**Note:** RoutingSnapshot is a pure struct used from any context. Check if `Logger.proxy` is accessible (it's defined in `AppLogger.swift`). If not, add a static logger here.

**Verify after:** Build succeeds; grep confirms log line present.

### Task 1.4 — C4: Debounce port field saves
**File:** `ModelProxy/Views/ClientsTabView.swift:50-56`
**Change:** Replace `onChange(of: portText)` immediate save with `.onSubmit` for the port TextField. The port field already shows a "restart needed" banner, so saving on submit (Enter key) is the right UX — no debounce timer needed.
**Implementation:**
- Remove the `onChange(of: portText)` modifier
- Add `.onSubmit { ... }` with the same guard + save logic
- Keep `portText` as `@State` for the TextField binding

**Verify after:** Build succeeds.

---

## Phase 2 — Performance (P1, P2, P3)

### Task 2.1 — P1: Static DateFormatter in TokenStatsStore
**File:** `ModelProxy/Services/TokenStatsStore.swift:33-38`
**Change:** Replace the per-call `DateFormatter()` allocation with a `nonisolated(unsafe) static let` (same pattern as `JSONEncoder.pretty` in ConfigStore).
```swift
private nonisolated(unsafe) static let dateFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.locale = Locale(identifier: "en_US_POSIX")
    return fmt
}()

private static func todayString() -> String {
    dateFormatter.string(from: Date())
}
```

**Verify after:** Build succeeds.

### Task 2.2 — P2: Add comment explaining body accumulation trade-off
**File:** `ModelProxy/Proxy/ResponseRelay.swift:65-66`
**Change:** Add a brief comment above `var bodyAccumulator = Data()` explaining: accumulates full body in parallel with forwarding to extract token usage; doubles peak memory for large responses; acceptable because most API responses are small.

**Verify after:** Build succeeds.

### Task 2.3 — P3: Batch writes in sendError
**File:** `ModelProxy/Proxy/ProxyForwarder.swift:154-163`
**Change:** Replace three `writeAndFlush` calls with `write` / `write` / `writeAndFlush` (flush only on the last one).
```swift
_ = try? await channel.write(NIOAny(HTTPServerResponsePart.head(responseHead))).get()
_ = try? await channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf)))).get()
_ = try? await channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).get()
```

**Verify after:** Build succeeds.

---

## Phase 3 — Maintainability (M1–M4)

### Task 3.1 — M1: Extract shared `AppPaths`
**Files:** `ModelProxy/Services/ConfigStore.swift:14-20`, `ModelProxy/Services/TokenStatsStore.swift:21-27`
**Change:**
1. Create `ModelProxy/App/AppPaths.swift` with:
   ```swift
   import Foundation
   enum AppPaths {
       static let appSupport: URL = {
           let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
           return base.appendingPathComponent("ModelProxy", isDirectory: true)
       }()
   }
   ```
2. Replace `appSupportURL` in both `ConfigStore` and `TokenStatsStore` with `AppPaths.appSupport`.

**Verify after:** Build succeeds; grep for `appSupportURL` confirms no remaining duplicates (only `AppPaths` definition).

### Task 3.2 — M2: Add unit tests for usage extraction
**File:** `ModelProxyTests/ModelProxyTests.swift` (append)
**Change:** Add tests for `ResponseRelay` usage extraction. These are `private static` methods, so either:
- (a) Change visibility to `internal` (no `private`) for the three methods, or
- (b) Test indirectly through a thin wrapper.

Option (a) is simpler for a personal tool. Change `private static func extractUsageFromSSEChunk`, `extractUsageFromJSONBody`, `parseUsageDict` to `static func` (drop `private`).

**Test cases:**
1. Anthropic streaming: `message_start` with `input_tokens` + `message_delta` with `output_tokens` — verify accumulated totals
2. OpenAI streaming: final chunk with `usage.prompt_tokens` / `completion_tokens`
3. Non-streaming Anthropic JSON: `usage.input_tokens` + `cache_read_input_tokens`
4. Non-streaming OpenAI JSON: `usage.prompt_tokens` / `completion_tokens`
5. Missing/malformed usage field: returns nil / (0,0)

**Verify after:** `swift test` passes.

### Task 3.3 — M3: Add confirmation dialog for routing rule deletion
**File:** `ModelProxy/Views/RoutingTabView.swift:136-139`
**Change:** Add a `@State private var deletingMapping: ModelMapping?` to `MappingRow`. Wire the Delete button to set `deletingMapping` instead of immediate removal. Add `.confirmationDialog` matching the pattern in `VendorsTabView.swift:67-92`.

**Verify after:** Build succeeds.

### Task 3.4 — M4: Validate vendor base URL scheme
**File:** `ModelProxy/Views/VendorEditSheet.swift:57`
**Change:** Add URL scheme validation to the Save/Add button's disabled condition:
```swift
.disabled(
    name.trimmingCharacters(in: .whitespaces).isEmpty
    || baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    || URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.scheme == nil
)
```
Optionally add a helper text below the Base URL field when the URL is non-empty but has no scheme.

**Verify after:** Build succeeds.

---

## Phase 4 — Informational Comments (S2, M5)

### Task 4.1 — S2: Comment explaining `@unchecked Sendable`
**File:** `ModelProxy/Proxy/ProxyChannelHandler.swift:9`
**Change:** Add comment above the class: `// @unchecked Sendable: safe because NIO guarantees channelRead is always called on the same EventLoop thread.`

### Task 4.2 — M5: Comment on KnownAnthropicModels maintenance policy
**File:** `ModelProxy/Models/KnownAnthropicModels.swift`
**Change:** Add a header comment: `// Maintenance: add new model names on release; keep retired models for one release cycle to avoid false deprecation warnings on existing configs.`

**Verify after:** Build succeeds.

---

## Execution Order

Phases are independent. Within each phase, tasks are independent except:
- Task 3.2 (tests) depends on Task 2.1 being done first (DateFormatter change affects the same file area).

**Final verification:** `swift build && swift test` after all phases.
