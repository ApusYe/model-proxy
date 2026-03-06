# Token Statistics Implementation Plan

**Goal:** Extract token usage from API responses (non-streaming JSON and streaming SSE) and display aggregated daily totals in the status popover and a new Statistics tab in Settings.

**Architecture:** `ResponseRelay` gains a side-channel extraction path: for non-streaming responses it accumulates body bytes in a parallel buffer while streaming; for SSE it scans each chunk as it passes through for the final usage event. Extracted `(vendorID, model, input, output)` tuples are published to `TokenStatsStore` via a callback closure, mirroring the existing `TrafficLog` pattern. `TokenStatsStore` is a `@MainActor @Observable` class that owns the in-memory `TokenStats` struct and persists it to a daily JSON file.

**Tech Stack:** Swift 6, SwiftUI `@Observable`, SwiftNIO ByteBuffer, Foundation JSONSerialization, FileManager for Application Support persistence.

**Design doc:** none

**Design analysis:** none

**Crystal file:** none

---

## Key Design Decisions Made in This Plan

### Vendor keying strategy

`DailyTokenSnapshot` and `TokenStats` key by vendor UUID string. `RoutingSnapshot.RouteTarget` has `vendorName` but not `vendorID`. Two options:

**Option A — Add `vendorID: UUID?` to `RouteTarget`:** Keeps UUID keying consistent with the existing data model. Requires modifying `RoutingSnapshot` to thread the vendor UUID through from `AppConfig.vendors`.

**Option B — Key by `vendorName` string instead of UUID:** Simpler, no model changes. Risk: if a user renames a vendor, historical stats accumulate under the old name in memory until the daily file rolls.

This plan uses **Option A** (add `vendorID: UUID?` to `RouteTarget`). The UUID is already available at `RoutingSnapshot` build time (`vendor.id`). Keying by UUID is more correct for the existing `DailyTokenSnapshot` Codable schema. Passthrough routes set `vendorID = nil` and are excluded from stats.

### Non-streaming body accumulation

The constraint says "prohibited: storing or logging API request/response bodies." Token usage extraction reads the `usage` field from the response JSON — it does NOT store or log the body content. A temporary in-memory copy of the response body is held only for the duration of the relay call and discarded immediately after parsing. This is consistent with the spirit of the constraint (no persistent body logging).

### SSE detection

Whether a response is SSE is determined by `Content-Type: text/event-stream` in the upstream response headers. This check happens in `ResponseRelay.relay()` before the body loop starts.

### Persistence cadence

Stats are written to disk on every `add()` call (fire-and-forget `Task` write). This is simple and ensures durability without a periodic timer. File writes are async and do not block the main actor.

---

## Task Overview

1. Add `vendorID` to `RoutingSnapshot.RouteTarget`
2. Create `TokenStatsStore` service
3. Wire `TokenStatsStore` through app entry point
4. Extend `ResponseRelay` with usage extraction callback
5. Publish token events from `ProxyForwarder`
6. Update `ProxyServer` and `ProxyChannelHandler` to thread `TokenStatsStore`
7. Add stats summary to `StatusPopover`
8. Create `StatisticsTabView` and wire into `SettingsView`

---

## Task 1: Add `vendorID` to `RoutingSnapshot.RouteTarget`

**Files:**
- Modify: `/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/RoutingSnapshot.swift`

**Steps:**

1. Add `vendorID: UUID?` to `RouteTarget`. It is `nil` for passthrough routes (which have no vendor record in config).

Replace the `RouteTarget` struct:

```swift
struct RouteTarget: Sendable {
    let baseURL: String
    let apiKey: String
    let vendorName: String
    let vendorID: UUID?          // nil for passthrough routes
    let targetModel: String?
    let isPassthrough: Bool
}
```

2. Update all `RouteTarget` construction sites inside `RoutingSnapshot.init`. There are three:

**Mapped routes** (inside the `for mapping in config.modelMappings` loop, line ~43):
```swift
mappings[mapping.sourceModel] = RouteTarget(
    baseURL: vendor.baseURL,
    apiKey: vendor.apiKey,
    vendorName: vendor.name,
    vendorID: vendor.id,        // ADD THIS
    targetModel: mapping.targetModel,
    isPassthrough: false
)
```

**Fallback target** (inside the `if clientConfig.unmappedPolicy == .routeAll` block, line ~60):
```swift
self.fallbackTarget = RouteTarget(
    baseURL: vendor.baseURL,
    apiKey: vendor.apiKey,
    vendorName: vendor.name,
    vendorID: vendor.id,        // ADD THIS
    targetModel: nil,
    isPassthrough: false
)
```

3. Update the two passthrough `RouteTarget` constructions inside `resolve(model:originalAPIKey:)` (lines ~79 and ~91). Both get `vendorID: nil`:

```swift
return .routed(RouteTarget(
    baseURL: passthroughBaseURL,
    apiKey: originalAPIKey,
    vendorName: "passthrough",
    vendorID: nil,              // ADD THIS
    targetModel: nil,
    isPassthrough: true
))
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"`
Expected: `Build succeeded`

---

## Task 2: Create `TokenStatsStore` Service

**Files:**
- Create: `/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/TokenStatsStore.swift`

**Steps:**

1. Create the file with this full implementation:

```swift
import Foundation
import Observation

/// Owns the in-memory token stats accumulator and persists daily totals to disk.
/// @MainActor so SwiftUI can observe it without cross-actor hops (matches TrafficLog pattern).
@MainActor
@Observable
final class TokenStatsStore {

    // MARK: - Observable State

    /// Current in-memory stats for today. Reset when the calendar date rolls over.
    private(set) var stats: TokenStats = TokenStats()

    /// The calendar date these stats belong to (ISO 8601, e.g. "2026-03-06").
    private(set) var statsDate: String = Self.todayString()

    // MARK: - File URL

    private static let appSupportURL: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base.appendingPathComponent("ModelProxy", isDirectory: true)
    }()

    private static func fileURL(for date: String) -> URL {
        appSupportURL.appendingPathComponent("token-stats-\(date).json")
    }

    private static func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date())
    }

    // MARK: - Init

    init() {
        let today = Self.todayString()
        self.statsDate = today
        self.stats = Self.load(for: today)
    }

    // MARK: - Accumulate

    /// Called from ProxyForwarder after a successful response with usage data.
    /// Resets the accumulator if the calendar date has rolled over since last write.
    func add(vendorID: UUID, model: String, input: Int, output: Int) {
        let today = Self.todayString()
        if today != statsDate {
            // Day rollover: persist the old day's stats (already written incrementally),
            // then start fresh for the new day.
            statsDate = today
            stats = TokenStats()
        }
        stats.add(vendorID: vendorID, modelID: model, input: input, output: output)
        persistAsync()
    }

    // MARK: - Computed helpers for UI

    /// Total tokens (input + output) for today across all vendors and models.
    var todayTotalTokens: Int {
        stats.totalInputTokens() + stats.totalOutputTokens()
    }

    /// Rows for the Statistics table: (vendorID, model, record), sorted by vendor then model.
    /// Returns empty array when stats are empty.
    var tableRows: [(vendorID: UUID, model: String, record: ModelTokenRecord)] {
        stats.records.sorted { $0.key.uuidString < $1.key.uuidString }.flatMap { (vid, modelMap) in
            modelMap.sorted { $0.key < $1.key }.map { (model, record) in
                (vendorID: vid, model: model, record: record)
            }
        }
    }

    // MARK: - Persistence

    private func persistAsync() {
        let snapshot = DailyTokenSnapshot(
            date: statsDate,
            usageByVendorAndModel: stats.records.reduce(into: [:]) { result, pair in
                result[pair.key.uuidString] = pair.value
            }
        )
        let fileURL = Self.fileURL(for: statsDate)
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                print("[TokenStatsStore] Failed to persist stats: \(error)")
            }
        }
    }

    private static func load(for date: String) -> TokenStats {
        let fm = FileManager.default
        // Ensure directory exists.
        if !fm.fileExists(atPath: appSupportURL.path) {
            try? fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        }

        let url = fileURL(for: date)
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(DailyTokenSnapshot.self, from: data) else {
            return TokenStats()
        }

        var result = TokenStats()
        for (vendorIDString, modelMap) in snapshot.usageByVendorAndModel {
            guard let vendorID = UUID(uuidString: vendorIDString) else { continue }
            for (model, record) in modelMap {
                result.add(
                    vendorID: vendorID,
                    modelID: model,
                    input: record.inputTokens,
                    output: record.outputTokens
                )
            }
        }
        return result
    }
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"`
Expected: `Build succeeded`

---

## Task 3: Wire `TokenStatsStore` Through App Entry Point

**Note:** This task is merged with Task 6. `ProxyServer` will gain a required `init(tokenStatsStore:)` in Task 6, so the full `ModelProxyApp` rewrite (including `tokenStatsStore` creation, `ProxyServer` init, and environment injection) is done there. **Skip this task — proceed to Task 4.**

---

## Task 4: Extend `ResponseRelay` with Usage Extraction

**Files:**
- Modify: `/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ResponseRelay.swift`

**Steps:**

This task modifies `ResponseRelay.relay()` to accept an optional callback closure. The relay behavior (forward immediately, no buffering) is unchanged. Usage extraction runs as a side effect:

- **Non-streaming:** body bytes are accumulated into a separate local buffer while chunks stream. After the body loop completes, the buffer is decoded once and the callback is invoked.
- **SSE:** each chunk is scanned as it passes through. Usage data is accumulated across events: Anthropic splits `input_tokens` (in `message_start` event under `message.usage`) and `output_tokens` (in `message_delta` event under `usage`). The parser checks both `json["usage"]` and `json["message"]["usage"]` paths. Accumulated totals are reported via callback after the stream ends. OpenAI-compatible SSE (single final chunk with usage) is also handled.

The callback type is `@Sendable (Int, Int) -> Void` where arguments are `(inputTokens, outputTokens)`.

Replace the entire file:

```swift
import Foundation
import NIOCore
import NIOHTTP1
import AsyncHTTPClient

enum ResponseRelay {

    /// Token usage callback: (inputTokens, outputTokens).
    typealias UsageCallback = @Sendable (Int, Int) -> Void

    /// Relay an AsyncHTTPClient response (headers + body) back to a NIO client channel.
    /// Writes each body chunk immediately as it arrives — no buffering for SSE.
    /// - Parameter onUsage: optional closure invoked once with extracted token counts.
    ///   Called at most once per relay call; never called if usage cannot be parsed.
    static func relay(
        upstreamResponse: HTTPClientResponse,
        to channel: any Channel,
        onUsage: UsageCallback? = nil
    ) async {
        // 1. Forward status + response headers.
        var responseHead = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: Int(upstreamResponse.status.code))
        )
        for (name, value) in upstreamResponse.headers {
            let lower = name.lowercased()
            if lower == "transfer-encoding" || lower == "connection" { continue }
            responseHead.headers.add(name: name, value: value)
        }
        responseHead.headers.add(name: "connection", value: "close")

        // Determine response type from Content-Type header.
        let contentType = upstreamResponse.headers.first(name: "content-type") ?? ""
        let isSSE = contentType.lowercased().contains("text/event-stream")

        do {
            try await channel.writeAndFlush(
                NIOAny(HTTPServerResponsePart.head(responseHead))
            ).get()

            if isSSE {
                // 2a. SSE: forward each chunk immediately; accumulate usage across events.
                // Anthropic splits input_tokens (message_start) and output_tokens (message_delta).
                var accumulatedInput = 0
                var accumulatedOutput = 0
                for try await chunk in upstreamResponse.body {
                    try await channel.writeAndFlush(
                        NIOAny(HTTPServerResponsePart.body(.byteBuffer(chunk)))
                    ).get()

                    // Scan chunk for usage data, accumulate across events.
                    if onUsage != nil {
                        let (input, output) = extractUsageFromSSEChunk(chunk)
                        accumulatedInput += input
                        accumulatedOutput += output
                    }
                }
                // Report accumulated totals at stream end.
                if let callback = onUsage, (accumulatedInput > 0 || accumulatedOutput > 0) {
                    callback(accumulatedInput, accumulatedOutput)
                }
            } else {
                // 2b. Non-streaming: forward chunks immediately; accumulate a parallel copy.
                var bodyAccumulator = Data()
                let shouldAccumulate = onUsage != nil

                for try await chunk in upstreamResponse.body {
                    try await channel.writeAndFlush(
                        NIOAny(HTTPServerResponsePart.body(.byteBuffer(chunk)))
                    ).get()

                    if shouldAccumulate {
                        if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                            bodyAccumulator.append(bytes)
                        }
                    }
                }

                // Parse usage from full body after all chunks forwarded.
                if let callback = onUsage, !bodyAccumulator.isEmpty {
                    if let (input, output) = extractUsageFromJSONBody(bodyAccumulator) {
                        callback(input, output)
                    }
                }
            }

            // 3. Signal end of response.
            try await channel.writeAndFlush(
                NIOAny(HTTPServerResponsePart.end(nil))
            ).get()

        } catch {
            print("[ResponseRelay] Write error (client may have disconnected): \(error)")
        }

        try? await channel.close().get()
    }

    // MARK: - Usage Extraction

    /// Extract token usage from a non-streaming JSON response body.
    /// Handles both Anthropic format (`input_tokens`, `output_tokens`, `cache_read_input_tokens`)
    /// and OpenAI format (`prompt_tokens`, `completion_tokens`).
    /// Cache read tokens are folded into input tokens.
    private static func extractUsageFromJSONBody(_ data: Data) -> (Int, Int)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else {
            return nil
        }
        return parseUsageDict(usage)
    }

    /// Extract token usage from a single SSE chunk (may contain multiple `data:` lines).
    /// Checks both top-level `usage` and nested `message.usage` paths to handle
    /// Anthropic streaming (input_tokens in message_start, output_tokens in message_delta).
    /// Returns (0, 0) if no usage found in this chunk.
    private static func extractUsageFromSSEChunk(_ buffer: ByteBuffer) -> (Int, Int) {
        guard let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
            return (0, 0)
        }
        var chunkInput = 0
        var chunkOutput = 0
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let jsonString = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard jsonString != "[DONE]",
                  let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }
            // Check top-level usage (Anthropic message_delta, OpenAI final chunk).
            if let usage = json["usage"] as? [String: Any],
               let (input, output) = parseUsageDict(usage) {
                chunkInput += input
                chunkOutput += output
            }
            // Check nested message.usage (Anthropic message_start contains input_tokens here).
            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any],
               let (input, _) = parseUsageDict(usage) {
                chunkInput += input
            }
        }
        return (chunkInput, chunkOutput)
    }

    /// Parse a `usage` dictionary into (inputTokens, outputTokens).
    /// Supports Anthropic keys (`input_tokens`, `output_tokens`, `cache_read_input_tokens`)
    /// and OpenAI keys (`prompt_tokens`, `completion_tokens`).
    /// Returns nil only if no recognized token field is found.
    private static func parseUsageDict(_ usage: [String: Any]) -> (Int, Int)? {
        // Anthropic format fields
        let anthropicInput = (usage["input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0)
        let anthropicOutput = usage["output_tokens"] as? Int ?? 0
        // OpenAI format fields
        let openaiInput = usage["prompt_tokens"] as? Int ?? 0
        let openaiOutput = usage["completion_tokens"] as? Int ?? 0

        let input = max(anthropicInput, openaiInput)
        let output = max(anthropicOutput, openaiOutput)

        guard input > 0 || output > 0 else { return nil }
        return (input, output)
    }
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"`
Expected: `Build succeeded`

---

## Task 5: Publish Token Events from `ProxyForwarder`

**Files:**
- Modify: `/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ProxyForwarder.swift`

**Steps:**

1. Add `tokenStatsStore: TokenStatsStore` parameter to `ProxyForwarder.forward()`.

2. Build the `onUsage` closure before calling `ResponseRelay.relay()`. The closure captures `vendorID` (from `target.vendorID`) and `model`. If `vendorID` is nil (passthrough), no closure is provided.

3. Pass the closure to `ResponseRelay.relay(upstreamResponse:to:onUsage:)`.

The `onUsage` callback runs in a detached task context (NIO event loop thread), so it must hop to MainActor to call `tokenStatsStore.add()`.

Full updated `forward()` function body — replace the existing `forward` static function:

```swift
static func forward(
    head: HTTPRequestHead,
    body: ByteBuffer,
    channel: any Channel,
    router: RequestRouter,
    httpClient: HTTPClient,
    trafficLog: TrafficLog,
    tokenStatsStore: TokenStatsStore
) async {
    // 1. Extract original API key.
    let originalAPIKey = Self.extractAPIKey(from: head.headers)

    // 2. Resolve route.
    let resolveResult: RoutingSnapshot.ResolveResult
    let model: String
    do {
        (resolveResult, model) = try await router.resolve(bodyBytes: body, originalAPIKey: originalAPIKey)
    } catch {
        await Self.sendError(channel: channel, status: .badRequest, message: "Bad request: \(error)")
        return
    }

    let target: RoutingSnapshot.RouteTarget
    switch resolveResult {
    case .routed(let t):
        target = t
    case .blocked(let reason):
        print("[Proxy] \(head.method.rawValue) \(head.uri) model=\(model) BLOCKED")
        let blockedEntry = TrafficEntry(model: model, routeType: .blocked, httpStatus: 403)
        await MainActor.run { trafficLog.append(blockedEntry) }
        await Self.sendError(channel: channel, status: .forbidden, message: reason)
        return
    }

    let routeType = target.isPassthrough ? "passthrough" : "mapped → \(target.vendorName)"
    print("[Proxy] \(head.method.rawValue) \(head.uri) model=\(model) \(routeType) → \(target.baseURL)")

    // 3. Build upstream URL.
    let finalURLString = target.baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        + head.uri

    guard let _ = URL(string: finalURLString) else {
        await Self.sendError(channel: channel, status: .badRequest, message: "Invalid upstream URL: \(finalURLString)")
        return
    }

    // 4. Build upstream request headers.
    var upstreamHeaders = HTTPHeaders()
    for (name, value) in head.headers {
        let lower = name.lowercased()
        if lower == "host" || lower == "connection" || lower == "transfer-encoding" { continue }
        upstreamHeaders.add(name: name, value: value)
    }

    if !target.isPassthrough {
        upstreamHeaders.remove(name: "authorization")
        upstreamHeaders.remove(name: "x-api-key")
        upstreamHeaders.add(name: "Authorization", value: "Bearer \(target.apiKey)")
        upstreamHeaders.add(name: "x-api-key", value: target.apiKey)
    }

    if let host = URL(string: target.baseURL)?.host {
        upstreamHeaders.remove(name: "host")
        upstreamHeaders.add(name: "Host", value: host)
    }

    // 5. Prepare request body.
    var bodyData = body.getData(at: body.readerIndex, length: body.readableBytes) ?? Data()

    if let targetModel = target.targetModel {
        if var jsonBody = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            jsonBody["model"] = targetModel
            bodyData = (try? JSONSerialization.data(withJSONObject: jsonBody)) ?? bodyData
        }
    }

    // 6. Send upstream request.
    var upstreamRequest: HTTPClientRequest
    do {
        upstreamRequest = HTTPClientRequest(url: finalURLString)
        upstreamRequest.method = head.method
        upstreamRequest.headers = upstreamHeaders
        upstreamRequest.body = .bytes(bodyData)
    }

    let entryRouteType: TrafficEntry.RouteType = target.isPassthrough
        ? .passthrough
        : .mapped(vendorName: target.vendorName)

    let upstreamResponse: HTTPClientResponse
    do {
        upstreamResponse = try await httpClient.execute(upstreamRequest, timeout: .seconds(120))
    } catch {
        let entry = TrafficEntry(model: model, routeType: entryRouteType, httpStatus: 502)
        await MainActor.run { trafficLog.append(entry) }
        await Self.sendError(channel: channel, status: .badGateway, message: "Upstream unreachable: \(error)")
        return
    }

    // 7. Build usage callback (only for mapped/fallback routes with a known vendor UUID).
    // Stats key by target model (vendor-facing name), falling back to source model if no mapping.
    let statsModel = target.targetModel ?? model
    let onUsage: ResponseRelay.UsageCallback? = target.vendorID.map { vendorID in
        { [tokenStatsStore] input, output in
            Task { @MainActor in
                tokenStatsStore.add(vendorID: vendorID, model: statsModel, input: input, output: output)
            }
        }
    }

    // 8. Relay response.
    await ResponseRelay.relay(
        upstreamResponse: upstreamResponse,
        to: channel,
        onUsage: onUsage
    )

    // 9. Publish traffic event.
    let statusCode = Int(upstreamResponse.status.code)
    let entry = TrafficEntry(model: model, routeType: entryRouteType, httpStatus: statusCode)
    await MainActor.run { trafficLog.append(entry) }
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"`
Expected: `Build succeeded`

---

## Task 6: Thread `TokenStatsStore` Through `ProxyChannelHandler`, `ProxyServer`, and `ModelProxyApp`

**Files:**
- Modify: `/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ProxyChannelHandler.swift`
- Modify: `/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ProxyServer.swift`
- Modify: `/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/App/ModelProxyApp.swift` (merged from Task 3)

**Steps — ProxyChannelHandler:**

1. Add `private let tokenStatsStore: TokenStatsStore` property.

2. Update `init` to accept `tokenStatsStore: TokenStatsStore`.

3. Pass `tokenStatsStore` to `ProxyForwarder.forward()`.

Full updated file:

```swift
import Foundation
import NIOCore
import NIOHTTP1
import AsyncHTTPClient
import NIOPosix

final class ProxyChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: RequestRouter
    private let httpClient: HTTPClient
    private let trafficLog: TrafficLog
    private let tokenStatsStore: TokenStatsStore

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?

    init(router: RequestRouter, httpClient: HTTPClient, trafficLog: TrafficLog, tokenStatsStore: TokenStatsStore) {
        self.router = router
        self.httpClient = httpClient
        self.trafficLog = trafficLog
        self.tokenStatsStore = tokenStatsStore
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)

        case .body(var buf):
            bodyBuffer?.writeBuffer(&buf)

        case .end:
            guard let head = requestHead, let body = bodyBuffer else { return }
            let channel = context.channel
            let router = self.router
            let httpClient = self.httpClient
            let trafficLog = self.trafficLog
            let tokenStatsStore = self.tokenStatsStore

            Task {
                await ProxyForwarder.forward(
                    head: head,
                    body: body,
                    channel: channel,
                    router: router,
                    httpClient: httpClient,
                    trafficLog: trafficLog,
                    tokenStatsStore: tokenStatsStore
                )
            }

            requestHead = nil
            bodyBuffer = nil
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[ProxyChannelHandler] Channel error: \(error)")
        context.close(promise: nil)
    }
}
```

**Steps — ProxyServer:**

1. Add `tokenStatsStore: TokenStatsStore` parameter to `start(config:)`.

2. Thread it through to `ProxyChannelHandler` construction inside `childChannelInitializer`.

3. Update the `start` call in `StatusPopover` (the `.task` modifier) to pass `tokenStatsStore` — but `StatusPopover` does not call `start` directly; it calls `proxyServer.start(config:)`. Update `ProxyServer.start` signature and update the call site in `StatusPopover`.

Changes to `ProxyServer.swift`:

Add `tokenStatsStore` as a `let` property on `ProxyServer`, set in `init`:

```swift
// At top of ProxyServer, alongside trafficLog:
let trafficLog: TrafficLog = TrafficLog()
let tokenStatsStore: TokenStatsStore
```

Update `ProxyServer.init` to accept and store `tokenStatsStore`:

```swift
init(tokenStatsStore: TokenStatsStore) {
    self.tokenStatsStore = tokenStatsStore
}
```

Inside `start(config:)`, update the `childChannelInitializer` closure to pass `tokenStatsStore`:

```swift
.childChannelInitializer { channel in
    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
        channel.pipeline.addHandler(
            ProxyChannelHandler(
                router: router,
                httpClient: client,
                trafficLog: trafficLog,
                tokenStatsStore: tokenStatsStore   // ADD
            )
        )
    }
}
```

Capture `tokenStatsStore` in the local `let` bindings inside `start(config:)`:

```swift
let trafficLog = self.trafficLog
let tokenStatsStore = self.tokenStatsStore    // ADD before the for-loop
```

**Steps — ModelProxyApp.swift:**

`ProxyServer` now requires a `TokenStatsStore` at init. Update `ModelProxyApp`:

```swift
@State private var tokenStatsStore = TokenStatsStore()
@State private var configStore = ConfigStore()
@State private var proxyServer: ProxyServer   // cannot use @State with custom init inline

// Use init():
init() {
    let store = TokenStatsStore()
    _tokenStatsStore = State(initialValue: store)
    _configStore = State(initialValue: ConfigStore())
    _proxyServer = State(initialValue: ProxyServer(tokenStatsStore: store))
}
```

**Steps — ModelProxyApp.swift (merged from Task 3):**

`ProxyServer` now requires a `TokenStatsStore` at init. `TokenStatsStore` is also injected into both scenes as an environment object.

Full updated file:

```swift
import SwiftUI

@main
struct ModelProxyApp: App {
    @State private var configStore = ConfigStore()
    @State private var tokenStatsStore: TokenStatsStore
    @State private var proxyServer: ProxyServer

    init() {
        let store = TokenStatsStore()
        _tokenStatsStore = State(initialValue: store)
        _configStore = State(initialValue: ConfigStore())
        _proxyServer = State(initialValue: ProxyServer(tokenStatsStore: store))
    }

    var body: some Scene {
        MenuBarExtra("ModelProxy", systemImage: "network") {
            StatusPopover()
                .environment(configStore)
                .environment(proxyServer)
                .environment(proxyServer.trafficLog)
                .environment(tokenStatsStore)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(configStore)
                .environment(proxyServer)
                .environment(tokenStatsStore)
        }
    }
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"`
Expected: `Build succeeded`

---

## Task 7: Add Stats Summary to `StatusPopover`

**Files:**
- Modify: `/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/StatusPopover.swift`

**Steps:**

1. Add `@Environment(TokenStatsStore.self) private var tokenStatsStore` alongside the existing environment properties.

2. Add a `statsSection` computed property displaying today's total. Show a placeholder when total is zero.

3. Insert `statsSection` and a `Divider()` between `statusSection` and the `controlSection` divider. The final VStack order: title → statusSection → Divider → statsSection → Divider → controlSection → Divider → trafficSection.

Add the `statsSection` view:

```swift
// MARK: - Stats Summary

@ViewBuilder
private var statsSection: some View {
    let total = tokenStatsStore.todayTotalTokens
    if total == 0 {
        Text("Today: no tokens yet")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    } else {
        Text("Today: \(total.formatted()) tokens")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
```

Update `body` to insert stats between status and controls:

```swift
var body: some View {
    VStack(spacing: 12) {
        Text("ModelProxy")
            .font(.headline)

        statusSection

        Divider()

        statsSection

        Divider()

        controlSection

        Divider()

        trafficSection
    }
    .padding()
    .frame(width: 360)
    .task {
        guard !proxyServer.isRunning else { return }
        await proxyServer.start(config: configStore.config)
    }
}
```

4. Update the `#Preview` at the bottom to inject a `TokenStatsStore`:

```swift
#Preview {
    StatusPopover()
        .environment(ConfigStore())
        .environment(ProxyServer(tokenStatsStore: TokenStatsStore()))
        .environment({
            let log = TrafficLog()
            log.append(TrafficEntry(model: "claude-opus-4-6", routeType: .mapped(vendorName: "DashScope"), httpStatus: 200))
            log.append(TrafficEntry(model: "claude-sonnet-4-6", routeType: .passthrough, httpStatus: 200))
            log.append(TrafficEntry(model: "gpt-4o", routeType: .blocked, httpStatus: 403))
            return log
        }())
        .environment(TokenStatsStore())
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"`
Expected: `Build succeeded`

---

## Task 8: Create `StatisticsTabView` and Wire Into `SettingsView`

**Files:**
- Create: `/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/StatisticsTabView.swift`
- Modify: `/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/SettingsView.swift`

**Steps — create StatisticsTabView:**

```swift
import SwiftUI

struct StatisticsTabView: View {
    @Environment(TokenStatsStore.self) private var tokenStatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            Divider()

            let rows = tokenStatsStore.tableRows
            if rows.isEmpty {
                emptyState
            } else {
                statsTable(rows: rows)
            }
        }
        .padding()
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Statistics — \(tokenStatsStore.statsDate)")
                .font(.headline)
            Spacer()
            Text("Today: \(tokenStatsStore.todayTotalTokens.formatted()) tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "chart.bar")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No token usage recorded today")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Token counts appear after the first proxied request.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Stats Table

    @ViewBuilder
    private func statsTable(
        rows: [(vendorID: UUID, model: String, record: ModelTokenRecord)]
    ) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Column headers
                HStack {
                    Text("Model")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Input")
                        .frame(width: 80, alignment: .trailing)
                    Text("Output")
                        .frame(width: 80, alignment: .trailing)
                    Text("Total")
                        .frame(width: 80, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)

                Divider()

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.model)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(row.record.inputTokens.formatted())
                            .font(.body.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                        Text(row.record.outputTokens.formatted())
                            .font(.body.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                        Text((row.record.inputTokens + row.record.outputTokens).formatted())
                            .font(.body.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 4)

                    Divider()
                }
            }
        }
    }
}

#Preview {
    StatisticsTabView()
        .environment(TokenStatsStore())
        .frame(width: 520, height: 380)
}
```

**Steps — update SettingsView:**

1. Add `@Environment(TokenStatsStore.self) private var tokenStatsStore`.

2. Add `StatisticsTabView` as the fourth tab in the `TabView`.

3. Thread `tokenStatsStore` through the environment chain.

Full updated file:

```swift
import SwiftUI

struct SettingsView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(TokenStatsStore.self) private var tokenStatsStore

    var body: some View {
        TabView {
            ClientsTabView()
                .tabItem { Label("Clients", systemImage: "desktopcomputer") }

            VendorsTabView()
                .tabItem { Label("Vendors", systemImage: "server.rack") }

            RoutingTabView()
                .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }

            StatisticsTabView()
                .tabItem { Label("Statistics", systemImage: "chart.bar") }
        }
        .frame(minWidth: 520, minHeight: 380)
        .environment(configStore)
        .environment(proxyServer)
        .environment(tokenStatsStore)
    }
}

#Preview {
    let store = TokenStatsStore()
    SettingsView()
        .environment(ConfigStore())
        .environment(ProxyServer(tokenStatsStore: store))
        .environment(store)
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"`
Expected: `Build succeeded`

---

## Task 9: Full Build and Acceptance Verification

**Files:** (no new files; read-only verification)

**Steps:**

1. Full clean build:

```
xcodebuild -scheme ModelProxy -destination 'platform=macOS' clean build 2>&1 | tail -5
```
Expected last line: `** BUILD SUCCEEDED **`

2. Verify `TokenStatsStore.swift` exists:

```
ls /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/TokenStatsStore.swift
```

3. Verify `StatisticsTabView.swift` exists:

```
ls /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/StatisticsTabView.swift
```

4. Verify `ResponseRelay` has `onUsage` callback:

```
grep -n "onUsage" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ResponseRelay.swift
```
Expected: at least 3 matches (parameter, SSE call, non-streaming call).

5. Verify `RouteTarget` has `vendorID`:

```
grep -n "vendorID" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/RoutingSnapshot.swift
```
Expected: at least 4 matches (property declaration + 3 construction sites).

6. Verify all passthrough routes set `vendorID: nil`:

```
grep -A2 "vendorName: \"passthrough\"" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/RoutingSnapshot.swift
```
Expected: each occurrence is followed by `vendorID: nil`.

7. Manual acceptance verification (device required):

```
# Non-streaming:
curl -X POST http://127.0.0.1:8080/v1/messages \
  -H "x-api-key: test" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-opus-4-6","messages":[{"role":"user","content":"hi"}],"max_tokens":10}'
# Then open popover — today total should be > 0.

# Streaming:
curl -X POST http://127.0.0.1:8080/v1/messages \
  -H "x-api-key: test" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-opus-4-6","messages":[{"role":"user","content":"hi"}],"max_tokens":10,"stream":true}'
# Popover today total should increment again.

# Restart app, verify stats survive restart.
# Open Settings > Statistics — table should show entries.
# Zero state: clear token-stats-<today>.json from ~/Library/Application Support/ModelProxy/, restart — Statistics tab shows placeholder.
```

---

## Decisions

### [DP-001] Anthropic SSE input token extraction
**Chosen:** C — Parse both `json["usage"]` and `json["message"]["usage"]` paths, accumulate across events, report final values at stream end.

### [DP-002] Source model vs target model in stats keying
**Chosen:** Target model (vendor-facing). Stats record `target.targetModel` (e.g., "qwen-max"), falling back to source model if no mapping exists.

---
## Verification
- **Verdict:** Approved
- **Date:** 2026-03-06
