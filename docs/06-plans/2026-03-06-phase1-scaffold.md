# Phase 1: Project Scaffold and Config Models Implementation Plan

**Goal:** Xcode project is cleaned up from its default template state, all data models are defined with JSON Codable + @Observable, config persistence is working, and the app launches as a menu bar app with an empty popover.

**Architecture:** The Xcode project already exists but was created from the default macOS SwiftData template — it needs to be stripped of SwiftData, WindowGroup, ContentView, and Item.swift scaffolding, then rebuilt with the correct structure. All models are pure Swift structs/classes with Codable conformance; `AppConfig` is the single root `@Observable` class loaded by `ConfigStore` at launch and injected into the environment. The app entry uses `MenuBarExtra` (window-style) with a placeholder `StatusPopover`, plus an empty `Settings` scene wired for future use.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, SwiftNIO 2.x + NIOHTTP1, AsyncHTTPClient, macOS 14+ (Sonoma)

**Design doc:** none

**Design analysis:** none

**Crystal file:** none

---

## Pre-flight: Existing State

The Xcode project at `/Users/norvyn/Code/Projects/ModelProxy` was generated from the standard macOS SwiftData template. The following files exist but are incompatible with the target architecture and must be replaced or deleted:

| File | Current state | Action |
|------|--------------|--------|
| `ModelProxy/ModelProxyApp.swift` | Uses SwiftData + `WindowGroup` | Replace entirely |
| `ModelProxy/ContentView.swift` | SwiftData-backed list view | Delete |
| `ModelProxy/Item.swift` | `@Model` SwiftData entity | Delete |

Current project settings that need to change:
- `SWIFT_VERSION = 5.0` → must be set to `6.0`
- `SWIFT_STRICT_CONCURRENCY` → must be set to `complete`
- `MACOSX_DEPLOYMENT_TARGET = 15.7` → already satisfies macOS 14+ requirement (keep as-is)

---

## Task 1: Package Dependencies

**Files:**
- Modify: `ModelProxy.xcodeproj` (via Xcode UI — no direct file edit)

**Steps:**

1. Open `ModelProxy.xcodeproj` in Xcode.

2. Add Swift Package dependencies. Go to File > Add Package Dependencies and add each URL:

   - **swift-nio**: `https://github.com/apple/swift-nio.git`
     - Version rule: Up to Next Major from `2.65.0`
     - Products to add: `NIO`, `NIOCore`, `NIOPosix`, `NIOHTTP1`

   - **async-http-client**: `https://github.com/swift-server/async-http-client.git`
     - Version rule: Up to Next Major from `1.21.0`
     - Products to add: `AsyncHTTPClient`

3. In the target's "Frameworks, Libraries, and Embedded Content" section, confirm these products are linked to the `ModelProxy` target: `NIO`, `NIOCore`, `NIOPosix`, `NIOHTTP1`, `AsyncHTTPClient`. (The test targets do not need these.)

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (the default template files still compile at this point; Swift version change in Task 2 may emit warnings — those are resolved in subsequent tasks)

---

## Task 2: Swift 6 Strict Concurrency Build Settings

**Files:**
- Modify: `ModelProxy.xcodeproj/project.pbxproj` — build settings for the `ModelProxy` target (both Debug and Release configurations)

**Steps:**

1. In Xcode, select the `ModelProxy` project in the navigator, then select the `ModelProxy` target (not the test targets).

2. Go to Build Settings. Search for "Swift Language Version" and set it to **Swift 6** for both Debug and Release.

3. Search for "Strict Concurrency Checking" (`SWIFT_STRICT_CONCURRENCY`) and set it to **Complete** for both Debug and Release.

4. Do the same for the `ModelProxyTests` target (Swift 6, Complete). Leave `ModelProxyUITests` at defaults.

5. The current `Item.swift`, `ContentView.swift`, and `ModelProxyApp.swift` will emit errors under Swift 6 + strict concurrency. That is expected — they will be replaced in Task 3.

**Verify:**
After Task 3 (app entry rewrite), run the full build and confirm zero warnings about concurrency. This build setting change is a prerequisite; verification happens at end of Task 3.

---

## Task 3: Clean Up Template Files and Rewrite App Entry

**Files:**
- Delete: `ModelProxy/ContentView.swift`
- Delete: `ModelProxy/Item.swift`
- Modify: `ModelProxy/ModelProxyApp.swift` (full rewrite)
- Create: `ModelProxy/Views/StatusPopover.swift`

**Steps:**

1. In Xcode's file navigator, delete `ContentView.swift` and `Item.swift`. Choose "Move to Trash" (not "Remove Reference").

2. Create the folder group `ModelProxy/Views/` in Xcode (New Group Without Folder, rename to `Views`). Also create `ModelProxy/App/`, `ModelProxy/Models/`, `ModelProxy/Services/` as group folders for later tasks.

   Note: Xcode 16+ uses filesystem-synced groups. Create the actual directories on disk so Xcode picks them up automatically:
   ```
   mkdir -p /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/App
   mkdir -p /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views
   mkdir -p /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Models
   mkdir -p /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services
   mkdir -p /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy
   ```

3. Configure entitlements for sandbox mode (required for Network and file access):
   - In Xcode, select the `ModelProxy` target
   - Go to Signing & Capabilities
   - If no Entitlements file exists, click "+ Capability" and add "App Sandbox"
   - This creates `ModelProxy.entitlements` file
   - Open `ModelProxy.entitlements` (or create it manually at `ModelProxy/ModelProxy.entitlements`):
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>com.apple.security.app-sandbox</key>
       <true/>
       <key>com.apple.security.network.server</key>
       <true/>
       <key>com.apple.security.network.client</key>
       <true/>
   </dict>
   </plist>
   ```
   This allows the sandboxed app to:
   - Run a local HTTP server (network.server) for the proxy
   - Make outbound HTTP requests to vendor APIs (network.client)
   - Use the default sandbox Application Support path: `~/Library/Containers/com.90percent.ModelProxy/Data/Library/Application Support/ModelProxy/config.json`

   **Important:** Sandbox redirects Application Support to a container path. ConfigStore will handle this automatically via `FileManager.urls(for: .applicationSupportDirectory)`, which respects the sandbox environment.

   After creating the `.entitlements` file, verify the build setting is configured:
   - In Xcode, select the `ModelProxy` target
   - Go to Build Settings
   - Search for "Code Sign Entitlements" (`CODE_SIGN_ENTITLEMENTS`)
   - For both Debug and Release, set the value to: `ModelProxy/ModelProxy.entitlements`
   - Without this setting, the entitlements file is ignored and the sandbox will not have network permissions.

4. Move `ModelProxyApp.swift` into `ModelProxy/App/`. In Terminal:
   ```
   mv /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/ModelProxyApp.swift \
      /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/App/ModelProxyApp.swift
   ```

4. Replace the entire contents of `ModelProxy/App/ModelProxyApp.swift` with:

   ```swift
   import SwiftUI

   @main
   struct ModelProxyApp: App {
       @State private var configStore = ConfigStore()

       var body: some Scene {
           MenuBarExtra("ModelProxy", systemImage: "arrow.triangle.2.circlepath") {
               StatusPopover()
                   .environment(configStore.config)
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

   Note: Removed unused `@State private var isPopoverShown` to eliminate Swift 6 warning.

   Note: `ConfigStore` and `StatusPopover` are defined in Tasks 7 and 5 respectively. This file will not compile until those tasks are complete. Proceed through the tasks in order.

5. Configure Info.plist for menu bar-only app:
   - In Xcode, select the `ModelProxy` target
   - Go to Info tab
   - Add key `LSUIElement` (Application is agent (UIElement)) with value `YES`
   - This hides the Dock icon; the app is menu bar-only
   Alternatively, edit `ModelProxy/Info.plist` directly (if it exists) and add:
   ```xml
   <key>LSUIElement</key>
   <true/>
   ```

6. Create `ModelProxy/Views/StatusPopover.swift`:

   ```swift
   import SwiftUI

   struct StatusPopover: View {
       var body: some View {
           VStack(spacing: 12) {
               Text("ModelProxy")
                   .font(.headline)
               Text("Proxy not yet configured.")
                   .font(.caption)
                   .foregroundStyle(.secondary)
           }
           .padding()
           .frame(width: 280)
       }
   }

   #Preview {
       StatusPopover()
   }
   ```

**Verify:**
After Tasks 5–7 are complete, run:
`xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **` with no `error:` lines.

---

## Task 4: `Vendor` Model

**Files:**
- Create: `ModelProxy/Models/Vendor.swift`

**Steps:**

1. Create `ModelProxy/Models/Vendor.swift`:

   ```swift
   import Foundation

   /// A single upstream API provider.
   struct Vendor: Identifiable, Codable, Equatable, Sendable {
       var id: UUID
       var name: String
       /// Base URL of the vendor's API, e.g. "https://dashscope.aliyuncs.com/compatible-mode/v1"
       var baseURL: String
       /// API key stored in plaintext in config.json (personal-use tool; not stored in Keychain by design).
       var apiKey: String
       /// Model identifiers or prefixes this vendor handles.
       /// Matching priority: exact match beats prefix match.
       var modelPatterns: [String]

       init(
           id: UUID = UUID(),
           name: String,
           baseURL: String,
           apiKey: String,
           modelPatterns: [String] = []
       ) {
           self.id = id
           self.name = name
           self.baseURL = baseURL
           self.apiKey = apiKey
           self.modelPatterns = modelPatterns
       }
   }
   ```

**Verify:**
This file has no external dependencies. Confirm it compiles in isolation:
`xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "Vendor.swift|error:"`
Expected: no errors referencing `Vendor.swift`.

---

## Task 5: `ClientConfig` Model

**Files:**
- Create: `ModelProxy/Models/ClientConfig.swift`

**Steps:**

1. Create `ModelProxy/Models/ClientConfig.swift`:

   ```swift
   import Foundation

   /// Configuration for a single AI client (e.g., Claude Code or Codex).
   struct ClientConfig: Identifiable, Codable, Equatable, Sendable {
       var id: UUID
       /// Display name, e.g. "Claude Code" or "Codex".
       var clientName: String
       /// Localhost port this client's proxy listener binds to.
       var port: Int
       /// Maps an Anthropic model ID (as presented to the client) to a vendor's UUID.
       /// E.g. ["claude-haiku-4-5": <vendor-uuid>]
       /// When the incoming request model matches a key here, the request is routed
       /// to the corresponding vendor. Unmatched models fall back to `defaultVendorID`.
       var modelMappings: [String: UUID]
       /// Vendor to route to when no model mapping matches. Nil means forward to api.anthropic.com.
       var defaultVendorID: UUID?

       init(
           id: UUID = UUID(),
           clientName: String,
           port: Int,
           modelMappings: [String: UUID] = [:],
           defaultVendorID: UUID? = nil
       ) {
           self.id = id
           self.clientName = clientName
           self.port = port
           self.modelMappings = modelMappings
           self.defaultVendorID = defaultVendorID
       }
   }
   ```

**Verify:**
`xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "ClientConfig.swift|error:"`
Expected: no errors referencing `ClientConfig.swift`.

---

## Task 6: `TokenStats` Model

**Files:**
- Create: `ModelProxy/Models/TokenStats.swift`

**Steps:**

1. Create `ModelProxy/Models/TokenStats.swift`:

   ```swift
   import Foundation

   /// Per-model token usage record (input + output).
   /// Cache read tokens are folded into inputTokens (per DP-003 arch note in Phase 6).
   struct ModelTokenRecord: Codable, Equatable, Sendable {
       var inputTokens: Int
       var outputTokens: Int

       init(inputTokens: Int = 0, outputTokens: Int = 0) {
           self.inputTokens = inputTokens
           self.outputTokens = outputTokens
       }
   }

   /// Daily token usage snapshot persisted to disk.
   /// Key: vendor ID string -> [model ID string -> record]
   struct DailyTokenSnapshot: Codable, Sendable {
       /// Calendar date string in ISO 8601 format, e.g. "2026-03-06".
       var date: String
       /// Outer key: vendor UUID string. Inner key: model ID string.
       var usageByVendorAndModel: [String: [String: ModelTokenRecord]]

       init(date: String, usageByVendorAndModel: [String: [String: ModelTokenRecord]] = [:]) {
           self.date = date
           self.usageByVendorAndModel = usageByVendorAndModel
       }
   }

   /// In-memory accumulator for token stats; not @Observable (managed by a future TokenStatsStore actor).
   /// This Phase 1 definition establishes the data shape used in Phase 6.
   struct TokenStats: Sendable {
       /// Outer key: vendor UUID. Inner key: model ID.
       private(set) var records: [UUID: [String: ModelTokenRecord]] = [:]

       mutating func add(vendorID: UUID, modelID: String, input: Int, output: Int) {
           records[vendorID, default: [:]][modelID, default: ModelTokenRecord()].inputTokens += input
           records[vendorID, default: [:]][modelID, default: ModelTokenRecord()].outputTokens += output
       }

       func totalInputTokens() -> Int {
           records.values.flatMap(\.values).map(\.inputTokens).reduce(0, +)
       }

       func totalOutputTokens() -> Int {
           records.values.flatMap(\.values).map(\.outputTokens).reduce(0, +)
       }
   }
   ```

**Verify:**
`xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "TokenStats.swift|error:"`
Expected: no errors referencing `TokenStats.swift`.

---

## Task 7: `AppConfig` Model

**Files:**
- Create: `ModelProxy/Models/AppConfig.swift`

**Steps:**

1. Create `ModelProxy/Models/AppConfig.swift`:

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

       // MARK: - Init

       init(vendors: [Vendor] = [], clients: [ClientConfig] = []) {
           self.vendors = vendors
           self.clients = clients
       }

       // MARK: - Codable

       enum CodingKeys: String, CodingKey {
           case vendors
           case clients
       }

       required init(from decoder: Decoder) throws {
           let container = try decoder.container(keyedBy: CodingKeys.self)
           vendors = try container.decode([Vendor].self, forKey: .vendors)
           clients = try container.decode([ClientConfig].self, forKey: .clients)
       }

       func encode(to encoder: Encoder) throws {
           var container = encoder.container(keyedBy: CodingKeys.self)
           try container.encode(vendors, forKey: .vendors)
           try container.encode(clients, forKey: .clients)
       }
   }

   // MARK: - Default config

   extension AppConfig {
       /// Sensible defaults created on first launch.
       static func makeDefault() -> AppConfig {
           let anthropicVendorID = UUID()
           let anthropicVendor = Vendor(
               id: anthropicVendorID,
               name: "Anthropic",
               baseURL: "https://api.anthropic.com/v1",
               apiKey: "",
               modelPatterns: ["claude-"]
           )
           let claudeCodeClient = ClientConfig(
               clientName: "Claude Code",
               port: 8080,
               modelMappings: [:],
               defaultVendorID: anthropicVendorID
           )
           return AppConfig(vendors: [anthropicVendor], clients: [claudeCodeClient])
       }
   }
   ```

   Important: `@Observable` macro generates observation tracking storage that is not `Sendable` by default. In Swift 6, `AppConfig` must be used from the `@MainActor` context when mutated from SwiftUI. `ConfigStore` (next task) will be `@MainActor`-isolated. If the compiler emits a `Sendable` warning for `AppConfig`, annotate the class declaration with `@MainActor`.

**Verify:**
`xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "AppConfig.swift|error:"`
Expected: no errors referencing `AppConfig.swift`.

---

## Task 8: `ConfigStore` Service

**Files:**
- Create: `ModelProxy/Services/ConfigStore.swift`

**Steps:**

1. Create `ModelProxy/Services/ConfigStore.swift`:

   ```swift
   import Foundation
   import Observation

   /// Loads and saves AppConfig to ~/Library/Application Support/ModelProxy/config.json.
   /// @MainActor because AppConfig is @Observable and mutated from SwiftUI context.
   @MainActor
   @Observable
   final class ConfigStore {
       private(set) var config: AppConfig

       private static let appSupportURL: URL = {
           let base = FileManager.default.urls(
               for: .applicationSupportDirectory,
               in: .userDomainMask
           ).first!
           return base.appendingPathComponent("ModelProxy", isDirectory: true)
       }()

       private static var configFileURL: URL {
           appSupportURL.appendingPathComponent("config.json")
       }

       // MARK: - Init

       init() {
           self.config = ConfigStore.loadOrCreateDefault()
       }

       // MARK: - Load

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
               return try JSONDecoder().decode(AppConfig.self, from: data)
           } catch {
               // Corrupt config: reset to defaults.
               // Phase 7 will add a user confirmation dialog before resetting.
               print("[ConfigStore] Failed to decode config.json: \(error). Resetting to defaults.")
               let defaults = AppConfig.makeDefault()
               try? JSONEncoder.pretty.encode(defaults).write(to: fileURL)
               return defaults
           }
       }

       // MARK: - Save

       func save() {
           do {
               let data = try JSONEncoder.pretty.encode(config)
               try data.write(to: ConfigStore.configFileURL, options: .atomic)
           } catch {
               print("[ConfigStore] Failed to save config.json: \(error)")
           }
       }
   }

   // MARK: - JSONEncoder helper

   private extension JSONEncoder {
       nonisolated(unsafe) static let pretty: JSONEncoder = {
           let e = JSONEncoder()
           e.outputFormatting = [.prettyPrinted, .sortedKeys]
           return e
       }()
   }
   ```

   Key Swift 6 concurrency notes:
   - `ConfigStore` is `@MainActor` so all access is serialized on the main actor. SwiftUI views that `@Environment(configStore)` or `@State private var configStore = ConfigStore()` are already on the main actor.
   - `loadOrCreateDefault()` is a `static func` called from `init()`, which is called on the main actor — no isolation mismatch.
   - `print` statements do not log API keys (they only log errors, not config content).

**Verify:**
`xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "ConfigStore.swift|error:"`
Expected: no errors referencing `ConfigStore.swift`.

---

## Task 9: Wire App Entry and Final Build

**Files:**
- Modify: `ModelProxy/App/ModelProxyApp.swift` (finalize — update the placeholder from Task 3)

**Steps:**

1. All model and service files are now created. The `ModelProxyApp.swift` written in Task 3 already references `ConfigStore` and `StatusPopover`. Verify the imports are correct — no changes needed if Tasks 3–8 were completed in order.

2. Confirm the `@Observable` `ConfigStore` is passed into the environment correctly. `StatusPopover` in Task 3 accepts it via `@Environment`. Since `AppConfig` is `@Observable`, SwiftUI will re-render `StatusPopover` automatically when `config` changes.

3. Run a full clean build:
   ```
   xcodebuild clean build \
     -scheme ModelProxy \
     -destination 'platform=macOS' \
     2>&1 | grep -E "error:|warning:.*concurren|BUILD"
   ```
   Expected output ends with `** BUILD SUCCEEDED **`. There must be no lines matching `error:` or concurrency-related `warning:`.

4. Run the app (`Cmd+R` in Xcode or `open -a ModelProxy` after build). Verify:
   - Menu bar shows the `arrow.triangle.2.circlepath` icon.
   - Clicking the icon opens a small popover with "ModelProxy" text.
   - Clicking outside the popover closes it.

5. Verify config.json creation (in sandbox container path):
   ```
   cat ~/Library/Containers/com.90percent.ModelProxy/Data/Library/Application\ Support/ModelProxy/config.json
   ```
   Expected: valid JSON with `vendors` array containing one Anthropic entry and `clients` array containing one Claude Code entry with port 8080.

6. Quit and relaunch the app. Manually edit config.json to change the port to 9090:
   ```
   # Edit port value (use container path for sandbox)
   sed -i '' 's/"port" : 8080/"port" : 9090/' \
     ~/Library/Containers/com.90percent.ModelProxy/Data/Library/Application\ Support/ModelProxy/config.json
   ```
   Re-launch the app and confirm no crash (the round-trip load succeeds even with a modified value).

**Verify:**
Run: `xcodebuild clean build -scheme ModelProxy -destination 'platform=macOS' 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

---

## Task 10: Codable Round-Trip Unit Tests

**Files:**
- Modify: `ModelProxyTests/ModelProxyTests.swift` (replace placeholder test)

**Steps:**

1. Replace `ModelProxyTests/ModelProxyTests.swift` with:

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
               baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
               apiKey: "sk-test-key",
               modelPatterns: ["qwen-", "qwen-turbo"]
           )
           let data = try JSONEncoder().encode(original)
           let decoded = try JSONDecoder().decode(Vendor.self, from: data)
           #expect(decoded == original)
       }

       // MARK: - ClientConfig round-trip

       @Test func clientConfigCodableRoundTrip() throws {
           let vendorID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
           let original = ClientConfig(
               id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
               clientName: "Claude Code",
               port: 8080,
               modelMappings: ["claude-haiku-4-5": vendorID],
               defaultVendorID: vendorID
           )
           let data = try JSONEncoder().encode(original)
           let decoded = try JSONDecoder().decode(ClientConfig.self, from: data)
           #expect(decoded == original)
       }

       // MARK: - AppConfig round-trip

       @Test func appConfigCodableRoundTrip() throws {
           let config = AppConfig.makeDefault()
           let data = try JSONEncoder().encode(config)
           let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
           #expect(decoded.vendors.count == config.vendors.count)
           #expect(decoded.clients.count == config.clients.count)
           #expect(decoded.vendors.first?.name == config.vendors.first?.name)
           #expect(decoded.vendors.first?.baseURL == config.vendors.first?.baseURL)
           #expect(decoded.clients.first?.port == config.clients.first?.port)
       }

       // MARK: - AppConfig default shape

       @Test func defaultConfigHasExpectedShape() {
           let config = AppConfig.makeDefault()
           #expect(config.vendors.count == 1)
           #expect(config.vendors.first?.name == "Anthropic")
           #expect(config.vendors.first?.baseURL == "https://api.anthropic.com/v1")
           #expect(config.clients.count == 1)
           #expect(config.clients.first?.clientName == "Claude Code")
           #expect(config.clients.first?.port == 8080)
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

2. Run the tests:
   ```
   xcodebuild test \
     -scheme ModelProxy \
     -destination 'platform=macOS' \
     2>&1 | grep -E "Test.*passed|Test.*failed|error:|BUILD"
   ```

**Verify:**
Run: `xcodebuild test -scheme ModelProxy -destination 'platform=macOS' 2>&1 | grep -E "passed|failed"`
Expected: all 5 tests listed as passed, zero failed.

---

## Acceptance Criteria Checklist

| Criterion | Verified by |
|-----------|-------------|
| App builds on macOS 14+ without warnings in Swift 6 strict concurrency mode | Task 9 step 3 |
| Menu bar icon appears on launch | Task 9 step 4 |
| Clicking icon opens and dismisses the popover | Task 9 step 4 |
| `config.json` created in Application Support on first launch | Task 9 step 5 |
| Re-launching loads previously saved config (round-trip) | Task 9 step 6 |
| All model types encode/decode without data loss | Task 10 |

---

## Decisions

None.

---

## Verification

- **Verdict:** Approved
- **Date:** 2026-03-06
- **Verified by:** dev-workflow:plan-verifier
- **Final revision:** Entitlements (network.server/client) + CODE_SIGN_ENTITLEMENTS build setting + sandbox path handling
