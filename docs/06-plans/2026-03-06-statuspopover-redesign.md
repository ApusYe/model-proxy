# StatusPopover Redesign Implementation Plan

**Goal:** Redesign StatusPopover for better visual hierarchy and information density, and update the menu bar icon to routing-themed SF Symbols.

**Architecture:** Pure UI-layer change. No proxy logic, no model layer, no config changes. Two files are modified: `ProxyServer.swift` (menuBarSymbol computed property only) and `StatusPopover.swift` (full layout rewrite). The popover moves from a vertically stacked single-column layout with full-width buttons to a compact header + token card + traffic list + single-row bottom controls layout.

**Tech Stack:** SwiftUI, SF Symbols, existing `@Observable` environment objects (`ProxyServer`, `TokenStatsStore`, `TrafficLog`, `ConfigStore`)

**Design doc:** none

**Design analysis:** none

**Crystal file:** `docs/11-crystals/2026-03-06-phase-consolidation-crystal.md`

---

## Scope Guards

This plan touches only UI presentation. The following are explicitly out of scope and must not be changed:
- Proxy start/stop logic
- ConfigStore / AppConfig / ClientConfig models
- TrafficLog ring buffer implementation
- TokenStatsStore data model
- SettingsView
- Any file other than `ProxyServer.swift` (menuBarSymbol only) and `StatusPopover.swift`

Crystal ref: [D-006] (Settings gear entry preserved), [D-007] (Start and Stop both present)

---

### Task 1: Update menuBarSymbol in ProxyServer

**Files:**
- Modify: `ModelProxy/Proxy/ProxyServer.swift:143-154`

**Context:** The current property returns `"network"` / `"network.slash"` / `"network.badge.shield.half.filled"` / `"exclamationmark.triangle"`. Replace with routing-themed symbols. The `isStopped` state now exists (added in the recent bug fix) and must be handled — stopped is not the same as error.

**Steps:**

1. Read lines 143–154 of `ModelProxy/Proxy/ProxyServer.swift` to confirm the exact current text before editing (rule: read before write).

2. Replace the `menuBarSymbol` computed property with:

```swift
/// SF Symbol name for the menu bar icon. Adapts to light/dark via template rendering.
/// States in priority order:
///   stopped/error  → xmark.circle        (not running, has error or was explicitly stopped)
///   partial error  → exclamationmark.circle  (running but last action had error)
///   deprecation    → exclamationmark.triangle
///   normal running → arrow.triangle.branch
var menuBarSymbol: String {
    if !isRunning && lastError != nil {
        return "xmark.circle"
    }
    if isRunning && lastError != nil {
        return "exclamationmark.circle"
    }
    if !deprecationWarnings.isEmpty {
        return "exclamationmark.triangle"
    }
    return "arrow.triangle.branch"
}
```

Note: `isStopped == true` with no `lastError` means clean stop — the icon should show `xmark.circle` only when there is an error. A clean stop (no error) also shows `xmark.circle` because the server is not running; add a dedicated stopped case:

```swift
var menuBarSymbol: String {
    if !isRunning && lastError != nil {
        return "xmark.circle"
    }
    if !isRunning {
        // stopped cleanly or never started
        return "xmark.circle"
    }
    if isRunning && lastError != nil {
        return "exclamationmark.circle"
    }
    if !deprecationWarnings.isEmpty {
        return "exclamationmark.triangle"
    }
    return "arrow.triangle.branch"
}
```

This simplifies to:

```swift
var menuBarSymbol: String {
    guard isRunning else { return "xmark.circle" }
    if lastError != nil { return "exclamationmark.circle" }
    if !deprecationWarnings.isEmpty { return "exclamationmark.triangle" }
    return "arrow.triangle.branch"
}
```

3. Update the doc comment above the property to reflect the new symbol names.

**Verify:**
Build the project:
```
xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED` with zero warnings.

---

### Task 2: Rewrite StatusPopover body and header section

**Files:**
- Modify: `ModelProxy/Views/StatusPopover.swift:11-51` (body + outer VStack)

**Context:** Current body stacks: bannerSection, "ModelProxy" title, statusSection, Divider, statsSection, Divider, controlSection, Divider, trafficSection — all at equal weight. Target layout removes the title, collapses status + ports into one compact header row, replaces statsSection with a token card, and makes trafficSection the dominant content area. The bottom controls collapse to a single horizontal row.

**Steps:**

1. Replace the `body` computed property (lines 11–51) with:

```swift
var body: some View {
    VStack(spacing: 0) {
        // Banners appear above everything else
        bannerSection
            .padding(.horizontal, 12)
            .padding(.top, 12)

        // Compact status header
        statusHeaderRow
            .padding(.horizontal, 12)
            .padding(.top, bannerIsVisible ? 8 : 12)
            .padding(.bottom, 8)

        Divider()

        // Token summary card
        tokenSummaryCard
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

        Divider()

        // Traffic list — primary content, gets maximum vertical space
        trafficSection
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

        Divider()
            .padding(.top, 4)

        // Compact single-row controls
        controlRow
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
    .frame(width: 360)
    .onAppear {
        if configStore.didResetFromCorrupt {
            showingCorruptAlert = true
            configStore.clearCorruptFlag()
        }
        let stale = DeprecationChecker.staleSourceModels(in: configStore.config.modelMappings)
        proxyServer.setDeprecationWarnings(stale)
    }
    .alert("Config Reset", isPresented: $showingCorruptAlert) {
        Button("OK") { }
    } message: {
        Text("config.json was corrupt and has been reset to defaults. Your previous settings were not recoverable.")
    }
    .task {
        guard !proxyServer.isRunning, !proxyServer.isStopped else { return }
        await proxyServer.start(config: configStore.config)
    }
}

/// True when any banner is being shown — used to adjust top padding on the header.
private var bannerIsVisible: Bool {
    (!proxyServer.isRunning && proxyServer.lastError != nil) ||
    (proxyServer.isRunning && proxyServer.lastError != nil) ||
    !proxyServer.deprecationWarnings.isEmpty
}
```

**Verify:**
Project compiles; the `statusHeaderRow`, `tokenSummaryCard`, `controlRow` references will be unresolved until Tasks 3–5, but the structure is in place.

---

### Task 3: Add compact status header row

**Files:**
- Modify: `ModelProxy/Views/StatusPopover.swift` — add `statusHeaderRow` computed property, replacing `statusSection`

**Context:** The header shows a status indicator on the left and port bindings on the right, all in one `HStack`. Port format: `ClientName:port` pairs joined by `,` with a space. When not running, the right side is empty (no ports bound). The "127.0.0.1 —" prefix from the old layout is removed; just show the port pairs.

**Steps:**

1. Delete the old `// MARK: - Status` section and `statusSection` property (lines 106–148 of the original file).

2. Add the following section in its place:

```swift
// MARK: - Status Header Row

@ViewBuilder
private var statusHeaderRow: some View {
    HStack(alignment: .center, spacing: 6) {
        // Left: status indicator
        Group {
            if proxyServer.isRunning {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                    Text("Running")
                        .font(.caption)
                        .fontWeight(.medium)
                }
            } else if proxyServer.lastError != nil {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                    Text("Error")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.red)
                }
            } else if proxyServer.isStopped {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 7, height: 7)
                    Text("Stopped")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 5) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 7, height: 7)
                    Text("Starting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Spacer()

        // Right: port bindings (only when running)
        if proxyServer.isRunning, !proxyServer.boundPorts.isEmpty {
            Text(portBindingLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(statusHeaderAccessibilityLabel)
}

private var portBindingLabel: String {
    proxyServer.boundPorts
        .sorted { $0.key < $1.key }
        .map { "\($0.key):\($0.value)" }
        .joined(separator: ", ")
}

private var statusHeaderAccessibilityLabel: String {
    if proxyServer.isRunning {
        let ports = portBindingLabel
        return ports.isEmpty
            ? "Proxy running"
            : "Proxy running on \(ports)"
    } else if let error = proxyServer.lastError {
        return "Proxy error: \(error)"
    } else if proxyServer.isStopped {
        return "Proxy stopped"
    } else {
        return "Proxy starting"
    }
}
```

**Verify:**
Build succeeds. No references to the old `statusSection` remain:
```
grep -n "statusSection" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/StatusPopover.swift
```
Expected: no output.

---

### Task 4: Add token summary card

**Files:**
- Modify: `ModelProxy/Views/StatusPopover.swift` — add `tokenSummaryCard` computed property, replacing `statsSection`

**Context:** `TokenStatsStore` exposes `todayTotalTokens: Int` and `stats` (which has `totalInputTokens() -> Int` and `totalOutputTokens() -> Int`). The card shows input (↓), output (↑), and total on one line with a subtle background. When all are zero show a muted "No tokens today" message.

**Steps:**

1. Delete the old `// MARK: - Stats Summary` section and `statsSection` property (lines 151–165 of the original file).

2. Add the following section in its place:

```swift
// MARK: - Token Summary Card

@ViewBuilder
private var tokenSummaryCard: some View {
    let total = tokenStatsStore.todayTotalTokens
    let input = tokenStatsStore.stats.totalInputTokens()
    let output = tokenStatsStore.stats.totalOutputTokens()

    Group {
        if total == 0 {
            Text("No tokens today")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        } else {
            HStack(spacing: 0) {
                // Input
                VStack(spacing: 1) {
                    Text("↓ \(input.formatted())")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("input")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 28)

                // Output
                VStack(spacing: 1) {
                    Text("↑ \(output.formatted())")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("output")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 28)

                // Total
                VStack(spacing: 1) {
                    Text(total.formatted())
                        .font(.caption2.monospacedDigit())
                        .fontWeight(.medium)
                    Text("total")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(.secondary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(total == 0
        ? "Today: no tokens"
        : "Today: \(total.formatted()) tokens, \(input.formatted()) input, \(output.formatted()) output"
    )
}
```

**Verify:**
Build succeeds. Confirm `statsSection` is fully removed:
```
grep -n "statsSection" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/StatusPopover.swift
```
Expected: no output.

---

### Task 5: Replace control section with compact single-row controls

**Files:**
- Modify: `ModelProxy/Views/StatusPopover.swift` — add `controlRow` computed property, replacing `controlSection`

**Context:** Current `controlSection` stacks three full-width buttons vertically. Target: one `HStack` with Start/Stop button (fills remaining space), a gear icon button, and a Quit button — all in a single row. Crystal refs [D-006] and [D-007] require both the settings entry and the start/stop bidirectionality.

**Steps:**

1. Delete the old `// MARK: - Controls` section and `controlSection` property (lines 169–203 of the original file).

2. Add:

```swift
// MARK: - Control Row

@ViewBuilder
private var controlRow: some View {
    HStack(spacing: 8) {
        // Start / Stop button — fills available space
        if proxyServer.isRunning {
            Button {
                Task { await proxyServer.stop() }
            } label: {
                Text("Stop")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Stop Proxy")
            .accessibilityHint("Stops the local proxy server.")
        } else {
            Button {
                Task { await proxyServer.start(config: configStore.config) }
            } label: {
                Text("Start")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Start Proxy")
            .accessibilityHint("Starts the local proxy server on configured ports.")
        }

        // Settings gear — fixed width icon button
        Button {
            openSettings()
        } label: {
            Image(systemName: "gear")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Open Settings")

        // Quit — fixed width
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Text("Quit")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Quit ModelProxy")
        .accessibilityHint("Stops the proxy and closes the application.")
    }
}
```

**Verify:**
Build succeeds. Confirm `controlSection` is fully removed:
```
grep -n "controlSection" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/StatusPopover.swift
```
Expected: no output.

---

### Task 6: Update trafficSection for expanded vertical space

**Files:**
- Modify: `ModelProxy/Views/StatusPopover.swift` — update `trafficSection` maxHeight

**Context:** The traffic list currently has `.frame(maxHeight: 180)`. With the title removed and controls collapsed to one row, there is more vertical space. Increase to `240` to give the list more room as the primary content area. The "Recent Requests" section heading and all existing scroll/auto-scroll logic remain unchanged.

**Steps:**

1. In `trafficSection`, change `.frame(maxHeight: 180)` to `.frame(maxHeight: 240)`.

2. The section label "Recent Requests", the empty state text, `ScrollViewReader`, `LazyVStack`, `onChange` auto-scroll logic, and `TrafficRowView` are all left unchanged.

**Verify:**
```
grep -n "maxHeight" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/StatusPopover.swift
```
Expected: one line showing `maxHeight: 240`.

---

### Task 7: Update bannerSection padding compatibility

**Files:**
- Modify: `ModelProxy/Views/StatusPopover.swift` — `bannerSection`

**Context:** In the old layout, `bannerSection` was a child of the top-level VStack with uniform `.padding()`. In the new layout, horizontal and top padding are applied by the parent `body` via `.padding(.horizontal, 12).padding(.top, 12)`. The banner views themselves use `.padding(8)` for internal inset and `.frame(maxWidth: .infinity)` — these are unchanged. Verify the banner is still rendered correctly with the new structure.

**Steps:**

1. Read the current `bannerSection` (lines 55–103) to confirm no changes are needed to its internal padding or frame modifiers. The outer VStack in the new `body` already wraps it with `padding(.horizontal, 12).padding(.top, 12)`, so the banner's own `.padding(8)` and `.frame(maxWidth: .infinity)` continue to work correctly.

2. No code change is needed to `bannerSection` itself. This task is a verification checkpoint.

**Verify:**
Confirm bannerSection is structurally unchanged:
```
grep -n "bannerSection\|exclamationmark.circle.fill\|exclamationmark.triangle.fill\|red.opacity\|orange.opacity\|yellow.opacity" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/StatusPopover.swift
```
Expected: all three banner background colors present, `bannerSection` appears in both `body` and the `private var bannerSection` definition.

---

### Task 8: Update Preview

**Files:**
- Modify: `ModelProxy/Views/StatusPopover.swift:310-324` (Preview block)

**Context:** The preview uses a default `ProxyServer` which starts as `isRunning == false, isStopped == false` — it will show the "Starting..." state. To preview the running state with ports, the preview must put the server into a running-looking state. Since `isRunning` and `boundPorts` are `private(set)`, the preview cannot set them directly. The existing preview is valid as-is (shows Starting state). Add a second preview showing the running state by using a subclass or by accepting the current limitation.

**Steps:**

1. Update the preview to add a second `#Preview` block that names the stopped/error scenario, making it easier to visually verify both states during development. Keep the existing preview as the "Startup" variant and add a second "Running" variant. Since `isRunning` is `private(set)`, the running state preview will only be achievable at runtime — add a comment noting this and keep both previews pointing at the same types.

Replace the existing `#Preview` block with:

```swift
#Preview("Starting / Stopped") {
    let store = TokenStatsStore()
    StatusPopover()
        .environment(ConfigStore())
        .environment(ProxyServer(tokenStatsStore: store))
        .environment({
            let log = TrafficLog()
            log.append(TrafficEntry(model: "claude-opus-4-6", routeType: .mapped(vendorName: "DashScope"), httpStatus: 200))
            log.append(TrafficEntry(model: "claude-sonnet-4-6", routeType: .passthrough, httpStatus: 200))
            log.append(TrafficEntry(model: "gpt-4o", routeType: .blocked, httpStatus: 403))
            return log
        }())
        .environment(store)
        .environment(LoginItemService())
}
```

The second preview variant (running state) requires runtime start — document this with a comment above the preview block:

```swift
// Note: to preview the running state, launch the app and open the menu bar.
// isRunning and boundPorts are private(set) and cannot be set from a preview.
```

**Verify:**
Xcode Canvas renders the preview without errors.

---

### Task 9: Final build and lint verification

**Files:** No new changes — verification only.

**Steps:**

1. Run a clean build:
```
xcodebuild -scheme ModelProxy -destination 'platform=macOS' clean build 2>&1 | grep -E "error:|warning:|BUILD"
```
Expected: `BUILD SUCCEEDED`, zero `error:` lines, zero `warning:` lines.

2. Confirm old layout strings are gone:
```
grep -n "\"ModelProxy\"\|statsSection\|statusSection\|controlSection\|\.frame(maxWidth: .infinity)" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/StatusPopover.swift
```
Expected: The `"ModelProxy"` title Text and the three old section names do not appear. `.frame(maxWidth: .infinity)` may appear inside banner and Start/Stop button — those are valid.

3. Confirm new symbol names are present in ProxyServer:
```
grep -n "arrow.triangle.branch\|xmark.circle\|exclamationmark.circle" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ProxyServer.swift
```
Expected: all three symbol names present.

4. Confirm accessibility labels cover all interactive elements:
```
grep -n "accessibilityLabel" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/StatusPopover.swift
```
Expected: at least 6 lines — statusHeaderRow combine, tokenSummaryCard, Start button, Stop button, Settings button, Quit button.

---

## Decisions

None.
