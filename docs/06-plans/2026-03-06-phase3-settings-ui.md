# Phase 3: Settings UI Implementation Plan

**Goal:** Users can manage vendors, configure model mappings, set per-client ports and default upstreams, and copy env export commands through the Settings window; config changes take effect on the next request without restarting the proxy.

**Architecture:** Model refactor first (ClientConfig simplified, global ModelMapping, Vendor.modelPatterns removed), then Settings UI (TabView with Clients/Vendors/Routing tabs, macOS HIG Form + auto-save), then multi-port ProxyServer and hot-reload wiring. Config changes trigger an atomic RoutingSnapshot swap in RequestRouter so in-flight requests are unaffected.

**Tech Stack:** Swift 6, SwiftUI (`Settings` scene, `Form`, `TabView`), SwiftNIO + NIOHTTP1 (multi-port), `@Observable` + JSON Codable config models.

**Design doc:** none

**Design analysis:** none

**Crystal file:** `docs/11-crystals/2026-03-06-phase-consolidation-crystal.md`, `docs/11-crystals/2026-03-06-proxy-routing-crystal.md`

---

## Task Order

```
Task 1  — Delete Xcode template leftovers (ContentView.swift, Item.swift)
Task 2  — Refactor Vendor: remove modelPatterns
Task 3  — Refactor ClientConfig: add defaultUpstream, remove modelMappings
Task 4  — Add ModelMapping struct + update AppConfig
Task 5  — Update AppConfig.makeDefault() + ConfigStore migration
Task 5b — Update ModelProxyTests for model refactor (comprehensive)
Task 6  — Refactor RoutingSnapshot for global mappings + per-client defaultUpstream
Task 7  — Refactor ProxyForwarder: passthrough uses client defaultUpstream (not hardcoded)
Task 8  — Refactor ProxyServer: multi-port (one listener per ClientConfig)
Task 9  — Wire proxy startup to app launch in ModelProxyApp
Task 10 — Update StatusPopover: remove startProxy call, add Settings entry + Start button
Task 11 — Hot-reload: connect ConfigStore saves to RequestRouter snapshot swap
Task 12 — SettingsView shell: TabView with three tabs
Task 13 — Clients tab UI
Task 14 — Vendors tab UI (list + add/edit sheet + delete)
Task 15 — Routing tab UI (mapping list + add/delete)
Task 16 — Build clean + smoke test
```

---

### Task 1: Delete Xcode template leftovers

**Crystal ref:** phase-consolidation-crystal [D-004] (cleanup noted as Phase 3 prerequisite)

**Files:**
- Delete: `ModelProxy/ContentView.swift`
- Delete: `ModelProxy/Item.swift`

**Steps:**
1. Remove both files from the Xcode project target. In Xcode: select each file in the Project Navigator, press Delete, choose "Move to Trash".
2. Verify nothing imports these files.

**Verify:**
Run: `grep -r "ContentView\|import SwiftData\|Item(timestamp" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/`
Expected: no matches (ContentView and Item are not referenced anywhere else in the project)

---

### Task 2: Refactor Vendor — remove modelPatterns

**Crystal ref:** phase-consolidation-crystal [D-002]

**Files:**
- Modify: `ModelProxy/Models/Vendor.swift` (full rewrite)

**Steps:**
1. Replace the entire file content with the version below. Remove `modelPatterns: [String]` from the struct and its `init`.

```swift
import Foundation

/// A single upstream API provider.
struct Vendor: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// Base URL of the vendor's API (without version path),
    /// e.g. "https://dashscope.aliyuncs.com/compatible-mode".
    /// The request URI (including "/v1/...") is appended directly.
    var baseURL: String
    /// API key stored in plaintext in config.json (personal-use tool; not Keychain by design).
    var apiKey: String

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        apiKey: String
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}
```

**Verify:**
Run: `grep -r "modelPatterns" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/`
Expected: no matches

---

### Task 3: Refactor ClientConfig — add defaultUpstream, remove modelMappings

**Crystal ref:** phase-consolidation-crystal [D-001], [D-003], [D-009]

**Files:**
- Modify: `ModelProxy/Models/ClientConfig.swift` (full rewrite)

**Steps:**
1. Replace the entire file. Remove the `ModelRoute` nested struct and `modelMappings`. Add `defaultUpstream: String`.

```swift
import Foundation

/// Configuration for a single AI client tool (e.g., Claude Code or Codex).
/// Each client gets its own proxy port. The proxy identifies the tool by port and
/// uses `defaultUpstream` as the passthrough target for unmapped models.
struct ClientConfig: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// Display name, e.g. "Claude Code" or "Codex".
    var clientName: String
    /// Localhost port this client's proxy listener binds to.
    var port: Int
    /// Passthrough target URL for unmapped models.
    /// Claude Code default: "https://api.anthropic.com"
    /// Codex default: configured per-installation endpoint.
    var defaultUpstream: String

    init(
        id: UUID = UUID(),
        clientName: String,
        port: Int,
        defaultUpstream: String
    ) {
        self.id = id
        self.clientName = clientName
        self.port = port
        self.defaultUpstream = defaultUpstream
    }
}
```

**Verify:**
Run: `grep -r "modelMappings\|ModelRoute" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/`
Expected: no matches

---

### Task 4: Add ModelMapping struct + update AppConfig

**Crystal ref:** phase-consolidation-crystal [D-001]; proxy-routing-crystal [D-003]

**Files:**
- Create: `ModelProxy/Models/ModelMapping.swift`
- Modify: `ModelProxy/Models/AppConfig.swift` (full rewrite)

**Steps:**

1. Create `ModelProxy/Models/ModelMapping.swift`:

```swift
import Foundation

/// A single global model routing rule.
/// Maps one Anthropic source model to a vendor-specific target model.
/// Global across all clients — routing rules do not differ by tool.
struct ModelMapping: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// Anthropic model ID to match exactly, e.g. "claude-haiku-4-5".
    var sourceModel: String
    /// Vendor-specific model name to substitute, e.g. "qwen-turbo".
    var targetModel: String
    /// UUID of the Vendor to route to.
    var targetVendorID: UUID

    init(
        id: UUID = UUID(),
        sourceModel: String,
        targetModel: String,
        targetVendorID: UUID
    ) {
        self.id = id
        self.sourceModel = sourceModel
        self.targetModel = targetModel
        self.targetVendorID = targetVendorID
    }
}
```

2. Rewrite `ModelProxy/Models/AppConfig.swift`:

```swift
import Foundation
import Observation

/// Top-level configuration container.
/// Loaded from and persisted to config.json by ConfigStore.
/// `@Observable` so SwiftUI views automatically update when properties change.
@Observable
final class AppConfig: Codable {
    var vendors: [Vendor]
    var clients: [ClientConfig]
    /// Global model routing rules, shared across all clients.
    var modelMappings: [ModelMapping]

    // MARK: - Init

    init(
        vendors: [Vendor] = [],
        clients: [ClientConfig] = [],
        modelMappings: [ModelMapping] = []
    ) {
        self.vendors = vendors
        self.clients = clients
        self.modelMappings = modelMappings
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case vendors
        case clients
        case modelMappings
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vendors = try container.decode([Vendor].self, forKey: .vendors)
        clients = try container.decode([ClientConfig].self, forKey: .clients)
        modelMappings = (try? container.decode([ModelMapping].self, forKey: .modelMappings)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vendors, forKey: .vendors)
        try container.encode(clients, forKey: .clients)
        try container.encode(modelMappings, forKey: .modelMappings)
    }
}

// MARK: - Default config

extension AppConfig {
    /// Sensible defaults created on first launch.
    static func makeDefault() -> AppConfig {
        let claudeCodeClient = ClientConfig(
            clientName: "Claude Code",
            port: 8080,
            defaultUpstream: "https://api.anthropic.com"
        )
        let codexClient = ClientConfig(
            clientName: "Codex",
            port: 8081,
            defaultUpstream: "https://api.openai.com"
        )
        return AppConfig(
            vendors: [],
            clients: [claudeCodeClient, codexClient],
            modelMappings: []
        )
    }
}
```

Note: `modelMappings` uses `try?` decode with `?? []` fallback so existing config.json files without the `modelMappings` key decode successfully (see Task 5 for the full migration strategy).

**Verify:**
Run: `grep -r "modelPatterns\|ModelRoute" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Models/`
Expected: no matches

---

### Task 5: Update ConfigStore — migration for existing config.json

**Files:**
- Modify: `ModelProxy/Services/ConfigStore.swift` (update migration block)

**Steps:**
1. Read the current file (already read above — lines 1-89).
2. Replace the migration block inside `loadOrCreateDefault()`. The new migration must handle two cases:
   - Old `Vendor` objects may have a `modelPatterns` key in JSON: harmless since `Vendor` no longer has the field and `Codable` ignores unknown keys by default.
   - Old `ClientConfig` objects will be missing `defaultUpstream`: the decoder will throw because `defaultUpstream` is non-optional with no default. Fix by using a custom migration: decode with a legacy struct first, then convert.

Replace the entire `loadOrCreateDefault()` method:

```swift
private static func loadOrCreateDefault() -> AppConfig {
    let fileURL = configFileURL
    let fm = FileManager.default

    // Ensure directory exists.
    if !fm.fileExists(atPath: appSupportURL.path) {
        try? fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
    }

    guard fm.fileExists(atPath: fileURL.path),
          let data = try? Data(contentsOf: fileURL) else {
        let defaults = AppConfig.makeDefault()
        try? JSONEncoder.pretty.encode(defaults).write(to: fileURL)
        return defaults
    }

    do {
        var config = try JSONDecoder().decode(AppConfig.self, from: data)

        // Migration 1: strip trailing /v1 from baseURLs (Phase 2 convention change).
        for i in 0..<config.vendors.count {
            if config.vendors[i].baseURL.hasSuffix("/v1") {
                config.vendors[i].baseURL = String(config.vendors[i].baseURL.dropLast(3))
            }
        }

        // Migration 2: clients missing defaultUpstream get a sensible default.
        // (AppConfig.init(from:) decodes defaultUpstream via a legacy-tolerant path — see note below.)
        // Clients whose name contains "Claude" default to api.anthropic.com; others to api.openai.com.
        for i in 0..<config.clients.count {
            if config.clients[i].defaultUpstream.isEmpty {
                config.clients[i].defaultUpstream = config.clients[i].clientName
                    .lowercased().contains("claude")
                    ? "https://api.anthropic.com"
                    : "https://api.openai.com"
            }
        }

        return config
    } catch {
        // Corrupt config: reset to defaults.
        print("[ConfigStore] Failed to decode config.json: \(error). Resetting to defaults.")
        let defaults = AppConfig.makeDefault()
        try? JSONEncoder.pretty.encode(defaults).write(to: fileURL)
        return defaults
    }
}
```

Also update `ClientConfig` to decode `defaultUpstream` with a fallback so old JSON doesn't hard-fail. Add a custom `init(from:)` to `ClientConfig`:

```swift
// In ClientConfig.swift, add after the memberwise init:

init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    clientName = try c.decode(String.self, forKey: .clientName)
    port = try c.decode(Int.self, forKey: .port)
    // Legacy configs lack defaultUpstream; use empty string; ConfigStore migration sets a real value.
    defaultUpstream = (try? c.decode(String.self, forKey: .defaultUpstream)) ?? ""
}

func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(clientName, forKey: .clientName)
    try c.encode(port, forKey: .port)
    try c.encode(defaultUpstream, forKey: .defaultUpstream)
}

enum CodingKeys: String, CodingKey {
    case id, clientName, port, defaultUpstream
}
```

**Verify:**
Create a temporary JSON file simulating old format and confirm it decodes:
```
echo '{"vendors":[],"clients":[{"id":"00000000-0000-0000-0000-000000000001","clientName":"Claude Code","port":8080,"modelMappings":{}}]}' | swift -e '
import Foundation
// paste ClientConfig + AppConfig structs inline and decode — or just build the project
'
```
Practical verify: `xcodebuild -scheme ModelProxy -destination "platform=macOS" build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

---

### Task 5b: Update ModelProxyTests for model refactor (comprehensive)

**Crystal ref:** phase-consolidation-crystal [D-001], [D-002]

**Files:**
- Modify: `ModelProxyTests/ModelProxyTests.swift` (full rewrite)

**Steps:**
1. Replace the entire file. Fix compilation for new model APIs + add comprehensive tests for ModelMapping, ClientConfig migration (old JSON -> new struct), and RoutingSnapshot with global mappings.

```swift
import Testing
import Foundation
@testable import ModelProxy

struct ModelProxyTests {

    // MARK: - Vendor round-trip

    @Test func vendorCodableRoundTrip() throws {
        let original = Vendor(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "DashScope",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode",
            apiKey: "sk-test-key"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Vendor.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - ClientConfig round-trip

    @Test func clientConfigCodableRoundTrip() throws {
        let original = ClientConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            clientName: "Claude Code",
            port: 8080,
            defaultUpstream: "https://api.anthropic.com"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClientConfig.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - ClientConfig migration (old JSON without defaultUpstream)

    @Test func clientConfigDecodesLegacyJSON() throws {
        // Old format: has modelMappings, no defaultUpstream
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000003",
            "clientName": "Claude Code",
            "port": 8080,
            "modelMappings": {"claude-haiku-4-5": {"targetModel": "qwen-turbo", "targetVendorID": "00000000-0000-0000-0000-000000000002"}}
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ClientConfig.self, from: legacyJSON)
        #expect(decoded.clientName == "Claude Code")
        #expect(decoded.port == 8080)
        #expect(decoded.defaultUpstream == "") // empty = needs migration in ConfigStore
    }

    // MARK: - ModelMapping round-trip

    @Test func modelMappingCodableRoundTrip() throws {
        let vendorID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let original = ModelMapping(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            sourceModel: "claude-haiku-4-5",
            targetModel: "qwen-turbo",
            targetVendorID: vendorID
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelMapping.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - AppConfig round-trip

    @Test func appConfigCodableRoundTrip() throws {
        let config = AppConfig.makeDefault()
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.vendors.count == config.vendors.count)
        #expect(decoded.clients.count == config.clients.count)
        #expect(decoded.modelMappings.count == config.modelMappings.count)
        #expect(decoded.clients.first?.port == config.clients.first?.port)
        #expect(decoded.clients.first?.defaultUpstream == config.clients.first?.defaultUpstream)
    }

    // MARK: - AppConfig default shape

    @Test func defaultConfigHasExpectedShape() {
        let config = AppConfig.makeDefault()
        #expect(config.vendors.isEmpty)
        #expect(config.clients.count == 2)
        #expect(config.clients[0].clientName == "Claude Code")
        #expect(config.clients[0].port == 8080)
        #expect(config.clients[0].defaultUpstream == "https://api.anthropic.com")
        #expect(config.clients[1].clientName == "Codex")
        #expect(config.clients[1].port == 8081)
        #expect(config.modelMappings.isEmpty)
    }

    // MARK: - RoutingSnapshot: mapped model

    @Test func routingSnapshotResolvesMappedModel() {
        let vendor = Vendor(name: "DashScope", baseURL: "https://dashscope.aliyuncs.com/compatible-mode", apiKey: "sk-dash")
        let mapping = ModelMapping(sourceModel: "claude-haiku-4-5", targetModel: "qwen-turbo", targetVendorID: vendor.id)
        let client = ClientConfig(clientName: "Claude Code", port: 8080, defaultUpstream: "https://api.anthropic.com")
        let config = AppConfig(vendors: [vendor], clients: [client], modelMappings: [mapping])
        let snapshot = RoutingSnapshot(from: config, for: client)

        let target = snapshot.resolve(model: "claude-haiku-4-5", originalAPIKey: "original-key")
        #expect(!target.isPassthrough)
        #expect(target.baseURL == "https://dashscope.aliyuncs.com/compatible-mode")
        #expect(target.apiKey == "sk-dash")
        #expect(target.targetModel == "qwen-turbo")
    }

    // MARK: - RoutingSnapshot: unmapped model passthrough

    @Test func routingSnapshotPassthroughUnmappedModel() {
        let client = ClientConfig(clientName: "Claude Code", port: 8080, defaultUpstream: "https://api.anthropic.com")
        let config = AppConfig(vendors: [], clients: [client], modelMappings: [])
        let snapshot = RoutingSnapshot(from: config, for: client)

        let target = snapshot.resolve(model: "claude-opus-4-6", originalAPIKey: "my-key")
        #expect(target.isPassthrough)
        #expect(target.baseURL == "https://api.anthropic.com")
        #expect(target.apiKey == "my-key")
        #expect(target.targetModel == nil)
    }

    // MARK: - RoutingSnapshot: different client uses different defaultUpstream

    @Test func routingSnapshotUsesClientDefaultUpstream() {
        let codexClient = ClientConfig(clientName: "Codex", port: 8081, defaultUpstream: "https://api.openai.com")
        let config = AppConfig(vendors: [], clients: [codexClient], modelMappings: [])
        let snapshot = RoutingSnapshot(from: config, for: codexClient)

        let target = snapshot.resolve(model: "some-model", originalAPIKey: "key")
        #expect(target.isPassthrough)
        #expect(target.baseURL == "https://api.openai.com")
    }

    // MARK: - TokenStats accumulation

    @Test func tokenStatsAccumulation() {
        var stats = TokenStats()
        let vendorID = UUID()
        stats.add(vendorID: vendorID, modelID: "claude-haiku-4-5", input: 100, output: 50)
        stats.add(vendorID: vendorID, modelID: "claude-haiku-4-5", input: 200, output: 75)
        #expect(stats.totalInputTokens() == 300)
        #expect(stats.totalOutputTokens() == 125)
    }

    // MARK: - DailyTokenSnapshot round-trip

    @Test func dailyTokenSnapshotRoundTrip() throws {
        let vendorID = UUID()
        let record = ModelTokenRecord(inputTokens: 500, outputTokens: 200)
        let snapshot = DailyTokenSnapshot(
            date: "2026-03-06",
            usageByVendorAndModel: [vendorID.uuidString: ["claude-sonnet-4-6": record]]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DailyTokenSnapshot.self, from: data)
        #expect(decoded.date == snapshot.date)
        #expect(decoded.usageByVendorAndModel[vendorID.uuidString]?["claude-sonnet-4-6"] == record)
    }
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`

Run: `xcodebuild test -scheme ModelProxy -destination "platform=macOS" 2>&1 | grep -E "Test.*passed|Test.*failed|error:"`
Expected: All tests passed

---

### Task 6: Refactor RoutingSnapshot — global mappings + per-client defaultUpstream

**Crystal ref:** proxy-routing-crystal [D-003], [D-005]; phase-consolidation-crystal [D-003]

**Files:**
- Modify: `ModelProxy/Proxy/RoutingSnapshot.swift` (full rewrite)

**Steps:**
1. Replace the entire file. The new `init` takes global `modelMappings` from `AppConfig` and the specific `ClientConfig` for the port that received the request. Passthrough target uses `clientConfig.defaultUpstream` instead of hardcoded `api.anthropic.com`.

```swift
import Foundation

/// Immutable routing snapshot for one client port.
/// Built from AppConfig global mappings + the ClientConfig for the receiving port.
/// Captured at request time; safe to use from any concurrency context.
struct RoutingSnapshot: Sendable {

    struct RouteTarget: Sendable {
        /// Vendor baseURL, e.g. "https://dashscope.aliyuncs.com/compatible-mode"
        let baseURL: String
        /// Vendor API key (empty string = use original key from request)
        let apiKey: String
        let vendorName: String
        /// Replacement model name; nil = no model field substitution
        let targetModel: String?
        /// true = pure passthrough — proxy does not touch headers, key, or body
        let isPassthrough: Bool
    }

    /// sourceModel -> RouteTarget, built from AppConfig.modelMappings
    private let modelMappings: [String: RouteTarget]
    /// Passthrough target for unmapped models: the client's configured defaultUpstream.
    private let passthroughBaseURL: String

    /// Build a snapshot for a specific client port.
    /// - Parameters:
    ///   - config: full AppConfig (provides global modelMappings + vendor lookup)
    ///   - clientConfig: the ClientConfig whose port received the request
    init(from config: AppConfig, for clientConfig: ClientConfig) {
        var mappings: [String: RouteTarget] = [:]
        for mapping in config.modelMappings {
            if let vendor = config.vendors.first(where: { $0.id == mapping.targetVendorID }) {
                mappings[mapping.sourceModel] = RouteTarget(
                    baseURL: vendor.baseURL,
                    apiKey: vendor.apiKey,
                    vendorName: vendor.name,
                    targetModel: mapping.targetModel,
                    isPassthrough: false
                )
            }
            // If vendor no longer exists (deleted), skip mapping silently.
            // The UI prevents dangling mappings but a concurrent delete could race.
        }
        self.modelMappings = mappings
        self.passthroughBaseURL = clientConfig.defaultUpstream
    }

    /// Resolve a route for the given model.
    /// - Mapped model: returns configured vendor target with key + model replacement.
    /// - Unmapped model: returns passthrough to client's defaultUpstream (proxy touches nothing).
    func resolve(model: String, originalAPIKey: String) -> RouteTarget {
        if let mapped = modelMappings[model] {
            return mapped
        }
        // Unmapped: pure passthrough. Use original key and the client's configured upstream.
        return RouteTarget(
            baseURL: passthroughBaseURL,
            apiKey: originalAPIKey,
            vendorName: "passthrough",
            targetModel: nil,
            isPassthrough: true
        )
    }
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED` with no `error:` lines

---

### Task 7: Fix ProxyForwarder — passthrough uses snapshot's baseURL, not hardcoded string

**Crystal ref:** proxy-routing-crystal [D-005]; phase-consolidation-crystal [D-003]

**Files:**
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift:31-45`

**Steps:**
1. The current code at lines 31-45 hardcodes `"https://api.anthropic.com"` as the `originalBaseURL` before building `finalURLString`. This is wrong for Codex clients whose `defaultUpstream` is different. Since `target.baseURL` is already set correctly by `RoutingSnapshot.resolve()` (either vendor URL or `passthroughBaseURL`), simplify the URL construction to use `target.baseURL` directly.

Replace lines 31-45 in `ProxyForwarder.forward()`:

```swift
// 3. Build upstream URL.
// target.baseURL is either the vendor's baseURL (mapped) or the client's defaultUpstream (passthrough).
// head.uri is the request path from the client (e.g., "/v1/messages").
let finalURLString = target.baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
    + head.uri

guard let _ = URL(string: finalURLString) else {
    await Self.sendError(channel: channel, status: .badRequest, message: "Invalid upstream URL: \(finalURLString)")
    return
}
```

2. For passthrough requests (`target.isPassthrough == true`), the proxy must not replace API key headers. Update step 4 (header injection):

```swift
// 4. Build upstream request headers.
var upstreamHeaders = HTTPHeaders()
for (name, value) in head.headers {
    let lower = name.lowercased()
    if lower == "host" || lower == "connection" || lower == "transfer-encoding" { continue }
    upstreamHeaders.add(name: name, value: value)
}

if !target.isPassthrough {
    // Inject vendor API key for mapped requests.
    upstreamHeaders.remove(name: "authorization")
    upstreamHeaders.remove(name: "x-api-key")
    upstreamHeaders.add(name: "Authorization", value: "Bearer \(target.apiKey)")
    upstreamHeaders.add(name: "x-api-key", value: target.apiKey)
}

// Update Host header to match upstream destination.
if let host = URL(string: target.baseURL)?.host {
    upstreamHeaders.remove(name: "host")
    upstreamHeaders.add(name: "Host", value: host)
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`

---

### Task 8: Refactor ProxyServer — multi-port (one NIO listener per ClientConfig)

**Crystal ref:** phase-consolidation-crystal [D-009]

**Files:**
- Modify: `ModelProxy/Proxy/ProxyServer.swift` (full rewrite)

**Context:** The current `ProxyServer` binds a single port and exposes `boundPort: Int`. After this task it manages one channel per `ClientConfig`, each with its own `RequestRouter` initialized from the global `AppConfig` scoped to that client's `RoutingSnapshot`.

**Steps:**
1. Replace the entire file:

```swift
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import AsyncHTTPClient
import Observation

/// Manages one NIO listener per configured client port.
/// @MainActor: all state mutations happen on main thread for SwiftUI observers.
@MainActor
@Observable
final class ProxyServer {

    // MARK: - Observable State

    private(set) var isRunning: Bool = false
    private(set) var lastError: String? = nil
    /// Ports currently bound, keyed by clientName for display.
    private(set) var boundPorts: [String: Int] = [:]

    // MARK: - Internal State

    private struct ListenerSlot {
        let channel: any Channel
        let router: RequestRouter
        let clientName: String
    }

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var httpClient: HTTPClient?
    private var listeners: [ListenerSlot] = []

    // MARK: - Start

    /// Start one listener per client in `config`. Idempotent if already running.
    func start(config: AppConfig) async {
        guard !isRunning else { return }
        lastError = nil

        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.eventLoopGroup = group

        let clientConfig = HTTPClient.Configuration(
            redirectConfiguration: .disallow,
            timeout: .init(connect: .seconds(10), read: .seconds(120))
        )
        let client = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: clientConfig)
        self.httpClient = client

        var slots: [ListenerSlot] = []
        var errors: [String] = []

        for clientCfg in config.clients {
            let snapshot = RoutingSnapshot(from: config, for: clientCfg)
            let router = RequestRouter(snapshot: snapshot)

            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.pipeline.addHandler(
                            ProxyChannelHandler(router: router, httpClient: client)
                        )
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)

            do {
                let channel = try await bootstrap.bind(host: "127.0.0.1", port: clientCfg.port).get()
                let actualPort = channel.localAddress?.port ?? clientCfg.port
                print("[ProxyServer] \(clientCfg.clientName) listening on 127.0.0.1:\(actualPort)")
                slots.append(ListenerSlot(channel: channel, router: router, clientName: clientCfg.clientName))
                boundPorts[clientCfg.clientName] = actualPort
            } catch let err as NIOCore.IOError where err.errnoCode == EADDRINUSE {
                errors.append("Port \(clientCfg.port) (\(clientCfg.clientName)) already in use.")
            } catch {
                errors.append("Failed to start \(clientCfg.clientName): \(error.localizedDescription)")
            }
        }

        self.listeners = slots

        if slots.isEmpty {
            // No listeners started — surface first error and clean up.
            self.lastError = errors.first ?? "No clients configured."
            try? await client.shutdown()
            try? await group.shutdownGracefully()
            self.httpClient = nil
            self.eventLoopGroup = nil
        } else {
            self.isRunning = true
            if !errors.isEmpty {
                // Partial start — surface warnings but remain running.
                self.lastError = errors.joined(separator: " ")
            }
        }
    }

    // MARK: - Stop

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        boundPorts = [:]

        for slot in listeners {
            try? await slot.channel.close().get()
        }
        listeners = []

        try? await httpClient?.shutdown()
        httpClient = nil

        try? await eventLoopGroup?.shutdownGracefully()
        eventLoopGroup = nil

        print("[ProxyServer] Stopped.")
    }

    // MARK: - Hot Reload

    /// Push a new routing snapshot to all listeners that match by clientName.
    /// Called after ConfigStore.save(); does not restart any channel.
    func updateRouting(config: AppConfig) {
        for slot in listeners {
            guard let clientCfg = config.clients.first(where: { $0.clientName == slot.clientName }) else {
                continue
            }
            let newSnapshot = RoutingSnapshot(from: config, for: clientCfg)
            Task {
                await slot.router.updateSnapshot(newSnapshot)
            }
        }
    }
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`

---

### Task 9: Wire proxy startup to app launch in ModelProxyApp

**Crystal ref:** phase-consolidation-crystal [D-006], [D-007]

**Files:**
- Modify: `ModelProxy/App/ModelProxyApp.swift` (full rewrite)

**Steps:**
1. Move proxy start from `StatusPopover.onAppear` to `ModelProxyApp`. Pass `configStore` as an environment object to `StatusPopover` and to `SettingsView`.

```swift
import SwiftUI

@main
struct ModelProxyApp: App {
    @State private var configStore = ConfigStore()
    @State private var proxyServer = ProxyServer()

    var body: some Scene {
        MenuBarExtra("ModelProxy", systemImage: "arrow.triangle.2.circlepath") {
            StatusPopover()
                .environment(configStore)
                .environment(proxyServer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(configStore)
                .environment(proxyServer)
        }
    }

    init() {
        // Proxy start is triggered via .task in StatusPopover (see Task 15).
        // ModelProxyApp.init() cannot call async functions directly.
    }
}
```

Note: The actual async `proxyServer.start()` call moves to `StatusPopover.task` in Task 15 because `App.init` is synchronous. Using `.task` on the MenuBarExtra content is the correct pattern.

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`

---

### Task 11: Hot-reload wiring — ConfigStore triggers snapshot swap

**Crystal ref:** phase-consolidation-crystal, DP-003 in dev-guide

**Files:**
- Modify: `ModelProxy/Services/ConfigStore.swift`

**Steps:**
1. Add a `saveAndReload(proxyServer:)` method that saves config then calls `proxyServer.updateRouting(config:)`. All Settings UI mutations will call this instead of `save()` directly.

Add after the existing `save()` method:

```swift
/// Save config and push updated routing snapshot to running listeners.
/// Call this from Settings UI after any config change.
func saveAndReload(proxyServer: ProxyServer) {
    save()
    proxyServer.updateRouting(config: config)
}
```

2. The Settings views (Tasks 12–14) will call `configStore.saveAndReload(proxyServer:)` on every field change using `.onChange`. No explicit Save button anywhere.

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`

---

### Task 12: SettingsView shell — TabView with three tabs

**Crystal ref:** phase-consolidation-crystal [D-008]

**Files:**
- Create: `ModelProxy/Views/SettingsView.swift`

**Steps:**
1. Create the file. Three tabs: Clients, Vendors, Routing. Uses macOS `Form` container at each tab root (HIG requirement). No Save button anywhere.

```swift
import SwiftUI

struct SettingsView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer

    var body: some View {
        TabView {
            ClientsTabView()
                .tabItem { Label("Clients", systemImage: "desktopcomputer") }

            VendorsTabView()
                .tabItem { Label("Vendors", systemImage: "server.rack") }

            RoutingTabView()
                .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
        }
        .frame(minWidth: 520, minHeight: 380)
        .environment(configStore)
        .environment(proxyServer)
    }
}

#Preview {
    SettingsView()
        .environment(ConfigStore())
        .environment(ProxyServer())
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED` (compile-only; ClientsTabView etc. stubs needed — create empty structs before building)

Create stubs in their respective files (will be filled in Tasks 12-14):
- `ModelProxy/Views/ClientsTabView.swift` — `struct ClientsTabView: View { var body: some View { Text("Clients") } }`
- `ModelProxy/Views/VendorsTabView.swift` — `struct VendorsTabView: View { var body: some View { Text("Vendors") } }`
- `ModelProxy/Views/RoutingTabView.swift` — `struct RoutingTabView: View { var body: some View { Text("Routing") } }`

---

### Task 13: Clients tab UI

**Crystal ref:** phase-consolidation-crystal [D-009], [D-010]

**Files:**
- Modify: `ModelProxy/Views/ClientsTabView.swift` (replace stub)

**Steps:**
1. Replace the stub with the full implementation. Each client row shows: port (numeric field, 1024-65535 validation), defaultUpstream (URL text field), and env export command (read-only + copy button with "Copied" flash).

```swift
import SwiftUI

struct ClientsTabView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer

    var body: some View {
        Form {
            ForEach(configStore.config.clients.indices, id: \.self) { index in
                ClientRowSection(index: index)
                    .environment(configStore)
                    .environment(proxyServer)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ClientRowSection: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    let index: Int

    @State private var portText: String = ""
    @State private var showCopied: Bool = false

    private var client: ClientConfig { configStore.config.clients[index] }

    private var envExportCommand: String {
        // Crystal [D-010]: complete executable command including tool launch
        let toolCommand: String
        switch client.clientName.lowercased() {
        case let n where n.contains("claude"):
            toolCommand = "claude"
        case let n where n.contains("codex"):
            toolCommand = "codex"
        default:
            toolCommand = client.clientName.lowercased()
        }
        return "export ANTHROPIC_BASE_URL=http://localhost:\(client.port) && \(toolCommand)"
    }

    var body: some View {
        Section(client.clientName) {
            // Port field
            HStack {
                Text("Port")
                Spacer()
                TextField("1024-65535", text: $portText)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .onAppear { portText = "\(client.port)" }
                    .onChange(of: portText) { _, newValue in
                        guard let port = Int(newValue), (1024...65535).contains(port) else { return }
                        configStore.config.clients[index].port = port
                        configStore.saveAndReload(proxyServer: proxyServer)
                    }
            }

            // Default upstream field
            HStack {
                Text("Default upstream")
                Spacer()
                TextField("https://api.anthropic.com", text: Binding(
                    get: { configStore.config.clients[index].defaultUpstream },
                    set: { newValue in
                        configStore.config.clients[index].defaultUpstream = newValue
                        configStore.saveAndReload(proxyServer: proxyServer)
                    }
                ))
                .frame(width: 260)
                .multilineTextAlignment(.trailing)
            }

            // Env export command row
            HStack {
                Text(envExportCommand)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(showCopied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(envExportCommand, forType: .string)
                    showCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopied = false
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showCopied ? .green : .accentColor)
            }
        }
    }
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`

Manual check (after build): open Settings > Clients tab; verify port field accepts only integers 1024-65535; verify copy button flashes "Copied" for ~1.5 seconds.

---

### Task 14: Vendors tab UI — list, add/edit sheet, delete with confirmation

**Crystal ref:** phase-consolidation-crystal [D-008]

**Files:**
- Modify: `ModelProxy/Views/VendorsTabView.swift` (replace stub)
- Create: `ModelProxy/Views/VendorEditSheet.swift`

**Steps:**
1. Create `ModelProxy/Views/VendorEditSheet.swift`:

```swift
import SwiftUI

/// Sheet for adding a new vendor or editing an existing one.
struct VendorEditSheet: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(\.dismiss) private var dismiss

    /// nil = adding new; non-nil = editing existing (matched by id)
    let editingVendorID: UUID?

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var showAPIKey: Bool = false

    private var isEditing: Bool { editingVendorID != nil }
    private var title: String { isEditing ? "Edit Vendor" : "Add Vendor" }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Vendor Details") {
                    TextField("Name", text: $name)
                    TextField("Base URL", text: $baseURL)
                        .autocorrectionDisabled()

                    HStack {
                        if showAPIKey {
                            TextField("API Key", text: $apiKey)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("API Key", text: $apiKey)
                        }
                        Button(showAPIKey ? "Hide" : "Reveal") {
                            showAPIKey.toggle()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add") {
                    commitVendor()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 420)
        .navigationTitle(title)
        .onAppear {
            if let vid = editingVendorID,
               let vendor = configStore.config.vendors.first(where: { $0.id == vid }) {
                name = vendor.name
                baseURL = vendor.baseURL
                apiKey = vendor.apiKey
            }
        }
    }

    private func commitVendor() {
        if let vid = editingVendorID,
           let idx = configStore.config.vendors.firstIndex(where: { $0.id == vid }) {
            configStore.config.vendors[idx].name = name
            configStore.config.vendors[idx].baseURL = baseURL
            configStore.config.vendors[idx].apiKey = apiKey
        } else {
            let v = Vendor(name: name, baseURL: baseURL, apiKey: apiKey)
            configStore.config.vendors.append(v)
        }
        configStore.saveAndReload(proxyServer: proxyServer)
    }
}
```

2. Replace `ModelProxy/Views/VendorsTabView.swift` stub:

```swift
import SwiftUI

struct VendorsTabView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer

    @State private var showAddSheet: Bool = false
    @State private var editingVendorID: UUID? = nil
    @State private var deletingVendorID: UUID? = nil

    var body: some View {
        Form {
            Section {
                if configStore.config.vendors.isEmpty {
                    Text("No vendors configured. Add one to enable routing.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(configStore.config.vendors) { vendor in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vendor.name)
                                    .fontWeight(.medium)
                                Text(vendor.baseURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") {
                                editingVendorID = vendor.id
                            }
                            .buttonStyle(.borderless)
                            Button("Delete") {
                                deletingVendorID = vendor.id
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                HStack {
                    Text("Vendors")
                    Spacer()
                    Button("Add Vendor") { showAddSheet = true }
                        .buttonStyle(.borderless)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showAddSheet) {
            VendorEditSheet(editingVendorID: nil)
                .environment(configStore)
                .environment(proxyServer)
        }
        .sheet(item: $editingVendorID) { vid in
            VendorEditSheet(editingVendorID: vid)
                .environment(configStore)
                .environment(proxyServer)
        }
        .confirmationDialog(
            "Delete vendor?",
            isPresented: Binding(
                get: { deletingVendorID != nil },
                set: { if !$0 { deletingVendorID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let vid = deletingVendorID {
                    deleteVendor(id: vid)
                }
                deletingVendorID = nil
            }
            Button("Cancel", role: .cancel) { deletingVendorID = nil }
        } message: {
            if let vid = deletingVendorID,
               let vendor = configStore.config.vendors.first(where: { $0.id == vid }) {
                let mappingCount = configStore.config.modelMappings
                    .filter { $0.targetVendorID == vid }.count
                if mappingCount > 0 {
                    Text("\"\(vendor.name)\" has \(mappingCount) routing rule(s) that will also be removed.")
                } else {
                    Text("Remove \"\(vendor.name)\"? This cannot be undone.")
                }
            }
        }
    }

    private func deleteVendor(id: UUID) {
        // Remove vendor and all its mappings.
        configStore.config.vendors.removeAll { $0.id == id }
        configStore.config.modelMappings.removeAll { $0.targetVendorID == id }
        configStore.saveAndReload(proxyServer: proxyServer)
    }
}

// Make UUID Identifiable for .sheet(item:) binding
extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`

Manual check: add a vendor; it appears in list. Edit it; changes persist after closing sheet. Delete it; confirmation dialog shows mapping count warning if applicable.

---

### Task 15: Routing tab UI — mapping list, add, delete

**Crystal ref:** proxy-routing-crystal [D-003]; dev-guide DP-002

**Files:**
- Modify: `ModelProxy/Views/RoutingTabView.swift` (replace stub)

**Steps:**
1. Source model picker uses a hardcoded list of known Anthropic models (the list from dev-guide DP-002). Target model is free-text. Target vendor is a picker from configured vendors.

```swift
import SwiftUI

struct RoutingTabView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer

    @State private var showAddRow: Bool = false

    // Known Anthropic model IDs for the source picker.
    private let knownAnthropicModels: [String] = [
        "claude-haiku-4-5",
        "claude-sonnet-4-6",
        "claude-opus-4-6",
        "claude-3-5-haiku-20241022",
        "claude-3-5-sonnet-20241022",
        "claude-3-opus-20240229",
    ]

    var body: some View {
        Form {
            Section {
                if configStore.config.modelMappings.isEmpty && !showAddRow {
                    Text("No routing rules. Add one to redirect Anthropic models to other vendors.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }

                ForEach(configStore.config.modelMappings) { mapping in
                    MappingRow(mapping: mapping)
                        .environment(configStore)
                        .environment(proxyServer)
                }

                if showAddRow {
                    AddMappingRow(
                        knownAnthropicModels: knownAnthropicModels,
                        onAdd: { newMapping in
                            configStore.config.modelMappings.append(newMapping)
                            configStore.saveAndReload(proxyServer: proxyServer)
                            showAddRow = false
                        },
                        onCancel: { showAddRow = false }
                    )
                    .environment(configStore)
                }

            } header: {
                HStack {
                    Text("Model Routing Rules")
                    Spacer()
                    Button("Add Rule") { showAddRow = true }
                        .buttonStyle(.borderless)
                        .disabled(showAddRow || configStore.config.vendors.isEmpty)
                }
            } footer: {
                if configStore.config.vendors.isEmpty {
                    Text("Add at least one vendor in the Vendors tab before creating routing rules.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct MappingRow: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    let mapping: ModelMapping

    private var vendorName: String {
        configStore.config.vendors.first(where: { $0.id == mapping.targetVendorID })?.name ?? "Unknown vendor"
    }

    var body: some View {
        HStack {
            Text(mapping.sourceModel)
                .font(.system(.body, design: .monospaced))
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(mapping.targetModel)
                    .font(.system(.body, design: .monospaced))
                Text(vendorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Delete") {
                configStore.config.modelMappings.removeAll { $0.id == mapping.id }
                configStore.saveAndReload(proxyServer: proxyServer)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
    }
}

private struct AddMappingRow: View {
    @Environment(ConfigStore.self) private var configStore
    let knownAnthropicModels: [String]
    let onAdd: (ModelMapping) -> Void
    let onCancel: () -> Void

    @State private var selectedSourceModel: String = ""
    @State private var targetModel: String = ""
    @State private var selectedVendorID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source model", selection: $selectedSourceModel) {
                Text("Select...").tag("")
                ForEach(knownAnthropicModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            TextField("Target model (vendor name)", text: $targetModel)
                .autocorrectionDisabled()
            Picker("Target vendor", selection: $selectedVendorID) {
                Text("Select...").tag(UUID?.none)
                ForEach(configStore.config.vendors) { vendor in
                    Text(vendor.name).tag(UUID?.some(vendor.id))
                }
            }
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
                Spacer()
                Button("Add") {
                    guard !selectedSourceModel.isEmpty,
                          !targetModel.trimmingCharacters(in: .whitespaces).isEmpty,
                          let vendorID = selectedVendorID else { return }
                    let mapping = ModelMapping(
                        sourceModel: selectedSourceModel,
                        targetModel: targetModel.trimmingCharacters(in: .whitespaces),
                        targetVendorID: vendorID
                    )
                    onAdd(mapping)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    selectedSourceModel.isEmpty ||
                    targetModel.trimmingCharacters(in: .whitespaces).isEmpty ||
                    selectedVendorID == nil
                )
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            selectedSourceModel = knownAnthropicModels.first ?? ""
            selectedVendorID = configStore.config.vendors.first?.id
        }
    }
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`

Manual check: add a mapping (select source model, enter target model, select vendor) — it appears in list. Delete it — it disappears immediately.

---

### Task 10: Update StatusPopover — remove startProxy call, add Settings entry + Start button

**Crystal ref:** phase-consolidation-crystal [D-006], [D-007]

**Files:**
- Modify: `ModelProxy/Views/StatusPopover.swift` (full rewrite)

**Steps:**
1. Remove `startProxyIfNeeded()` and `onAppear`. Add `.task` modifier for proxy auto-start at first appearance. Add Settings button (opens Settings window via `openSettings`). Add Start button when proxy is not running.

```swift
import SwiftUI

struct StatusPopover: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 12) {
            Text("ModelProxy")
                .font(.headline)

            statusSection

            Divider()

            controlSection
        }
        .padding()
        .frame(width: 300)
        .task {
            // Start proxy on first appearance if not already running.
            guard !proxyServer.isRunning else { return }
            await proxyServer.start(config: configStore.config)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        if proxyServer.isRunning {
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Running").font(.caption)
                }
                let portList = proxyServer.boundPorts.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ", ")
                Text("127.0.0.1 — \(portList)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else if let error = proxyServer.lastError {
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text("Error").font(.caption)
                }
                Text(error)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(3).multilineTextAlignment(.center)
            }
        } else {
            HStack {
                ProgressView().scaleEffect(0.6)
                Text("Starting...").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlSection: some View {
        if proxyServer.isRunning {
            Button(action: {
                Task { await proxyServer.stop() }
            }) {
                Text("Stop Proxy").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } else {
            Button(action: {
                Task { await proxyServer.start(config: configStore.config) }
            }) {
                Text("Start Proxy").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }

        Button(action: { openSettings() }) {
            Label("Settings...", systemImage: "gear").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)

        Button("Quit ModelProxy") {
            NSApplication.shared.terminate(nil)
        }
        .buttonStyle(.bordered)
    }
}

#Preview {
    StatusPopover()
        .environment(ConfigStore())
        .environment(ProxyServer())
}
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`

Manual check: popover shows green "Running" status with port list; Settings button opens the Settings window; Stop/Start buttons toggle proxy state.

---

### Task 16: Build clean + smoke test

**Files:** None (verification only)

**Steps:**
1. Full clean build:

```
xcodebuild clean -scheme ModelProxy -destination "platform=macOS"
xcodebuild -scheme ModelProxy -destination "platform=macOS" build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED` with 0 errors.

2. Verify no API key leaks in logging. Search for any `print` statements that could include API key:

```
grep -n "apiKey\|api_key\|x-api-key" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ProxyForwarder.swift
```

Expected: no `print(` calls near those lines.

3. Verify no `modelPatterns` or `ModelRoute` references remain:

```
grep -rn "modelPatterns\|ModelRoute" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/
```

Expected: no matches.

4. Verify `ContentView` and `Item` are gone:

```
ls /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/ContentView.swift 2>&1
ls /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Item.swift 2>&1
```

Expected: `No such file or directory` for both.

5. Verify config.json migration (manual): delete `~/Library/Application Support/ModelProxy/config.json`, run the app, confirm new config.json is created with `modelMappings: []` and two clients (Claude Code on 8080, Codex on 8081).

```
cat ~/Library/Application\ Support/ModelProxy/config.json | python3 -m json.tool | head -40
```

Expected: valid JSON with `clients` array containing `defaultUpstream` fields and an empty `modelMappings` array.

6. End-to-end routing smoke test (requires a configured vendor + mapping):
- Open Settings, add a test vendor (name: "Test", baseURL: `http://localhost:9999`, apiKey: `test-key`)
- Add a mapping: `claude-haiku-4-5` -> `test-model` -> Test vendor
- In terminal: `curl -s -X POST http://localhost:8080/v1/messages -H "Content-Type: application/json" -H "x-api-key: original-key" -d '{"model":"claude-haiku-4-5","messages":[{"role":"user","content":"hi"}],"max_tokens":10}' -w "\n%{http_code}"`
- Expected: connection refused from `localhost:9999` (correct — proxy attempted to forward to test vendor) not from `localhost:8080`

---

## Decisions

### [DP-001] UUID retroactive conformance to Identifiable (blocking)

**Context:** Task 13 uses `extension UUID: @retroactive Identifiable` to support `.sheet(item: $editingVendorID)` where the binding holds a `UUID?`. Swift 5.7+ requires `@retroactive` for conformances in modules you don't own. If the project already has this extension elsewhere, a duplicate will cause a compile error.

**Options:**
- A: Keep `extension UUID: @retroactive Identifiable` in `VendorsTabView.swift` — simple, works if no duplicate exists
- B: Use a local wrapper `struct IdentifiableUUID: Identifiable { let id: UUID }` instead — avoids retroactive conformance entirely
- C: Change the sheet trigger from `UUID?` binding to `Bool` + a separate `@State var editingVendor: Vendor?` — idiomatic SwiftUI pattern, no retroactive conformance needed

**Chosen:** C — use `@State private var editingVendor: Vendor?` and `.sheet(item: $editingVendor)` since `Vendor` already conforms to `Identifiable`. Remove `extension UUID: @retroactive Identifiable` from Task 14.

### [DP-002] Port change behavior: transparent restart vs. requires app restart (recommended)

**Context:** When the user changes a client's port in the Clients tab, the existing NIO channel is bound to the old port. The acceptance criteria says "proxy picks up new port (may require restart of listener, but transparent to user)." The current hot-reload path (`updateRouting`) only swaps the routing snapshot; it does not rebind the port.

**Options:**
- A: Port change triggers stop + restart of affected listener only (auto, transparent) — implementation requires partial stop/start in `ProxyServer`, touching NIO lifecycle. Moderate complexity.
- B: Port change takes effect after full proxy Stop + Start (user-initiated via Stop/Start buttons) — simple, no partial restart logic. User must manually stop and start.
- C: Port change takes effect after app restart — simplest but poor UX.

**Chosen:** B — show a banner in the Clients tab ("Port change takes effect after stopping and restarting the proxy") when port differs from currently bound port. Minimal complexity, honest UX. Option A can be added in a follow-up phase.

---
## Verification
- **Verdict:** Approved (after revision)
- **Date:** 2026-03-06
- **Revisions applied:**
  - Task ordering: StatusPopover (old Task 15) moved to Task 10, immediately after Task 9, to fix compile break
  - Added Task 5b: comprehensive test updates for model refactor (DP-001 chosen: B)
  - Task numbers shifted: old 10-14 → 11-15
- **Report:** `.claude/reviews/plan-verifier-2026-03-06-163628.md`
