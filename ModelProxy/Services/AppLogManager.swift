import Foundation
import OSLog

// MARK: - LogFileActor

/// Actor for thread-safe file I/O operations.
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

// MARK: - AppLogManager

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
                // Use os.log directly to avoid recursion
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
