import OSLog

extension Logger {
    private static let subsystem = "com.modelproxy.app"

    static let proxy  = Logger(subsystem: subsystem, category: "proxy")
    static let config = Logger(subsystem: subsystem, category: "config")
    static let stats  = Logger(subsystem: subsystem, category: "stats")
}

// MARK: - AppLog Facade

/// Dual logging facade: os.log + file-based AppLogManager.
/// Usage: `AppLog.proxy.info("message")` replaces `Logger.proxy.info("message")`
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
