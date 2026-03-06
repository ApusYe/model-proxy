# Phase 2: Proxy Server Core (Routing and Forwarding) Implementation Plan

**Goal:** The proxy server starts on localhost, intercepts Anthropic-format requests, routes them by model ID to the correct vendor, and relays responses including SSE streaming — verified by sending real requests from curl.

**Architecture:**
- `ProxyServer`: owns NIO `ServerBootstrap`, manages start/stop lifecycle
- `RequestRouter`: looks up model in `ClientConfig.modelMappings`
  - **If found**: returns the configured vendor's endpoint and API key
  - **If not found**: returns a "passthrough" target (original api.anthropic.com + preserve caller's API key)
- `ResponseRelay`: reads AsyncHTTPClient's response body as `AsyncSequence` and writes each chunk directly to NIO client channel via `channel.writeAndFlush` (no buffering)
- **NIO-to-async bridge**: `Task { }` launched from `channelRead` handler; captures request data (model, original key) at read time and safe to use from async task
- **SSE handling**: raw bytes forwarded with no parsing; satisfies both pure-proxy and no-buffering constraints

**Tech Stack:** Swift 6 (strict concurrency), SwiftNIO 2.x, NIOHTTP1, AsyncHTTPClient, macOS 14+ (Sonoma)

**Design doc:** none

**Design analysis:** none

**Crystal file:** none

---

## Dependency Map

```
Task 1: RoutingSnapshot (pure value type — no dependencies)
Task 2: RequestRouter (depends on Task 1)
Task 3: ProxyChannelHandler (depends on Task 2)
Task 4: ProxyServer (depends on Task 3)
Task 5: ResponseRelay (depends on Task 3 — called from inside handler)
Task 6: Wire app lifecycle (depends on Task 4)
Task 7: Error handling hardening (depends on Tasks 3–5)
Task 8: End-to-end curl verification (depends on all prior tasks)
```

---

### Task 1: RoutingSnapshot — immutable config snapshot for routing

**Files:**
- Create: `ModelProxy/Proxy/RoutingSnapshot.swift`

**Steps:**

1. Create the file. This type is a pure `Sendable` struct derived from `AppConfig` at config-load time. It is captured once per incoming request in `channelRead` and passed into the async `Task` — no shared mutable state.

```swift
import Foundation

/// Immutable routing snapshot derived from ClientConfig.
/// Maps models to vendors based on modelMappings; unmapped models are passed through unchanged.
/// Captured at request time; safe to use from any concurrency context.
struct RoutingSnapshot: Sendable {

    struct RouteTarget: Sendable {
        let baseURL: String          // e.g. "https://dashscope.aliyuncs.com/compatible-mode"
        let apiKey: String
        let vendorName: String
        let targetModel: String?     // replacement model name (e.g. "qwen-turbo" when mapping claude-haiku-4-5)
        let isPassthrough: Bool      // true = preserve original API key and endpoint (api.anthropic.com)
    }

    /// Model ID -> RouteTarget mapping from ClientConfig.modelMappings
    private let modelMappings: [String: RouteTarget]
    /// Fallback: the original api.anthropic.com passthrough target
    private let passthroughTarget: RouteTarget

    init(from config: AppConfig, for clientConfig: ClientConfig) {
        // Build mapping from ClientConfig.modelMappings (set in Settings)
        // Each entry maps: sourceModel -> (targetModel, targetVendorID)
        var mappings: [String: RouteTarget] = [:]
        for (sourceModel, modelRoute) in clientConfig.modelMappings {
            if let vendor = config.vendors.first(where: { $0.id == modelRoute.targetVendorID }) {
                mappings[sourceModel] = RouteTarget(
                    baseURL: vendor.baseURL,
                    apiKey: vendor.apiKey,
                    vendorName: vendor.name,
                    targetModel: modelRoute.targetModel,
                    isPassthrough: false
                )
            }
        }
        self.modelMappings = mappings

        // Passthrough target for unmapped models:
        // If defaultVendorID is set, use that vendor; otherwise fall back to Anthropic
        if let defaultVendorID = clientConfig.defaultVendorID,
           let defaultVendor = config.vendors.first(where: { $0.id == defaultVendorID }) {
            self.passthroughTarget = RouteTarget(
                baseURL: defaultVendor.baseURL,
                apiKey: "",           // empty = use original API key
                vendorName: defaultVendor.name,
                targetModel: nil,     // no model replacement for passthrough
                isPassthrough: true
            )
        } else {
            // No default vendor configured; fall back to hardcoded Anthropic
            self.passthroughTarget = RouteTarget(
                baseURL: "https://api.anthropic.com",
                apiKey: "",           // empty = use original API key
                vendorName: "Anthropic",
                targetModel: nil,     // no model replacement for passthrough
                isPassthrough: true
            )
        }
    }

    /// Resolve the route for a given model.
    /// - If model is in modelMappings: return the configured vendor target
    /// - If model is not mapped: return passthrough target (transparent forwarding, no proxying)
    /// - Parameter model: the value of the `model` field from the request JSON.
    /// - Parameter originalAPIKey: the key sent by the client; used for passthrough requests.
    func resolve(model: String, originalAPIKey: String) -> RouteTarget {
        // Check if this model has a configured mapping
        if let mappedTarget = modelMappings[model] {
            return mappedTarget
        }

        // Unmapped model: passthrough with original baseURL (https://api.anthropic.com) and original key
        // ModelProxy does NOT proxy unmapped models — just forward them transparently
        return RouteTarget(
            baseURL: "https://api.anthropic.com",  // Claude Code's default ANTHROPIC_BASE_URL
            apiKey: originalAPIKey,                 // preserve original API key
            vendorName: "Anthropic",
            targetModel: nil,                       // no model transformation for passthrough
            isPassthrough: true
        )
    }
}
```

2. Verify the file compiles in isolation by triggering a build after Task 3 is in place (no standalone verification command possible before the project compiles).

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (run after Tasks 1–4 are all in place)

---

### Task 2: RequestRouter — extract model field and resolve route

**Files:**
- Create: `ModelProxy/Proxy/RequestRouter.swift`

**Steps:**

1. Create the file. `RequestRouter` is a pure actor that holds the current `RoutingSnapshot` and can swap it atomically (for Phase 3 hot reload). In Phase 2, the snapshot is set once at startup and never swapped.

```swift
import Foundation
import NIOCore

/// Thread-safe routing resolver.
/// Holds an atomic snapshot of routing config; swapped on config change (Phase 3).
actor RequestRouter {

    private var snapshot: RoutingSnapshot

    init(snapshot: RoutingSnapshot) {
        self.snapshot = snapshot
    }

    /// Atomically replace the routing table. In-flight requests keep the old snapshot.
    func updateSnapshot(_ newSnapshot: RoutingSnapshot) {
        self.snapshot = newSnapshot
    }

    /// Parse raw HTTP body bytes, extract the `model` field, and return a resolved target.
    /// - Parameter bodyBytes: accumulated request body buffer.
    /// - Parameter originalAPIKey: Authorization value from the incoming request.
    /// - Returns: RouteTarget with resolved base URL and API key, plus extracted model string.
    func resolve(
        bodyBytes: ByteBuffer,
        originalAPIKey: String
    ) throws -> (target: RoutingSnapshot.RouteTarget, model: String) {
        guard let data = bodyBytes.getData(at: bodyBytes.readerIndex, length: bodyBytes.readableBytes) else {
            throw RouterError.unreadableBody
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? String, !model.isEmpty else {
            throw RouterError.missingModelField
        }
        let target = snapshot.resolve(model: model, originalAPIKey: originalAPIKey)
        return (target, model)
    }
}

enum RouterError: Error, CustomStringConvertible {
    case unreadableBody
    case missingModelField

    var description: String {
        switch self {
        case .unreadableBody:   return "Request body could not be read as bytes"
        case .missingModelField: return "Request JSON missing or empty 'model' field"
        }
    }
}
```

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (run after Tasks 1–4 are all in place)

---

### Task 3: ProxyChannelHandler — NIO channel handler that bridges to async forwarding

**Files:**
- Create: `ModelProxy/Proxy/ProxyChannelHandler.swift`

**Steps:**

1. Create the file. This `ChannelInboundHandler` accumulates HTTP request parts, then launches a `Task` to call the upstream client. The async task captures the `router` actor and the channel reference — both are `Sendable`.

```swift
import Foundation
import NIOCore
import NIOHTTP1
import AsyncHTTPClient
import NIOPosix

/// NIO channel handler: accumulates a full HTTP request, then dispatches async forwarding.
final class ProxyChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: RequestRouter
    private let httpClient: HTTPClient

    // Accumulated state for the current request.
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?

    init(router: RequestRouter, httpClient: HTTPClient) {
        self.router = router
        self.httpClient = httpClient
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

            // Bridge NIO to Swift async: safe because channel is Sendable via NIO's own conformance.
            Task {
                await ProxyForwarder.forward(
                    head: head,
                    body: body,
                    channel: channel,
                    router: router,
                    httpClient: httpClient
                )
            }

            // Reset for the next request on this channel (keep-alive support).
            requestHead = nil
            bodyBuffer = nil
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Log and close; do not crash the server.
        print("[ProxyChannelHandler] Channel error: \(error)")
        context.close(promise: nil)
    }
}
```

2. Create `ProxyForwarder.swift` in the same directory. This is a namespace for the async forwarding logic — separated from the handler to keep `ProxyChannelHandler` free of `async` methods (NIO handlers are synchronous).

```swift
import Foundation
import NIOCore
import NIOHTTP1
import AsyncHTTPClient

/// Async forwarding logic, called from a Task inside ProxyChannelHandler.
enum ProxyForwarder {

    static func forward(
        head: HTTPRequestHead,
        body: ByteBuffer,
        channel: any Channel,
        router: RequestRouter,
        httpClient: HTTPClient
    ) async {
        // 1. Extract original API key (support both x-api-key and Authorization: Bearer).
        let originalAPIKey = Self.extractAPIKey(from: head.headers)

        // 2. Resolve route.
        let target: RoutingSnapshot.RouteTarget
        let model: String
        do {
            (target, model) = try await router.resolve(bodyBytes: body, originalAPIKey: originalAPIKey)
        } catch {
            await Self.sendError(channel: channel, status: .badRequest, message: "Bad request: \(error)")
            return
        }

        // 3. Build upstream URL.
        // Claude Code's default ANTHROPIC_BASE_URL is "https://api.anthropic.com"
        // Replace it with the target vendor's baseURL.
        // head.uri = request path from client (e.g., "/v1/messages")
        let originalBaseURL = "https://api.anthropic.com"
        let upstreamURLString = originalBaseURL + head.uri
            .replacingOccurrences(of: originalBaseURL, with: target.baseURL)
        // Fallback: if originalBaseURL not in path, just concat baseURL + uri
        let finalURLString = upstreamURLString.contains(target.baseURL)
            ? upstreamURLString
            : target.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + head.uri

        guard let _ = URL(string: finalURLString) else {
            await Self.sendError(channel: channel, status: .badRequest, message: "Invalid upstream URL: \(finalURLString)")
            return
        }

        // 4. Build upstream request headers.
        var upstreamHeaders = HTTPHeaders()
        for (name, value) in head.headers {
            let lower = name.lowercased()
            // Strip hop-by-hop and host headers; we will set them fresh.
            if lower == "host" || lower == "connection" || lower == "transfer-encoding" { continue }
            upstreamHeaders.add(name: name, value: value)
        }

        // Inject vendor API key — support both Anthropic header styles.
        upstreamHeaders.remove(name: "authorization")
        upstreamHeaders.remove(name: "x-api-key")
        upstreamHeaders.add(name: "Authorization", value: "Bearer \(target.apiKey)")
        upstreamHeaders.add(name: "x-api-key", value: target.apiKey)

        // Set Host from the upstream base URL.
        if let host = URL(string: target.baseURL)?.host {
            upstreamHeaders.remove(name: "host")
            upstreamHeaders.add(name: "Host", value: host)
        }

        // 5. Prepare request body — modify model field if mapped.
        var bodyData = body.getData(at: body.readerIndex, length: body.readableBytes) ?? Data()

        // If targetModel is set (mapped model), replace the model field in the JSON body.
        if let targetModel = target.targetModel {
            // Parse JSON, replace model field, re-encode.
            if var jsonBody = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                jsonBody["model"] = targetModel
                bodyData = (try? JSONSerialization.data(withJSONObject: jsonBody)) ?? bodyData
            }
        }

        // 6. Send upstream request via AsyncHTTPClient.
        var upstreamRequest: HTTPClientRequest
        do {
            upstreamRequest = HTTPClientRequest(url: finalURLString)
            upstreamRequest.method = head.method
            upstreamRequest.headers = upstreamHeaders
            upstreamRequest.body = .bytes(bodyData)
        }

        let upstreamResponse: HTTPClientResponse
        do {
            upstreamResponse = try await httpClient.execute(upstreamRequest, timeout: .seconds(120))
        } catch {
            await Self.sendError(channel: channel, status: .badGateway, message: "Upstream unreachable: \(error)")
            return
        }

        // 6. Relay response (delegates to ResponseRelay).
        await ResponseRelay.relay(
            upstreamResponse: upstreamResponse,
            to: channel
        )
    }

    // MARK: - Helpers

    private static func extractAPIKey(from headers: HTTPHeaders) -> String {
        if let bearer = headers.first(name: "authorization") {
            return bearer.hasPrefix("Bearer ") ? String(bearer.dropFirst(7)) : bearer
        }
        return headers.first(name: "x-api-key") ?? ""
    }

    static func sendError(channel: any Channel, status: HTTPResponseStatus, message: String) async {
        let bodyData = Data(message.utf8)
        var responseHead = HTTPResponseHead(version: .http1_1, status: status)
        responseHead.headers.add(name: "Content-Type", value: "text/plain")
        responseHead.headers.add(name: "Content-Length", value: "\(bodyData.count)")
        responseHead.headers.add(name: "Connection", value: "close")

        var buf = channel.allocator.buffer(capacity: bodyData.count)
        buf.writeBytes(bodyData)

        _ = try? await channel.writeAndFlush(
            NIOAny(HTTPServerResponsePart.head(responseHead))
        ).get()
        _ = try? await channel.writeAndFlush(
            NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf)))
        ).get()
        _ = try? await channel.writeAndFlush(
            NIOAny(HTTPServerResponsePart.end(nil))
        ).get()
        try? await channel.close().get()
    }
}
```

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (run after Tasks 1–4 are all in place)

---

### Task 4: ProxyServer — SwiftNIO ServerBootstrap, start/stop lifecycle

**Files:**
- Create: `ModelProxy/Proxy/ProxyServer.swift`

**Steps:**

1. Create the file. `ProxyServer` is an `@Observable` actor that owns the NIO `EventLoopGroup`, the `HTTPClient`, the `RequestRouter`, and the bound `Channel`. Observable so the app can observe `isRunning` and `lastError`.

```swift
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import AsyncHTTPClient
import Observation

/// macOS menu bar proxy server.
/// @MainActor: all state mutations must happen on main thread, avoiding data races with SwiftUI observers.
@MainActor
@Observable
final class ProxyServer {

    // MARK: - Observable State (read from MainActor in SwiftUI)

    private(set) var isRunning: Bool = false
    private(set) var lastError: String? = nil
    private(set) var boundPort: Int = 0

    // MARK: - Internal State

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var httpClient: HTTPClient?
    private var serverChannel: (any Channel)?
    private var router: RequestRouter?

    // MARK: - Start

    /// Start the proxy on the given port, using the given routing snapshot.
    /// Snapshot is built on MainActor before calling this method.
    func start(port: Int, snapshot: RoutingSnapshot) async {
        guard !isRunning else { return }
        lastError = nil
        let routerInstance = RequestRouter(snapshot: snapshot)
        self.router = routerInstance

        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.eventLoopGroup = group

        let clientConfig = HTTPClient.Configuration(
            redirectConfiguration: .disallow,
            timeout: .init(connect: .seconds(10), read: .seconds(120))
        )
        let client = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: clientConfig)
        self.httpClient = client

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        ProxyChannelHandler(router: routerInstance, httpClient: client)
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)

        do {
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
            self.serverChannel = channel
            self.boundPort = (channel.localAddress?.port) ?? port
            self.isRunning = true
            print("[ProxyServer] Listening on 127.0.0.1:\(self.boundPort)")
        } catch let err as NIOCore.IOError where err.errnoCode == EADDRINUSE {
            self.lastError = "Port \(port) is already in use. Choose a different port in Settings."
            print("[ProxyServer] \(self.lastError!)")
            try? await client.shutdown()
            try? await group.shutdownGracefully()
            self.httpClient = nil
            self.eventLoopGroup = nil
        } catch {
            self.lastError = "Failed to start proxy: \(error.localizedDescription)"
            print("[ProxyServer] \(self.lastError!)")
            try? await client.shutdown()
            try? await group.shutdownGracefully()
            self.httpClient = nil
            self.eventLoopGroup = nil
        }
    }

    // MARK: - Stop

    func stop() async {
        guard isRunning else { return }
        isRunning = false

        try? await serverChannel?.close().get()
        serverChannel = nil

        try? await httpClient?.shutdown()
        httpClient = nil

        try? await eventLoopGroup?.shutdownGracefully()
        eventLoopGroup = nil

        router = nil
        boundPort = 0
        print("[ProxyServer] Stopped.")
    }
}
```

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

### Task 5: ResponseRelay — stream upstream bytes to client channel without buffering

**Files:**
- Create: `ModelProxy/Proxy/ResponseRelay.swift`

**Steps:**

1. Create the file. The relay iterates `AsyncHTTPClient`'s response body `AsyncSequence` and writes each `ByteBuffer` directly to the client NIO channel. This single loop handles both non-streaming JSON (one or a few buffers) and SSE (many small buffers) without any buffering or framing logic — satisfying the pure-proxy and no-buffering requirements.

```swift
import Foundation
import NIOCore
import NIOHTTP1
import AsyncHTTPClient

enum ResponseRelay {

    /// Relay an AsyncHTTPClient response (headers + body) back to a NIO client channel.
    /// Writes each body chunk immediately as it arrives — no buffering for SSE.
    static func relay(upstreamResponse: HTTPClientResponse, to channel: any Channel) async {
        // 1. Forward status + response headers.
        var responseHead = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: Int(upstreamResponse.status.code))
        )
        for (name, value) in upstreamResponse.headers {
            let lower = name.lowercased()
            // Strip hop-by-hop headers.
            if lower == "transfer-encoding" || lower == "connection" { continue }
            responseHead.headers.add(name: name, value: value)
        }

        // Add Connection: close since we always close after this response (Phase 2 behavior).
        // This prevents clients from attempting keep-alive reuse and getting reset errors.
        responseHead.headers.add(name: "connection", value: "close")

        do {
            try await channel.writeAndFlush(
                NIOAny(HTTPServerResponsePart.head(responseHead))
            ).get()

            // 2. Stream body chunks as they arrive.
            for try await chunk in upstreamResponse.body {
                try await channel.writeAndFlush(
                    NIOAny(HTTPServerResponsePart.body(.byteBuffer(chunk)))
                ).get()
            }

            // 3. Signal end of response.
            try await channel.writeAndFlush(
                NIOAny(HTTPServerResponsePart.end(nil))
            ).get()

        } catch {
            // Channel may already be closed (client disconnected mid-stream); log and continue.
            print("[ResponseRelay] Write error (client may have disconnected): \(error)")
        }

        // Close the client connection unless keep-alive was negotiated.
        // For simplicity in Phase 2, always close after each response.
        // Phase 3+ can add keep-alive support when the UI is in place.
        try? await channel.close().get()
    }
}
```

**Data flow:** `upstreamResponse.body (AsyncSequence<ByteBuffer>)` -> `channel.writeAndFlush` per chunk -> client socket

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

### Task 6: Wire ProxyServer into app lifecycle

**⚠️ CRITICAL: Update AppConfig.makeDefault() FIRST**

Before implementing Task 6, update `ModelProxy/Models/AppConfig.swift` line 48:
- Old: `baseURL: "https://api.anthropic.com/v1"`
- New: `baseURL: "https://api.anthropic.com"`

**Reason:** `baseURL` is the API root without version. The request path already includes `/v1/messages`. Concatenating `baseURL + head.uri` when baseURL includes `/v1` produces `/v1/v1/messages` (doubled path). This fix aligns with the user's prior decision that baseURL should be the domain + base path only, not include the version.

**⚠️ Config migration for existing users:**

The `AppConfig.makeDefault()` change only affects fresh installs. Existing users who have manually edited `config.json` or were running an earlier version may have vendor `baseURL` values that include `/v1`. Add a migration step in `ConfigStore.loadOrCreateDefault()`:

In the `do` block at line 47, change the return statement to:
```swift
var config = try JSONDecoder().decode(AppConfig.self, from: data)

// Migration: strip trailing /v1 from baseURLs (Phase 2 baseURL convention change)
for i in 0..<config.vendors.count {
    if config.vendors[i].baseURL.hasSuffix("/v1") {
        config.vendors[i].baseURL = String(config.vendors[i].baseURL.dropLast(3))
    }
}

return config
```

This ensures all loaded configs use the new baseURL convention.

**Files:**
- Modify: `ModelProxy/App/ModelProxyApp.swift` (full file, currently 20 lines)
- Modify: `ModelProxy/Services/ConfigStore.swift` (add migration at line 48)

**Steps:**

1. Read the current file (done above — it is 20 lines). Replace it with the version below that:
   - Holds a `ProxyServer` instance on `@State`.
   - Starts the server on first launch using the first `ClientConfig`'s port.
   - Stops the server when the app terminates.

```swift
import SwiftUI

@main
struct ModelProxyApp: App {
    @State private var configStore = ConfigStore()
    @State private var proxyServer = ProxyServer()

    var body: some Scene {
        MenuBarExtra("ModelProxy", systemImage: "arrow.triangle.2.circlepath") {
            StatusPopover()
                .environment(configStore.config)
                .environment(proxyServer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            Text("Settings coming in a later phase.")
                .padding()
                .frame(width: 400)
        }
    }
}
```

**Phase 2 limitation:** The proxy server starts when the user opens the StatusPopover for the first time (clicks the menu bar icon). This is acceptable for initial development—clients can trigger the proxy startup by sending a request. Phase 3 will move this to proper app-level startup via `NSApplicationDelegateAdaptor` or `ObservableObject`.

2. Modify `ModelProxy/Views/StatusPopover.swift` to accept `proxyServer` from environment and start it on first appearance. Currently the file is a placeholder — replace it with:

```swift
import SwiftUI

struct StatusPopover: View {
    @Environment(AppConfig.self) private var config
    @Environment(ProxyServer.self) private var proxyServer
    @State private var startupAttempted = false

    var body: some View {
        VStack(spacing: 12) {
            Text("ModelProxy")
                .font(.headline)
            if proxyServer.isRunning {
                Text("Running on :\(proxyServer.boundPort)")
                    .foregroundStyle(.green)
            } else if let error = proxyServer.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            } else {
                Text("Starting…")
                    .foregroundStyle(.secondary)
            }
            Button("Quit ModelProxy") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 280)
        .onAppear {
            guard !startupAttempted else { return }
            startupAttempted = true
            Task {
                let port = config.clients.first?.port ?? 8080
                guard let clientConfig = config.clients.first else { return }
                let snapshot = RoutingSnapshot(from: config, for: clientConfig)
                await proxyServer.start(port: port, snapshot: snapshot)
            }
        }
    }
}
```

**Note:** The `proxyServer` is started in `StatusPopover.onAppear` when the user first clicks the menu bar icon. The `startupAttempted` guard ensures `start()` is called only once. This is a Phase 2 simplification; Phase 3+ will move startup to app-level lifecycle (before the user needs to interact with the UI).

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Then launch the app from Xcode (`Product > Run`). Open Console.app, filter by `ModelProxy`. Expected log within 2 seconds:
```
[ProxyServer] Listening on 127.0.0.1:8080
```

---

### Task 7: Error handling — port conflict, upstream unreachable, malformed request

**Files:**
- Modify: `ModelProxy/Proxy/ProxyServer.swift` (already written in Task 4 with EADDRINUSE handling)
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift` (already written in Task 3 with .badGateway handling)

**Steps:**

1. Verify port-conflict error path is in place. The `EADDRINUSE` catch block in `ProxyServer.start` (Task 4, step 1) sets `self.lastError`. Confirm the `lastError` string is specific enough for the UI:

   Expected string: `"Port 8080 is already in use. Choose a different port in Settings."`

2. Verify upstream-unreachable error path. In `ProxyForwarder.forward`, the `httpClient.execute` catch block returns HTTP 502 with `"Upstream unreachable: …"`. No additional code needed.

3. Verify malformed-request error path. In `ProxyForwarder.forward`, the `router.resolve` call throws `RouterError.missingModelField` on missing `model` field. The catch block returns HTTP 400. No additional code needed.

4. Add a missing-`model`-field test via curl (run after Task 8 verifies the server is live):

```bash
curl -s -o /dev/null -w "%{http_code}" \
  -X POST http://localhost:8080/v1/messages \
  -H "content-type: application/json" \
  -d '{"messages":[]}'
```
Expected: `400`

**Verify:**
Run the port-conflict test:
```bash
# Occupy port 8080
nc -l 127.0.0.1 8080 &
NC_PID=$!
# Observe ProxyServer log in Console.app — should print the "already in use" error.
# Kill the nc process after confirming:
kill $NC_PID
```
Expected Console.app output:
```
[ProxyServer] Port 8080 is already in use. Choose a different port in Settings.
```

---

### Task 8: End-to-end curl verification

**Pre-condition:** App is running, Console.app shows `[ProxyServer] Listening on 127.0.0.1:8080`. A real API key is configured in `config.json` for the Anthropic vendor.

**Steps:**

1. Confirm the default config has the Anthropic vendor with the Anthropic API key. Edit `~/Library/Application Support/ModelProxy/config.json`:
   - Set `apiKey` on the `Anthropic` vendor to your real Anthropic API key.
   - Note: `modelPatterns` is stored but NOT used for routing in Phase 2. Routing uses exact-match via `ClientConfig.modelMappings` only. Unmapped models pass through to the default vendor (Anthropic).

2. Non-streaming request — verify the full JSON body is returned correctly:

⚠️ **Important:** The API key in the `x-api-key` header is passed through verbatim to the upstream vendor (Anthropic) for unmapped models. Use your **real Anthropic API key**, not a test value. If the key is invalid, upstream returns 401.

```bash
curl -s -X POST http://localhost:8080/v1/messages \
  -H "content-type: application/json" \
  -H "x-api-key: YOUR_REAL_ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-haiku-4-5",
    "max_tokens": 16,
    "messages": [{"role": "user", "content": "Reply with the word OK only."}]
  }'
```
Expected: JSON response body with `"content"` array containing the model's reply. HTTP 200.

3. SSE streaming request — verify chunks arrive progressively, not buffered (again, use your **real API key**):

```bash
curl -N -s -X POST http://localhost:8080/v1/messages \
  -H "content-type: application/json" \
  -H "x-api-key: YOUR_REAL_ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-haiku-4-5",
    "max_tokens": 64,
    "stream": true,
    "messages": [{"role": "user", "content": "Count from 1 to 5."}]
  }'
```
Expected: Multiple `data: {...}` lines appear in the terminal progressively (observe they do not all arrive at once at the end). The `-N` flag disables curl's own buffering. Final line: `data: [DONE]` or the Anthropic `message_stop` event.

4. Exact-match routing verification (Phase 2 only supports exact-match via `modelMappings`). If you configured a mapping in the UI or manually edited `config.json`:
   - Add a model mapping: `"claude-haiku-4-5": "<some-other-vendor-uuid>"`
   - Send a request with `"model": "claude-haiku-4-5"`
   - Observe via Console or HTTP proxy (Charles) that it routes to the configured vendor, not to Anthropic
   - If no model mapping exists, the default behavior is passthrough to Anthropic (tested in step 5)

5. Default fallback — send a model name that matches no vendor:

```bash
curl -s -X POST http://localhost:8080/v1/messages \
  -H "content-type: application/json" \
  -H "x-api-key: REAL_KEY_HERE" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "gpt-totally-unknown-model",
    "max_tokens": 8,
    "messages": [{"role": "user", "content": "Hi"}]
  }'
```
Expected: The request reaches `api.anthropic.com` (visible in Console or Charles). The response will be a 400 from Anthropic (unknown model), which is correct behavior — the proxy forwarded it without misrouting.

6. Graceful stop — quit the app from the Dock or menu bar. Then:

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/v1/messages
```
Expected: `curl: (7) Failed to connect` (connection refused), exit code 7. No crash in Console.app.

**Verify:**
All curl commands above exit with the expected outputs. The Console.app `[ProxyServer]` log shows `Stopped.` on quit with no fatal errors.

---

## Decisions

### [DP-P2-001] Concurrency model for NIO-async bridging (blocking)

**Context:** `ProxyChannelHandler` is a synchronous NIO `ChannelInboundHandler`. When a full request arrives, it must call an `async` upstream client. The bridge must not block the NIO event loop thread.

**Options:**
- A: `Task { }` launched from `channelRead` — captures `channel` and `router`, dispatches to the cooperative thread pool. Simple, no NIO future involved. Already used in Task 3 above.
- B: `EventLoop.executeAsync` + `EventLoopFuture` promise — the handler creates a promise, resolves it from an async task. More complex; requires `eventLoop.makePromise` and `promise.completeWith`. No benefit over option A for Phase 2.

**Chosen:** A — `Task { }` from `channelRead`. The NIO event loop is freed immediately; the async task runs on Swift's cooperative pool. Consistent with the Swift 6 concurrency model. Already implemented in the plan.

---

### [DP-P2-002] SSE relay strategy (blocking)

**Context:** SSE responses (`text/event-stream`) must reach the client without buffering. Two approaches exist.

**Options:**
- A: Raw byte relay — forward each `ByteBuffer` chunk from `AsyncHTTPClient` directly to the client channel via `writeAndFlush`. No SSE parsing; pure proxy.
- B: Parse SSE frames and re-emit — deserialize each `data:` line, possibly reformat, then re-serialize. Adds latency, violates the "no modification of request/response content" constraint.

**Chosen:** A — raw byte relay. Satisfies the no-modification and no-buffering constraints simultaneously. Already implemented in Task 5.

---

### [DP-P2-003] Port conflict behavior (blocking)

**Context:** When the configured port is occupied at startup, the server cannot bind. The user must know what happened.

**Options:**
- A: Fail with a clear error message — set `ProxyServer.lastError`, display in `StatusPopover`, do not retry. User fixes the conflict manually.
- B: Auto-select next available port — bind to `port+1`, `port+2`, etc. Invisible to the user; breaks configured `ANTHROPIC_BASE_URL` env var.

**Chosen:** A — fail with a clear error. Option B silently breaks the configured environment variable, which is worse than a visible error. Already implemented in Task 4.

---

## Verification

- **Verdict:** Approved
- **Date:** 2026-03-06
