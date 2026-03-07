# Debug Tab Implementation Plan

**Goal:** Add a Debug tab to Settings with file-based logging, live log viewer, auto-cleanup, compression, and configurable log levels.

**Architecture:** Create `AppLog` facade + `AppLogManager` service. `AppLog` provides static call sites (`AppLog.proxy.info("...")`) that write to both os.log and AppLogManager. AppLogManager handles file I/O (via `LogFileActor`), in-memory ring buffer (for live viewer), and config-driven filtering. `DebugConfig` added to existing `AppConfig` for persistence.

**Tech Stack:** Swift 6, SwiftUI, OSLog, Foundation

**Design doc:** None
**Design analysis:** None
**Crystal file:** None

---

## Task 1: Add DebugConfig Model to AppConfig

**Files:**
- Modify: `ModelProxy/Models/AppConfig.swift`

**Steps:**
1. Add `DebugConfig` struct before `AppConfig`:
```swift
struct DebugConfig: Codable, Hashable {
    var isEnabled: Bool = false
    var minimumLogLevel: LogLevel = .info
    var autoCleanupEnabled: Bool = true
    var cleanupAfterDays: Int = 7
    var compressAfterDays: Int = 3

    enum LogLevel: String, Codable, CaseIterable, Comparable {
        case debug, info, warning, error

        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            let order: [Self] = [.debug, .info, .warning, .error]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }
}
```

2. Add `var debug: DebugConfig` field to `AppConfig`, init parameter with default `DebugConfig()`.

3. Add `case debug` to `CodingKeys`.

4. In `init(from decoder:)`, add:
```swift
debug = (try? container.decode(DebugConfig.self, forKey: .debug)) ?? DebugConfig()
```

5. In `encode(to:)`, add:
```swift
try container.encode(debug, forKey: .debug)
```

6. Add `import OSLog` at top of file (needed for `OSLogType`).

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build`
Expected: Build succeeds. Existing config.json loads without error; `debug` field defaults via decoder fallback.

---

## Task 2: Create LogEntry Model

**Files:**
- Create: `ModelProxy/Models/LogEntry.swift`

**Steps:**
1. Create the model:
```swift
import Foundation

struct LogEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let category: String
    let level: DebugConfig.LogLevel
    let message: String

    init(id: UUID = UUID(), timestamp: Date = Date(),
         category: String, level: DebugConfig.LogLevel, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
    }
}
```

**Verify:**
Run: `xcodebuild ... build`
Expected: Build succeeds.

---

## Task 3: Create AppLogManager and LogFileActor

**Files:**
- Create: `ModelProxy/Services/AppLogManager.swift`

**Design notes (fixes from plan verification):**
- AppLogManager does NOT write to os.log — it only handles file + memory buffer. os.log is handled by the `AppLog` facade (Task 4).
- `clearCurrentLog()` closes file handle BEFORE removing directory.
- Compression uses async Process with `terminationHandler` instead of blocking `waitUntilExit()`.

**Steps:**
1. Create `LogFileActor`:
```swift
import Foundation

actor LogFileActor {
    private let logsDirectory: URL
    private let fileManager = FileManager.default
    private var currentDate: String = ""
    private var currentFileHandle: FileHandle?

    nonisolated(unsafe) private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(logsDirectory: URL) {
        self.logsDirectory = logsDirectory
    }

    func ensureLogsDirectory() throws {
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    func writeEntry(_ entry: LogEntry) throws {
        let dateStr = Self.dateFormatter.string(from: entry.timestamp)

        if dateStr != currentDate {
            currentFileHandle?.closeFile()
            currentFileHandle = nil
            currentDate = dateStr
        }

        if currentFileHandle == nil {
            let fileURL = logsDirectory.appendingPathComponent("modelproxy-\(dateStr).log")
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            currentFileHandle = try FileHandle(forWritingTo: fileURL)
            try currentFileHandle?.seekToEnd()
        }

        let timeStr = Self.timeFormatter.string(from: entry.timestamp)
        let levelStr = entry.level.rawValue.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)
        let line = "[\(timeStr)] [\(entry.category)] \(levelStr) \(entry.message)\n"

        if let data = line.data(using: .utf8) {
            try currentFileHandle?.write(contentsOf: data)
        }
    }

    func getLogFileURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: logsDirectory.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return contents.filter { $0.pathExtension == "log" || $0.pathExtension == "gz" }
    }

    func getLogFilesInfo() throws -> [(url: URL, size: Int64, modified: Date)] {
        try getLogFileURLs().map { url in
            let attrs = try fileManager.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? Int64) ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? Date.distantPast
            return (url: url, size: size, modified: modified)
        }
    }

    func deleteOldLogFiles(olderThan days: Int) throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        for url in try getLogFileURLs() {
            let attrs = try fileManager.attributesOfItem(atPath: url.path)
            if let modified = attrs[.modificationDate] as? Date, modified < cutoff {
                try fileManager.removeItem(at: url)
            }
        }
    }

    func compressOldLogFiles(olderThan days: Int) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let logFiles = try getLogFileURLs().filter { $0.pathExtension == "log" }

        for url in logFiles {
            let attrs = try fileManager.attributesOfItem(atPath: url.path)
            if let modified = attrs[.modificationDate] as? Date, modified < cutoff {
                try await compressFile(at: url)
            }
        }
    }

    private func compressFile(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = [url.path]
            process.terminationHandler = { _ in cont.resume() }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    func clearAllLogs() throws {
        // Close handle FIRST, then remove directory
        currentFileHandle?.closeFile()
        currentFileHandle = nil
        currentDate = ""
        if fileManager.fileExists(atPath: logsDirectory.path) {
            try fileManager.removeItem(at: logsDirectory)
        }
        try ensureLogsDirectory()
    }
}
```

2. Create `AppLogManager`:
```swift
/// Manages in-memory log buffer and file-based persistence.
/// Does NOT write to os.log — that is handled by the AppLog facade.
@MainActor
@Observable
final class AppLogManager {
    static let shared = AppLogManager()

    private(set) var entries: [LogEntry] = []
    private let maxEntries = 1000
    let fileActor: LogFileActor

    private(set) var isEnabled = false
    private var minimumLevel: DebugConfig.LogLevel = .info

    private init() {
        let logsDir = AppPaths.appSupport.appendingPathComponent("logs", isDirectory: true)
        self.fileActor = LogFileActor(logsDirectory: logsDir)
    }

    func configure(from config: DebugConfig) async {
        isEnabled = config.isEnabled
        minimumLevel = config.minimumLogLevel

        if isEnabled {
            do {
                try await fileActor.ensureLogsDirectory()
                if config.autoCleanupEnabled {
                    try await fileActor.compressOldLogFiles(olderThan: config.compressAfterDays)
                    try await fileActor.deleteOldLogFiles(olderThan: config.cleanupAfterDays)
                }
            } catch {
                // Use os.log directly here to avoid recursion
                Logger.config.error("[AppLogManager] Init failed: \(error, privacy: .public)")
            }
        }
    }

    /// Called by AppLog facade. Only writes to file + memory buffer (not os.log).
    func record(category: String, level: DebugConfig.LogLevel, message: String) {
        guard isEnabled, level >= minimumLevel else { return }

        let entry = LogEntry(category: category, level: level, message: message)

        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        Task {
            do {
                try await fileActor.writeEntry(entry)
            } catch {
                // Fail silently to avoid log spam
            }
        }
    }

    func clearLogs() async throws {
        entries.removeAll()
        try await fileActor.clearAllLogs()
    }

    func getLogFilesInfo() async throws -> [(url: URL, size: Int64, modified: Date)] {
        try await fileActor.getLogFilesInfo()
    }

    var logsDirectory: URL {
        AppPaths.appSupport.appendingPathComponent("logs", isDirectory: true)
    }
}
```

**Verify:**
Run: `xcodebuild ... build`
Expected: Build succeeds. No SwiftUI import in this file.

---

## Task 4: Create AppLog Facade (Replaces Logger Extension)

**Files:**
- Modify: `ModelProxy/App/AppLogger.swift`

**Design notes (fixes from verification):**
- Does NOT use Logger extension with `dualX` methods — Logger has no `.category` property.
- Instead, `AppLog` is a standalone struct with static instances matching Logger categories.
- Each method: (1) writes to os.log via Logger, (2) calls AppLogManager.record() for file + memory.

**Steps:**
1. Add `AppLog` struct after existing Logger extension:
```swift
/// Facade for dual logging: os.log + file-based AppLogManager.
/// Usage: AppLog.proxy.info("message") replaces Logger.proxy.info("message")
struct AppLog: Sendable {
    static let proxy  = AppLog(category: "proxy",  logger: .proxy)
    static let config = AppLog(category: "config", logger: .config)
    static let stats  = AppLog(category: "stats",  logger: .stats)

    private let category: String
    private let logger: Logger

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        forward(level: .debug, message: message)
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        forward(level: .info, message: message)
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        forward(level: .warning, message: message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        forward(level: .error, message: message)
    }

    private func forward(level: DebugConfig.LogLevel, message: String) {
        Task { @MainActor in
            AppLogManager.shared.record(category: category, level: level, message: message)
        }
    }
}
```

**Verify:**
Run: `xcodebuild ... build`
Expected: Build succeeds.

---

## Task 5: Migrate Existing Logger Calls to AppLog

**Files:** (11 call sites across 8 files)
- `ModelProxy/Proxy/ProxyServer.swift` — 2 calls (lines 90, 137)
- `ModelProxy/Proxy/ProxyForwarder.swift` — 2 calls (lines 38, 47)
- `ModelProxy/Proxy/ProxyChannelHandler.swift` — 1 call (line 76)
- `ModelProxy/Proxy/ResponseRelay.swift` — 1 call (line 97)
- `ModelProxy/Proxy/RoutingSnapshot.swift` — 1 call (line 105)
- `ModelProxy/Services/ConfigStore.swift` — 2 calls (lines 71, 85)
- `ModelProxy/Services/TokenStatsStore.swift` — 1 call (line 89)
- `ModelProxy/Services/LoginItemService.swift` — 1 call (line 26)

**Steps:**
Migration pattern — replace `Logger.{cat}.{level}("...\(val, privacy: .public)...")` with `AppLog.{cat}.{level}("...\(val)...")`:

Example transformations:
```swift
// Before:
Logger.proxy.info("[ProxyServer] \(clientCfg.clientName, privacy: .public) listening on 127.0.0.1:\(actualPort, privacy: .public)")
// After:
AppLog.proxy.info("[ProxyServer] \(clientCfg.clientName) listening on 127.0.0.1:\(actualPort)")

// Before:
Logger.proxy.error("[ProxyChannelHandler] Channel error: \(error, privacy: .public)")
// After:
AppLog.proxy.error("[ProxyChannelHandler] Channel error: \(error)")

// Before:
Logger.config.error("[ConfigStore] Failed to decode config.json: \(error, privacy: .public). Resetting to defaults.")
// After:
AppLog.config.error("[ConfigStore] Failed to decode config.json: \(error). Resetting to defaults.")
```

Apply this pattern to all 11 call sites. Remove `, privacy: .public` from all interpolations.

**Verify:**
Run: `xcodebuild ... build`
Expected: Build succeeds. `grep -r 'Logger\.\(proxy\|config\|stats\)\.\(info\|error\|warning\)' ModelProxy/` returns 0 matches (only `Logger` references left are the static declarations in AppLogger.swift and the one direct call in AppLogManager.configure()).

---

## Task 6: Create LogViewerView Component

**Files:**
- Create: `ModelProxy/Views/Components/LogViewerView.swift`

**Design note:** Created BEFORE DebugTabView (Task 7) so Task 7's build verification succeeds.

**Steps:**
1. Create the log viewer:
```swift
import SwiftUI
import UniformTypeIdentifiers

struct LogViewerView: View {
    @Environment(AppLogManager.self) private var logManager
    @State private var selectedCategory: String = "All"
    @State private var searchText = ""
    @State private var autoScroll = true

    private let categories = ["All", "proxy", "config", "stats"]

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            logListView
            Divider()
            controlBar
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack {
            Picker("Filter", selection: $selectedCategory) {
                ForEach(categories, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 150)

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Log List

    private var logListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredEntries) { entry in
                        LogEntryRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: logManager.entries.count) {
                if autoScroll, let last = filteredEntries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: 200)
        .background(.background)
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack {
            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)

            Spacer()

            Button("Clear") {
                Task { try? await logManager.clearLogs() }
            }
            .buttonStyle(.mpInline)

            Button("Open Log Folder") {
                NSWorkspace.shared.open(logManager.logsDirectory)
            }
            .buttonStyle(.mpInline)

            Button("Export Log") { exportLog() }
                .buttonStyle(.mpInline)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Filtering

    private var filteredEntries: [LogEntry] {
        var result = logManager.entries
        if selectedCategory != "All" {
            result = result.filter { $0.category == selectedCategory }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.message.localizedCaseInsensitiveContains(searchText) ||
                $0.category.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    // MARK: - Export

    private func exportLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "modelproxy-export.log"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content = filteredEntries.map { entry in
            let time = LogEntryRow.timeFormatter.string(from: entry.timestamp)
            return "[\(time)] [\(entry.category)] \(entry.level.rawValue.uppercased()) \(entry.message)"
        }.joined(separator: "\n")

        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Log Entry Row

struct LogEntryRow: View {
    let entry: LogEntry

    nonisolated(unsafe) static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            Text("[\(entry.category)]")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            Text(entry.level.rawValue.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(levelColor)
                .frame(width: 50, alignment: .leading)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(nil)
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}
```

**Verify:**
Run: `xcodebuild ... build`
Expected: Build succeeds.

---

## Task 7: Create DebugTabView

**Files:**
- Create: `ModelProxy/Views/DebugTabView.swift`

**Steps:**
1. Create the Debug tab:
```swift
import SwiftUI

struct DebugTabView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(AppLogManager.self) private var logManager

    var body: some View {
        Form {
            debugToggleSection

            if configStore.config.debug.isEnabled {
                logSettingsSection
                liveLogSection
                storageInfoSection
            } else {
                disabledSection
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Debug Toggle

    private var debugToggleSection: some View {
        Section {
            Toggle(isOn: binding(\.isEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Debug Mode")
                    Text("Enable file-based logging and log viewer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Log Settings

    private var logSettingsSection: some View {
        Section("Log Settings") {
            Picker("Minimum Level", selection: binding(\.minimumLogLevel)) {
                ForEach(DebugConfig.LogLevel.allCases, id: \.self) {
                    Text($0.rawValue.capitalized).tag($0)
                }
            }

            Toggle("Auto Cleanup", isOn: binding(\.autoCleanupEnabled))

            if configStore.config.debug.autoCleanupEnabled {
                HStack {
                    Text("Retain")
                    TextField("", value: binding(\.cleanupAfterDays), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                    Text("days")
                }

                HStack {
                    Text("Compress After")
                    TextField("", value: binding(\.compressAfterDays), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                    Text("days")
                }
            }
        }
    }

    // MARK: - Live Log

    private var liveLogSection: some View {
        Section("Live Log") {
            LogViewerView()
        }
    }

    // MARK: - Storage Info

    private var storageInfoSection: some View {
        Section {
            HStack {
                Text("Log storage:")
                Text(logManager.logsDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            StorageInfoRow()
        }
    }

    // MARK: - Disabled State

    private var disabledSection: some View {
        Section {
            Text("Debug mode is disabled. Enable it to view logs, configure log levels, and manage log files.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Binding Helper

    /// Creates a binding to a DebugConfig keypath that auto-saves and reconfigures.
    private func binding<T>(_ keyPath: WritableKeyPath<DebugConfig, T>) -> Binding<T> {
        Binding(
            get: { configStore.config.debug[keyPath: keyPath] },
            set: { newValue in
                configStore.config.debug[keyPath: keyPath] = newValue
                configStore.save()
                Task { await logManager.configure(from: configStore.config.debug) }
            }
        )
    }
}

// MARK: - Storage Info Row

private struct StorageInfoRow: View {
    @Environment(AppLogManager.self) private var logManager
    @State private var totalSize: Int64 = 0
    @State private var fileCount: Int = 0

    var body: some View {
        HStack {
            Text("Current size:")
            Text("\(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)) (\(fileCount) files)")
                .foregroundStyle(.secondary)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        do {
            let info = try await logManager.getLogFilesInfo()
            totalSize = info.reduce(0) { $0 + $1.size }
            fileCount = info.count
        } catch {
            totalSize = 0
            fileCount = 0
        }
    }
}
```

**Verify:**
Run: `xcodebuild ... build`
Expected: Build succeeds.

---

## Task 8: Wire Up Debug Tab in Settings and App

**Files:**
- Modify: `ModelProxy/Views/SettingsView.swift`
- Modify: `ModelProxy/App/ModelProxyApp.swift`

**Design note (fix from verification):** Do NOT create a redundant `ConfigStore()` in init. Use `.task {}` modifier to configure AppLogManager from the existing `configStore`.

**Steps:**
1. In `SettingsView.swift`, add Debug tab after Statistics:
```swift
StatisticsTabView()
    .tabItem { Label("Statistics", systemImage: "chart.bar") }

DebugTabView()
    .tabItem { Label("Debug", systemImage: "ladybug") }
```

2. In `ModelProxyApp.swift`, add `AppLogManager.shared` to environment for both scenes, and configure on launch via `.task {}`:

```swift
var body: some Scene {
    MenuBarExtra("ModelProxy", systemImage: proxyServer.menuBarSymbol) {
        StatusPopover()
            .environment(configStore)
            .environment(proxyServer)
            .environment(proxyServer.trafficLog)
            .environment(tokenStatsStore)
            .environment(loginItemService)
            .environment(AppLogManager.shared)
    }
    .menuBarExtraStyle(.window)

    Settings {
        SettingsView()
            .environment(configStore)
            .environment(proxyServer)
            .environment(tokenStatsStore)
            .environment(loginItemService)
            .environment(AppLogManager.shared)
            .onDisappear {
                NSApp.setActivationPolicy(.accessory)
            }
            .task {
                await AppLogManager.shared.configure(from: configStore.config.debug)
            }
    }
}
```

Remove the init()-based Task if any was added earlier. The `.task {}` on Settings is sufficient since debug logging only matters when the app is running.

**Verify:**
Run: `xcodebuild ... build`
Expected: Build succeeds. Debug tab appears as 6th tab in Settings.

---

## Task 9: Verify Build and Smoke Test

**Steps:**
1. Build: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build`
2. Verify no warnings related to new code.
3. Grep to confirm migration complete:
   - `grep -r 'Logger\.\(proxy\|config\|stats\)\.\(info\|error\|warning\|debug\)(' ModelProxy/` should return 0 matches outside of `AppLogger.swift` and `AppLogManager.swift`.

**Verify:**
Expected: Clean build, all Logger calls migrated to AppLog.

---

## Task 10: Manual Testing — File Logging and Live Viewer

⚠️ 需设备验证

**Steps:**
1. Open Settings → Debug tab.
2. Enable Debug Mode.
3. Start/stop proxy to generate log entries.
4. Verify file created at `~/Library/Application Support/ModelProxy/logs/modelproxy-YYYY-MM-DD.log`.
5. Verify Live Log section shows entries in real-time.
6. Test category filter (select "proxy" only).
7. Test text search.
8. Test Clear button — file deleted, viewer cleared.
9. Test Open Log Folder — Finder opens.
10. Test Export Log — save dialog, exported file content correct.

---

## Task 11: Manual Testing — Auto-Cleanup and Compression

⚠️ 需设备验证

**Steps:**
1. Create backdated test files:
   ```bash
   cd ~/Library/Application\ Support/ModelProxy/logs/
   echo "test" > modelproxy-2026-02-01.log && touch -t 202602010000 modelproxy-2026-02-01.log
   echo "test" > modelproxy-2026-02-25.log && touch -t 202602250000 modelproxy-2026-02-25.log
   ```
2. Set Retain = 7 days, Compress After = 3 days.
3. Toggle Debug Mode off then on (triggers configure).
4. Verify: Feb 1 file deleted, Feb 25 file compressed to .gz, today's file untouched.

---

## Task 12: Manual Testing — Persistence and Debug Toggle

⚠️ 需设备验证

**Steps:**
1. Configure: Debug ON, Level = Warning, Retain = 14, Compress = 7, Cleanup OFF.
2. Quit and relaunch app.
3. Verify all settings retained.
4. Toggle Debug OFF — verify UI collapses to disabled message.
5. Toggle Debug ON — verify UI restores, previous log file still exists.

---

## Decisions

None. All requirements clear from scope and approved UI design.
