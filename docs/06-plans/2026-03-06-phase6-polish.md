# Phase 6: Launch at Login and Final Polish — Implementation Plan

**Goal:** Add SMAppService launch-at-login, menu bar icon state badges, deprecation detection for stale model mappings, corrupt-config resilience with user notification, os.Logger replacement for print statements, and VoiceOver accessibility labels.

**Architecture:** A new `LoginItemService` wraps `SMAppService` calls. Menu bar icon state is driven by a computed `AppState` enum on `ProxyServer` that combines `isRunning`, `lastError`, and a new `deprecationWarnings` property added in this phase. `ConfigStore` gains a `didResetFromCorrupt` flag so `StatusPopover` can surface a one-time alert. The known-model list is extracted from `RoutingTabView` into a shared constant so both the picker and the deprecation checker use the same source of truth.

**Tech Stack:** Swift 6, SwiftUI, macOS 14+, ServiceManagement (SMAppService), os.Logger

**Design doc:** docs/06-plans/dev-guide.md § Phase 6

**Design analysis:** none

**Crystal file:** none

---

## Task 1: Extract known Anthropic models to a shared constant

**Why first:** Both the deprecation checker (Task 3) and the routing picker (existing `RoutingTabView`) need the same list. Extracting it first avoids a circular dependency.

**Files:**
- Create: `ModelProxy/Models/KnownAnthropicModels.swift`
- Modify: `ModelProxy/Views/RoutingTabView.swift:10-17`

**Steps:**

1. Create `ModelProxy/Models/KnownAnthropicModels.swift`:

```swift
import Foundation

/// Canonical list of supported Anthropic model IDs.
/// Used by RoutingTabView picker and deprecation detection on launch.
/// Update this list when Anthropic releases or retires models.
enum KnownAnthropicModels {
    static let all: [String] = [
        "claude-haiku-4-5",
        "claude-sonnet-4-6",
        "claude-opus-4-6",
        "claude-3-5-haiku-20241022",
        "claude-3-5-sonnet-20241022",
        "claude-3-opus-20240229",
    ]
}
```

2. In `ModelProxy/Views/RoutingTabView.swift`, remove the private `knownAnthropicModels` property (lines 10-17) and replace all references to it with `KnownAnthropicModels.all`:

Replace:
```swift
// Known Anthropic model IDs for the source picker.
private let knownAnthropicModels: [String] = [
    "claude-haiku-4-5",
    ...
]
```
With: _(delete entire property block)_

In `RoutingTabView.body`, change:
```swift
AddMappingRow(
    knownAnthropicModels: knownAnthropicModels,
```
to:
```swift
AddMappingRow(
    knownAnthropicModels: KnownAnthropicModels.all,
```

In `AddMappingRow.onAppear`:
```swift
selectedSourceModel = KnownAnthropicModels.all.first ?? ""
```

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

## Task 2: Replace print() with os.Logger across proxy layer

**Why:** The acceptance criterion "No API key in Console.app logs" requires auditing all print paths. The existing prints do not leak keys, but replacing with `os.Logger` is the correct production pattern and gives subsystem/category filtering in Console.app.

**Files:**
- Modify: `ModelProxy/Proxy/ProxyServer.swift`
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift`
- Modify: `ModelProxy/Proxy/ProxyChannelHandler.swift`
- Modify: `ModelProxy/Proxy/ResponseRelay.swift`
- Modify: `ModelProxy/Services/TokenStatsStore.swift`
- Modify: `ModelProxy/Services/ConfigStore.swift`

**Steps:**

1. Audit: confirm no existing print statement includes an API key.
   - `ProxyForwarder.swift:46` logs `target.baseURL` — this is a URL, not a key. Safe.
   - `ProxyForwarder.swift:37` logs model and URI. Safe.
   - `ProxyChannelHandler.swift:65` logs the NIO error. Safe.
   - `ResponseRelay.swift:94` logs write errors. Safe.
   - `TokenStatsStore.swift:92` logs persistence errors. Safe.
   - `ConfigStore.swift:71,85` logs decode/save errors. Safe.
   - `ProxyServer.swift:86,132` logs port binding and stop. Safe.

2. Add a shared logger file. Create `ModelProxy/App/AppLogger.swift`:

```swift
import OSLog

extension Logger {
    private static let subsystem = "com.modelproxy.app"

    static let proxy   = Logger(subsystem: subsystem, category: "proxy")
    static let config  = Logger(subsystem: subsystem, category: "config")
    static let stats   = Logger(subsystem: subsystem, category: "stats")
}
```

3. In `ModelProxy/Proxy/ProxyServer.swift`, add `import OSLog` and replace:
```swift
print("[ProxyServer] \(clientCfg.clientName) listening on 127.0.0.1:\(actualPort)")
```
with:
```swift
Logger.proxy.info("[ProxyServer] \(clientCfg.clientName, privacy: .public) listening on 127.0.0.1:\(actualPort, privacy: .public)")
```

Replace:
```swift
print("[ProxyServer] Stopped.")
```
with:
```swift
Logger.proxy.info("[ProxyServer] Stopped.")
```

4. In `ModelProxy/Proxy/ProxyForwarder.swift`, add `import OSLog` and replace:
```swift
print("[Proxy] \(head.method.rawValue) \(head.uri) model=\(model) BLOCKED")
```
with:
```swift
Logger.proxy.info("[Proxy] \(head.method.rawValue, privacy: .public) \(head.uri, privacy: .public) model=\(model, privacy: .public) BLOCKED")
```

Replace:
```swift
print("[Proxy] \(head.method.rawValue) \(head.uri) model=\(model) \(routeType) → \(target.baseURL)")
```
with:
```swift
Logger.proxy.info("[Proxy] \(head.method.rawValue, privacy: .public) \(head.uri, privacy: .public) model=\(model, privacy: .public) \(routeType, privacy: .public) → \(target.baseURL, privacy: .public)")
```

5. In `ModelProxy/Proxy/ProxyChannelHandler.swift`, add `import OSLog` and replace:
```swift
print("[ProxyChannelHandler] Channel error: \(error)")
```
with:
```swift
Logger.proxy.error("[ProxyChannelHandler] Channel error: \(error, privacy: .public)")
```

6. In `ModelProxy/Proxy/ResponseRelay.swift`, add `import OSLog` and replace:
```swift
print("[ResponseRelay] Write error (client may have disconnected): \(error)")
```
with:
```swift
Logger.proxy.warning("[ResponseRelay] Write error (client may have disconnected): \(error, privacy: .public)")
```

7. In `ModelProxy/Services/TokenStatsStore.swift`, add `import OSLog` and replace:
```swift
print("[TokenStatsStore] Failed to persist stats: \(error)")
```
with:
```swift
Logger.stats.error("[TokenStatsStore] Failed to persist stats: \(error, privacy: .public)")
```

8. In `ModelProxy/Services/ConfigStore.swift`, add `import OSLog` and replace both `print(...)` calls:
```swift
// Line 71
Logger.config.error("[ConfigStore] Failed to decode config.json: \(error, privacy: .public). Resetting to defaults.")
// Line 85
Logger.config.error("[ConfigStore] Failed to save config.json: \(error, privacy: .public)")
```

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Then verify no `print(` calls remain in proxy/services:
Run: `grep -rn "^\s*print(" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/`
Expected: no output (zero matches)

---

## Task 3: Deprecation detection — flag stale model mappings at launch

**Files:**
- Create: `ModelProxy/Services/DeprecationChecker.swift`
- Modify: `ModelProxy/Proxy/ProxyServer.swift`

**Steps:**

1. Create `ModelProxy/Services/DeprecationChecker.swift`:

```swift
import Foundation

/// Checks configured model mappings against the known Anthropic model list.
/// Returns the set of source model IDs that are no longer in KnownAnthropicModels.all.
enum DeprecationChecker {
    /// Returns source model strings that are not in KnownAnthropicModels.all.
    static func staleSourceModels(in mappings: [ModelMapping]) -> [String] {
        let known = Set(KnownAnthropicModels.all)
        return mappings
            .map(\.sourceModel)
            .filter { !known.contains($0) }
    }
}
```

2. Add `deprecationWarnings: [String]` to `ProxyServer`'s observable state (after `boundPorts`):

In `ModelProxy/Proxy/ProxyServer.swift`, add to the `// MARK: - Observable State` block:
```swift
/// Source model IDs that are in config but not in KnownAnthropicModels.all.
/// Populated by ConfigStore on launch and on config save.
private(set) var deprecationWarnings: [String] = []
```

Add a setter method (below `updateRouting`):
```swift
/// Called by ConfigStore after loading or saving config.
func setDeprecationWarnings(_ warnings: [String]) {
    deprecationWarnings = warnings
}
```

3. Wire deprecation check in `ModelProxyApp.swift`: after `ConfigStore` initialises, run the check and push results to `ProxyServer`. The check happens inside `StatusPopover`'s `.task` (since `ProxyServer` and `ConfigStore` are both available there). Add a second `.task` modifier to `StatusPopover` in `ModelProxyApp.swift` — actually, the cleanest place is inside `StatusPopover.swift`'s existing `.task` block.

In `ModelProxy/Views/StatusPopover.swift`, add an `.onAppear` modifier (fires each time popover opens, unlike `.task` which fires once per lifecycle):

```swift
.onAppear {
    let stale = DeprecationChecker.staleSourceModels(in: configStore.config.modelMappings)
    proxyServer.setDeprecationWarnings(stale)
}
```

Keep the existing `.task` block unchanged (it handles proxy auto-start).

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

## Task 4: Compute app icon state from ProxyServer

**Why:** `MenuBarExtra` accepts only a `systemImage:` string — it cannot overlay a badge image dynamically. SF Symbol name-swapping is the practical approach: swap to a different symbol name based on error/warning state.

**Files:**
- Modify: `ModelProxy/Proxy/ProxyServer.swift`
- Modify: `ModelProxy/App/ModelProxyApp.swift`

**Steps:**

1. Add a computed property to `ProxyServer` that returns the correct SF Symbol name. Add below `setDeprecationWarnings` in `ProxyServer.swift`:

```swift
/// SF Symbol name for the menu bar icon.
/// Uses template rendering (set in MenuBarExtra) so it adapts to light/dark menu bar automatically.
var menuBarSymbol: String {
    if lastError != nil && !isRunning {
        // Total failure: proxy not running and has an error (e.g., port conflict on all clients).
        return "network.slash"
    }
    if lastError != nil {
        // Partial failure: proxy running but at least one port failed.
        return "network.badge.shield.half.filled"
    }
    if !deprecationWarnings.isEmpty {
        // Warning: deprecated model mappings configured.
        return "exclamationmark.triangle"
    }
    return "network"
}
```

Note on symbols: `network.slash` and `network.badge.shield.half.filled` are available on macOS 14+. `network.badge.clock.household.fill` is available macOS 14+ (SF Symbols 5). Verify symbol availability in the SF Symbols app before finalising — if `network.badge.clock.household.fill` is unavailable, use `exclamationmark.triangle` as the warning icon alongside a different primary.

2. In `ModelProxy/App/ModelProxyApp.swift`, update `MenuBarExtra` to use the computed symbol:

Replace:
```swift
MenuBarExtra("ModelProxy", systemImage: "network") {
```
with:
```swift
MenuBarExtra("ModelProxy", systemImage: proxyServer.menuBarSymbol) {
```

The `MenuBarExtra` label observes `proxyServer` because `proxyServer` is `@State` and `@Observable`; any change to `menuBarSymbol`'s dependencies (`lastError`, `deprecationWarnings`, `isRunning`) automatically triggers a re-render.

**Verify symbol availability:** Open SF Symbols 5 app and search for `network.slash` and `network.badge.shield.half.filled`. Both must show macOS 14 availability. If not available, replace with:
- Error: `"exclamationmark.circle.fill"` (always available)
- Warning: `"exclamationmark.triangle.fill"` (always available)

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

## Task 5: Popover banner — show error/warning when icon has a badge

**Files:**
- Modify: `ModelProxy/Views/StatusPopover.swift`

**Steps:**

1. Add a `bannerSection` computed view above `statusSection` in `StatusPopover`. Insert before the `statusSection` in the `VStack`:

```swift
// Insert as first child of VStack, before Text("ModelProxy"):
bannerSection
```

Add the computed view:
```swift
// MARK: - Banner

@ViewBuilder
private var bannerSection: some View {
    // Error banner: show when proxy is fully stopped due to error.
    if !proxyServer.isRunning, let error = proxyServer.lastError {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Error: \(error)")
    }
    // Partial-error banner: proxy running but some ports failed.
    else if proxyServer.isRunning, let error = proxyServer.lastError {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Warning: \(error)")
    }

    // Deprecation warning banner.
    if !proxyServer.deprecationWarnings.isEmpty {
        let modelList = proxyServer.deprecationWarnings.joined(separator: ", ")
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text("Deprecated model mappings: \(modelList)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Warning: deprecated model mappings \(modelList). Update routing rules in Settings.")
    }
}
```

2. The full `VStack` order after this change should be:
   1. `bannerSection` (new — conditionally empty)
   2. `Text("ModelProxy").font(.headline)`
   3. `statusSection`
   4. `Divider()`
   5. `statsSection`
   6. `Divider()`
   7. `controlSection`
   8. `Divider()`
   9. `trafficSection`

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

## Task 6: Corrupt config notification

**Context:** `ConfigStore.loadOrCreateDefault()` already resets to defaults silently on corrupt JSON (line 69-75). This task surfaces that reset to the user via a one-time flag read by `StatusPopover`.

**Files:**
- Modify: `ModelProxy/Services/ConfigStore.swift`
- Modify: `ModelProxy/Views/StatusPopover.swift`

**Steps:**

1. Add a `didResetFromCorrupt` flag to `ConfigStore`. In `ConfigStore.swift`, add to the class body after `private(set) var config: AppConfig`:

```swift
/// True if config.json was corrupt at launch and was reset to defaults.
/// Cleared after first read so the notification shows only once.
private(set) var didResetFromCorrupt: Bool = false
```

2. `loadOrCreateDefault()` is `static` and cannot mutate `self`. Change the approach: return a tuple from `loadOrCreateDefault()` and set the flag in `init()`.

Replace the static method signature:
```swift
private static func loadOrCreateDefault() -> AppConfig {
```
with:
```swift
private static func loadOrCreateDefault() -> (config: AppConfig, wasCorrupt: Bool) {
```

At the `guard` early return (missing file path), change:
```swift
return defaults
```
to:
```swift
return (defaults, false)
```

At the `return config` success path:
```swift
return (config, false)
```

At the corrupt-reset path:
```swift
return (defaults, true)
```

Update `init()`:
```swift
init() {
    let result = ConfigStore.loadOrCreateDefault()
    self.config = result.config
    self.didResetFromCorrupt = result.wasCorrupt
}
```

3. Add a method to clear the flag (call after showing the alert):
```swift
func clearCorruptFlag() {
    didResetFromCorrupt = false
}
```

4. In `StatusPopover.swift`, add state for the alert and show it on appear:

```swift
@State private var showingCorruptAlert: Bool = false
```

Add to `.task` block (at the top, before the deprecation check):
```swift
if configStore.didResetFromCorrupt {
    showingCorruptAlert = true
    configStore.clearCorruptFlag()
}
```

Add `.alert` modifier to the outer `VStack`:
```swift
.alert("Config Reset", isPresented: $showingCorruptAlert) {
    Button("OK") { }
} message: {
    Text("config.json was corrupt and has been reset to defaults. Your previous settings were not recoverable.")
}
```

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Manual test: rename `~/Library/Application Support/ModelProxy/config.json` to `.bak`, replace with invalid JSON (`echo "CORRUPT" > ~/Library/Application\ Support/ModelProxy/config.json`), relaunch the app. Expected: alert dialog appears, proxy starts with default config.

---

## Task 7: SMAppService — launch at login

**Files:**
- Create: `ModelProxy/Services/LoginItemService.swift`
- Create: `ModelProxy/Views/GeneralTabView.swift`
- Modify: `ModelProxy/Views/SettingsView.swift`

**Steps:**

1. Create `ModelProxy/Services/LoginItemService.swift`:

```swift
import Foundation
import ServiceManagement
import Observation
import OSLog

/// Wraps SMAppService to register/unregister the app as a login item.
/// @MainActor so SwiftUI bindings work without isolation hops.
@MainActor
@Observable
final class LoginItemService {

    private(set) var isEnabled: Bool = false

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            Logger.config.error("[LoginItemService] Failed to \(enabled ? "register" : "unregister", privacy: .public) login item: \(error, privacy: .public)")
        }
    }

    /// Refresh status from SMAppService (call after app becomes active to pick up external changes).
    func refreshStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
```

2. Create `ModelProxy/Views/GeneralTabView.swift`:

```swift
import SwiftUI
import ServiceManagement

struct GeneralTabView: View {
    @Environment(LoginItemService.self) private var loginItemService

    var body: some View {
        Form {
            Section {
                        Toggle(isOn: Binding(
                    get: { loginItemService.isEnabled },
                    set: { loginItemService.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                        Text("ModelProxy will start automatically when you log in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Launch at Login")
                .accessibilityHint("When enabled, ModelProxy starts automatically after you log in.")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemService.refreshStatus()
        }
    }
}

#Preview {
    GeneralTabView()
        .environment(LoginItemService())
}
```

3. In `ModelProxy/Views/SettingsView.swift`:

   a. Add `@Environment(LoginItemService.self) private var loginItemService` property.

   b. Insert `GeneralTabView` as the first tab in the `TabView`:
   ```swift
   GeneralTabView()
       .tabItem { Label("General", systemImage: "gearshape") }
       .environment(loginItemService)
   ```

   c. Pass `loginItemService` through environment at the bottom:
   ```swift
   .environment(loginItemService)
   ```
   (alongside the existing `.environment(configStore)` etc.)

4. In `ModelProxy/App/ModelProxyApp.swift`:

   a. Add `@State private var loginItemService: LoginItemService` to the app struct.

   b. In `init()`, add:
   ```swift
   _loginItemService = State(initialValue: LoginItemService())
   ```

   c. Inject into both scenes:
   ```swift
   // MenuBarExtra content:
   .environment(loginItemService)

   // Settings scene:
   .environment(loginItemService)
   ```

5. Verify `ServiceManagement` is available without adding a package dependency — it is a system framework included in macOS SDK. No `Package.swift` changes needed. Add `import ServiceManagement` only in `LoginItemService.swift`.

**SMAppService entitlement note:** `SMAppService.mainApp` requires no special entitlement for a sandboxed app distributing outside the Mac App Store. For a local personal tool without sandboxing enabled, it works out-of-the-box. If the app has App Sandbox entitlement enabled, no additional entitlement is required for login item registration via `SMAppService`.

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Manual test: toggle "Launch at Login" on. Open System Settings > General > Login Items. ModelProxy should appear under "Open at Login". Toggle off — it should disappear.

---

## Task 8: Accessibility labels on key UI elements

**Files:**
- Modify: `ModelProxy/Views/StatusPopover.swift`
- Modify: `ModelProxy/Views/SettingsView.swift`

**Steps:**

1. In `StatusPopover.swift`, add VoiceOver labels to the control buttons in `controlSection`:

```swift
// Stop button:
Button(action: { Task { await proxyServer.stop() } }) {
    Text("Stop Proxy").frame(maxWidth: .infinity)
}
.buttonStyle(.bordered)
.accessibilityLabel("Stop Proxy")
.accessibilityHint("Stops the local proxy server. Requests from connected tools will fail.")

// Start button:
Button(action: { Task { await proxyServer.start(config: configStore.config) } }) {
    Text("Start Proxy").frame(maxWidth: .infinity)
}
.buttonStyle(.borderedProminent)
.accessibilityLabel("Start Proxy")
.accessibilityHint("Starts the local proxy server on configured ports.")

// Settings button:
Button(action: { openSettings() }) {
    Label("Settings...", systemImage: "gear").frame(maxWidth: .infinity)
}
.buttonStyle(.bordered)
.accessibilityLabel("Open Settings")

// Quit button:
Button("Quit ModelProxy") { NSApplication.shared.terminate(nil) }
.buttonStyle(.bordered)
.accessibilityLabel("Quit ModelProxy")
.accessibilityHint("Stops the proxy and closes the application.")
```

2. Add accessibility label to the status section's status indicator. In `statusSection`, add `.accessibilityLabel` to each `HStack`:

```swift
// Running state HStack:
HStack { ... }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Proxy running on \(portList)")

// Error state HStack:
HStack { ... }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Proxy error: \(error)")

// Starting state HStack:
HStack { ... }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Proxy starting")
```

3. Add accessibility label to the token stats text in `statsSection`:

```swift
Text("Today: \(total.formatted()) tokens")
    .font(.caption2)
    .foregroundStyle(.secondary)
    .accessibilityLabel("Today's token usage: \(total.formatted()) tokens")
```

4. Add accessibility labels to traffic rows in `TrafficRowView`. Add to the `HStack` in `TrafficRowView.body`:

```swift
.accessibilityElement(children: .ignore)
.accessibilityLabel("\(entry.model), routed to \(routeLabel), HTTP \(entry.httpStatus), \(relativeTime) ago")
```

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Manual test: enable VoiceOver (Cmd+F5), hover over popover elements. Each button should announce its label and hint. Status indicator should announce running/error state without reading individual image descriptions.

---

## Task 9: Menu bar icon light/dark template rendering

**Context:** `MenuBarExtra` with `systemImage:` uses SF Symbols, which are template-rendered by default in the menu bar. No asset catalog image is needed. The symbol changes in Task 4 handle error/warning states. This task confirms the rendering is correct and documents the decision.

**Files:**
- No new files. Verify existing behavior.

**Steps:**

1. Confirm that `MenuBarExtra("ModelProxy", systemImage: proxyServer.menuBarSymbol)` renders as a template image (monochrome, adapts to menu bar color). SF Symbols used as `systemImage:` in `MenuBarExtra` are always rendered as template images by AppKit's `NSStatusItem` — no explicit rendering mode needs to be set.

2. Manual verification steps:
   - Launch app in light mode (System Settings > Appearance > Light). Menu bar icon should be dark.
   - Switch to dark mode. Menu bar icon should be light (inverted).
   - With a port conflict error (stop any listener using the configured port, then restart proxy): icon should change to `network.slash` or `network.badge.shield.half.filled`.
   - With a deprecated model mapping (add a mapping with source model `"claude-deprecated-fake"` via direct config.json edit): icon should change to the warning symbol.

3. No code changes required if Task 4 is complete. This task is a verification-only checkpoint.

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

## Task 10: End-to-end acceptance verification

**Files:** None (verification only)

**Steps:**

1. Launch at Login:
   ```
   # Enable in Settings > General > Launch at Login
   # Open System Settings > General > Login Items
   # ModelProxy must appear under "Open at Login"
   # Disable toggle — ModelProxy must disappear from Login Items
   ```

2. Port conflict (red badge):
   ```bash
   # Start a listener on port 8080 to simulate conflict
   nc -l 8080 &
   # Restart ModelProxy proxy (Stop + Start in popover)
   # Expected: icon changes to error symbol, popover banner shows "Port 8080 ... already in use."
   kill %1
   ```

3. Missing config.json (no crash):
   ```bash
   mv ~/Library/Application\ Support/ModelProxy/config.json \
      ~/Library/Application\ Support/ModelProxy/config.json.bak
   # Relaunch app
   # Expected: starts with defaults, no crash
   mv ~/Library/Application\ Support/ModelProxy/config.json.bak \
      ~/Library/Application\ Support/ModelProxy/config.json
   ```

4. Corrupt config.json (alert + no crash):
   ```bash
   echo "NOT JSON" > ~/Library/Application\ Support/ModelProxy/config.json
   # Relaunch app
   # Expected: alert "Config Reset" appears, app runs with defaults
   ```

5. Upstream 503 (traffic list):
   ```bash
   curl -s -o /dev/null -w "%{http_code}" \
     -X POST http://127.0.0.1:8080/v1/messages \
     -H "Content-Type: application/json" \
     -H "x-api-key: test" \
     -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"hi"}],"max_tokens":10}'
   # If upstream is unreachable, expected HTTP response: 502
   # Traffic list row: shows 502 status in red
   ```

6. No API key in Console.app:
   ```bash
   log stream --predicate 'subsystem == "com.modelproxy.app"' --level info
   # Send a request through the proxy
   # Expected: log lines show model names and URLs but NOT API key values
   ```

7. Icon light/dark: switch System Appearance between Light and Dark while app is running. Icon must remain visible (appropriate contrast) in both modes.

8. Deprecated model mapping (yellow warning):
   - In Settings > Routing, add a mapping with source model set to any non-current model (e.g., `claude-3-opus-20240229` if it has been removed from `KnownAnthropicModels.all`, or temporarily remove a model from the constant to simulate).
   - Close and reopen popover.
   - Expected: yellow warning banner appears listing the stale model(s). Icon switches to warning symbol.

---

## Decisions

None.

---
## Verification
- **Verdict:** Approved
- **Date:** 2026-03-06
