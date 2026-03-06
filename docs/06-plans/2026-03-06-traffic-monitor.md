# Traffic Monitor Implementation Plan

**Goal:** Add a live-updating traffic list to the StatusPopover that shows the 50 most recent proxied requests with model name, vendor/route info, HTTP status, and relative timestamp.

**Architecture:** A new `@MainActor @Observable` class `TrafficLog` holds a ring buffer (capped at 50 entries). `ProxyForwarder` — which runs in a non-MainActor `Task` — publishes events to `TrafficLog` via `MainActor.run { }` at two points: the BLOCKED path (403) and after the upstream response returns. `TrafficLog` is injected into the SwiftUI environment alongside `ProxyServer` and `ConfigStore`, and `StatusPopover` gains a new scrollable traffic section below the existing controls.

**Tech Stack:** Swift 6, SwiftUI, `@Observable`, `MainActor.run`, `ScrollViewReader` for auto-scroll to newest entry.

**Design doc:** none

**Design analysis:** none

**Crystal file:** `docs/11-crystals/2026-03-06-phase-consolidation-crystal.md`, `docs/11-crystals/2026-03-06-proxy-routing-crystal.md`

Crystal ref: [D-006] (proxy-routing) — audit log records all forwarded requests.

---

## Scope Guards

- StatusPopover status indicator, Start/Stop, Settings, Quit buttons already exist and are NOT touched.
- Menu bar icon change is in scope (Task 4) but is cosmetic-only; no behavior change.
- No request or response body content is stored or logged at any point.

---

### Task 1: TrafficLog model (ring buffer)

**Files:**
- Create: `ModelProxy/Models/TrafficLog.swift`

**Steps:**

1. Create the file with the following content:

```swift
import Foundation
import Observation

// MARK: - TrafficEntry

/// One recorded proxy request. No body content is stored.
struct TrafficEntry: Identifiable, Sendable {
    enum RouteType: Sendable {
        case passthrough
        case mapped(vendorName: String)
        case blocked
    }

    let id: UUID
    let model: String
    let routeType: RouteType
    /// HTTP status returned to the client (200, 403, 502, etc.)
    let httpStatus: Int
    let timestamp: Date

    init(model: String, routeType: RouteType, httpStatus: Int, timestamp: Date = .now) {
        self.id = UUID()
        self.model = model
        self.routeType = routeType
        self.httpStatus = httpStatus
        self.timestamp = timestamp
    }
}

// MARK: - TrafficLog

/// Ring buffer of recent proxy requests. Capped at 50 entries.
/// @MainActor so SwiftUI can observe it directly without cross-actor hops.
@MainActor
@Observable
final class TrafficLog {

    static let maxEntries = 50

    /// Ordered oldest → newest; consumers scroll/display newest last.
    private(set) var entries: [TrafficEntry] = []

    /// Append a new entry, evicting the oldest if the buffer is full.
    func append(_ entry: TrafficEntry) {
        if entries.count >= Self.maxEntries {
            entries.removeFirst()
        }
        entries.append(entry)
    }
}
```

2. Verify the file compiles by building the target (no test needed for a pure model).

**Verify:**
Run: `xcodebuild -scheme ModelProxy -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

### Task 2: Thread-safe event publishing from ProxyForwarder

**Files:**
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift` (full file, lines 1–144)
- Modify: `ModelProxy/Proxy/ProxyChannelHandler.swift` (lines 19–50, init + channelRead)
- Modify: `ModelProxy/Proxy/ProxyServer.swift` (lines 12–136, class body)
- Modify: `ModelProxy/App/ModelProxyApp.swift` (lines 1–22)

**Context:** `ProxyForwarder.forward()` is called from a non-`@MainActor` `Task` in `ProxyChannelHandler`. `TrafficLog` is `@MainActor`. Publishing requires `await MainActor.run { trafficLog.append(...) }`.

**Steps:**

1. **Add `trafficLog` parameter to `ProxyForwarder.forward`.**

   In `ModelProxy/Proxy/ProxyForwarder.swift`, change the function signature from:

   ```swift
   static func forward(
       head: HTTPRequestHead,
       body: ByteBuffer,
       channel: any Channel,
       router: RequestRouter,
       httpClient: HTTPClient
   ) async {
   ```

   to:

   ```swift
   static func forward(
       head: HTTPRequestHead,
       body: ByteBuffer,
       channel: any Channel,
       router: RequestRouter,
       httpClient: HTTPClient,
       trafficLog: TrafficLog
   ) async {
   ```

2. **Publish a blocked event.** Replace the existing BLOCKED print line (line 35–38):

   ```swift
   case .blocked(let reason):
       print("[Proxy] \(head.method.rawValue) \(head.uri) model=\(model) BLOCKED")
       await Self.sendError(channel: channel, status: .forbidden, message: reason)
       return
   ```

   with:

   ```swift
   case .blocked(let reason):
       print("[Proxy] \(head.method.rawValue) \(head.uri) model=\(model) BLOCKED")
       let blockedEntry = TrafficEntry(model: model, routeType: .blocked, httpStatus: 403)
       await MainActor.run { trafficLog.append(blockedEntry) }
       await Self.sendError(channel: channel, status: .forbidden, message: reason)
       return
   ```

3. **Publish error events for early-return paths.** Three error paths in `forward()` return early without contacting the upstream. Add traffic logging before each return:

   a. After the 502 "Upstream unreachable" `sendError` call:
   ```swift
   } catch {
       let entry = TrafficEntry(model: model, routeType: target.isPassthrough ? .passthrough : .mapped(vendorName: target.vendorName), httpStatus: 502)
       await MainActor.run { trafficLog.append(entry) }
       await Self.sendError(channel: channel, status: .badGateway, message: "Upstream unreachable: \(error)")
       return
   }
   ```

4. **Publish a routed event after upstream response.** After the `ResponseRelay.relay(...)` call (currently the last statement in the function, line 108–111), add:

   ```swift
   // Publish traffic event — status code from upstream response.
   let statusCode = Int(upstreamResponse.status.code)
   let routeType: TrafficEntry.RouteType = target.isPassthrough
       ? .passthrough
       : .mapped(vendorName: target.vendorName)
   let entry = TrafficEntry(model: model, routeType: routeType, httpStatus: statusCode)
   await MainActor.run { trafficLog.append(entry) }
   ```

   This goes after `await ResponseRelay.relay(...)` and before the closing brace of `forward()`.

4. **Thread-safety note:** `MainActor.run { }` is the correct bridge. `TrafficLog` is `@MainActor` so the closure executes on the main actor. `TrafficEntry` is `Sendable`, so passing it across the actor boundary is safe.

5. **Pass `trafficLog` through `ProxyChannelHandler`.** In `ModelProxy/Proxy/ProxyChannelHandler.swift`:

   Add `trafficLog: TrafficLog` to the stored properties and `init`:

   ```swift
   private let router: RequestRouter
   private let httpClient: HTTPClient
   private let trafficLog: TrafficLog

   init(router: RequestRouter, httpClient: HTTPClient, trafficLog: TrafficLog) {
       self.router = router
       self.httpClient = httpClient
       self.trafficLog = trafficLog
   }
   ```

   In the `Task` block inside `case .end:`, update the call to `ProxyForwarder.forward`:

   ```swift
   Task {
       await ProxyForwarder.forward(
           head: head,
           body: body,
           channel: channel,
           router: router,
           httpClient: httpClient,
           trafficLog: trafficLog
       )
   }
   ```

6. **Pass `trafficLog` through `ProxyServer`.** In `ModelProxy/Proxy/ProxyServer.swift`:

   Add a stored property to `ProxyServer`:

   ```swift
   // Add at the top of the observable state section, after `boundPorts`:
   let trafficLog: TrafficLog = TrafficLog()
   ```

   In `start(config:)`, where `ProxyChannelHandler` is instantiated (inside `.childChannelInitializer`), update to pass `trafficLog`:

   ```swift
   channel.pipeline.addHandler(
       ProxyChannelHandler(router: router, httpClient: client, trafficLog: self.trafficLog)
   )
   ```

   Note: `self.trafficLog` is accessed here from within a `nonisolated` closure. Because `trafficLog` is a `let` constant on `@MainActor ProxyServer`, capture it as a local `let` before the closure to satisfy Swift 6 strict concurrency:

   ```swift
   // Before the bootstrap definition, inside the for-loop:
   let trafficLog = self.trafficLog

   // Then inside .childChannelInitializer:
   channel.pipeline.addHandler(
       ProxyChannelHandler(router: router, httpClient: client, trafficLog: trafficLog)
   )
   ```

7. **Inject `TrafficLog` into the environment.** In `ModelProxy/App/ModelProxyApp.swift`, `TrafficLog` is now owned by `ProxyServer` (as `proxyServer.trafficLog`), so no separate `@State` is needed. Update the environment injection in both scenes:

   ```swift
   MenuBarExtra("ModelProxy", systemImage: "network") {
       StatusPopover()
           .environment(configStore)
           .environment(proxyServer)
           .environment(proxyServer.trafficLog)
   }
   .menuBarExtraStyle(.window)

   Settings {
       SettingsView()
           .environment(configStore)
           .environment(proxyServer)
   }
   ```

   (The Settings scene does not display traffic, so no injection there.)

**Verify:**
Run: `xcodebuild -scheme ModelProxy -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

### Task 3: Traffic list view in StatusPopover

**Files:**
- Modify: `ModelProxy/Views/StatusPopover.swift` (full file)

**Steps:**

1. Read the current file to confirm no drift from what was read above before editing.

2. Replace the full file content with the following. The existing `statusSection` and `controlSection` are preserved verbatim; the traffic section is added below:

```swift
import SwiftUI

struct StatusPopover: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(TrafficLog.self) private var trafficLog
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 12) {
            Text("ModelProxy")
                .font(.headline)

            statusSection

            Divider()

            controlSection

            Divider()

            trafficSection
        }
        .padding()
        .frame(width: 360)
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

    // MARK: - Traffic

    @ViewBuilder
    private var trafficSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Requests")
                .font(.caption)
                .foregroundStyle(.secondary)

            if trafficLog.entries.isEmpty {
                Text("No requests yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(trafficLog.entries) { entry in
                                TrafficRowView(entry: entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    .onChange(of: trafficLog.entries.last?.id) { _, _ in
                        if let last = trafficLog.entries.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - TrafficRowView

private struct TrafficRowView: View {
    let entry: TrafficEntry

    var body: some View {
        HStack(spacing: 6) {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            // Model name
            Text(entry.model)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Route label
            Text(routeLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // HTTP status
            Text("\(entry.httpStatus)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(statusColor)
                .frame(width: 28, alignment: .trailing)

            // Relative time
            Text(relativeTime)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch entry.httpStatus {
        case 200..<300: return .green
        case 400..<500: return .orange
        default: return .red
        }
    }

    private var routeLabel: String {
        switch entry.routeType {
        case .passthrough: return "pass"
        case .mapped(let vendor): return vendor
        case .blocked: return "blocked"
        }
    }

    private var relativeTime: String {
        let elapsed = Date.now.timeIntervalSince(entry.timestamp)
        if elapsed < 60 {
            return "\(Int(elapsed))s"
        } else if elapsed < 3600 {
            return "\(Int(elapsed / 60))m"
        } else {
            return "\(Int(elapsed / 3600))h"
        }
    }
}

#Preview {
    StatusPopover()
        .environment(ConfigStore())
        .environment(ProxyServer())
        .environment({
            let log = TrafficLog()
            log.append(TrafficEntry(model: "claude-opus-4-5", routeType: .mapped(vendorName: "Alibaba"), httpStatus: 200))
            log.append(TrafficEntry(model: "claude-sonnet-4-5", routeType: .passthrough, httpStatus: 200))
            log.append(TrafficEntry(model: "gpt-4o", routeType: .blocked, httpStatus: 403))
            return log
        }())
}
```

**Design rationale:**
- Width bumped from 300 to 360 to accommodate traffic rows without truncating model names.
- `maxHeight: 180` shows approximately 6–8 rows; user can scroll for more.
- `LazyVStack` avoids rendering all 50 rows at once.
- `onChange(of: trafficLog.entries.last?.id)` auto-scrolls to the newest entry on each append (using `.last?.id` instead of `.count` because count stays 50 after ring buffer is full).
- `relativeTime` is computed on render; no Timer is set up — acceptable staleness for a passive monitor.

**Verify:**
Run: `xcodebuild -scheme ModelProxy -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

### Task 4: Update menu bar icon

**Files:**
- Modify: `ModelProxy/App/ModelProxyApp.swift` (line 9)

**Steps:**

1. Change the `systemImage` in `MenuBarExtra` from `"arrow.triangle.2.circlepath"` to `"network"`.

   `"network"` (three horizontal signal arcs) communicates "proxy / network traffic" more directly than the rotation arrows.

   Current line 9:
   ```swift
   MenuBarExtra("ModelProxy", systemImage: "arrow.triangle.2.circlepath") {
   ```

   Updated:
   ```swift
   MenuBarExtra("ModelProxy", systemImage: "network") {
   ```

   This change was already applied in Task 2 Step 7 if done in order; confirm it is present rather than duplicating the edit.

**Verify:**
Run: `xcodebuild -scheme ModelProxy -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

### Task 5: End-to-end acceptance verification

**Files:** none (verification only)

**Steps:**

1. Build and run the app:
   ```
   xcodebuild -scheme ModelProxy -configuration Debug -destination 'platform=macOS' run
   ```
   Or open in Xcode and run with Cmd+R.

2. **Proxy start test.** Open the menu bar popover. Confirm the status section shows "Running" with a green checkmark within 2 seconds.

3. **Traffic log — mapped request.** Send a request using a mapped model (adjust model name to match your config):
   ```
   curl -s -o /dev/null -w "%{http_code}" \
     -X POST http://127.0.0.1:8080/v1/messages \
     -H "Content-Type: application/json" \
     -H "x-api-key: test-key" \
     -d '{"model":"claude-opus-4-5","messages":[{"role":"user","content":"hi"}],"max_tokens":1}'
   ```
   Expected: entry appears in the traffic list within 1 second showing the model name, vendor name, HTTP status (e.g., 200), and a relative time like "0s" or "1s".

4. **Traffic log — blocked request.** Configure a client with `unmappedModelPolicy = block`, then send a request with an unmapped model. Expected: entry appears in the list with status 403 and route label "blocked".

5. **Traffic log — passthrough request.** Configure a client with `unmappedModelPolicy = passthrough`, send a request with an unmapped model. Expected: entry appears with route label "pass".

6. **Ring buffer cap.** Send 55 requests (script a loop). Expected: list shows exactly 50 entries after all requests complete; oldest entries are evicted.

7. **Stop proxy.** Click "Stop Proxy". Then run:
   ```
   curl -s --connect-timeout 2 http://127.0.0.1:8080/v1/messages
   ```
   Expected: connection refused.

8. **Start proxy.** Click "Start Proxy". Then re-run the curl command from step 3. Expected: proxy responds (non-connection-refused).

9. **Settings button.** Click "Settings...". Expected: Settings window opens.

10. **No body content.** Confirm `TrafficEntry` fields in code — only `model`, `routeType`, `httpStatus`, `timestamp`, `id`. No body field exists.

---

## Decisions

None.

---
## Verification
- **Verdict:** Approved
- **Date:** 2026-03-06
- **Revisions applied:**
  - Auto-scroll trigger changed from `entries.count` to `entries.last?.id` (ring buffer count stays 50 after full)
  - Added 502 upstream-unreachable traffic entry publishing (error path coverage)
- **Report:** `.claude/reviews/plan-verifier-2026-03-06-175715.md`
