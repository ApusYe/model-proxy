import OSLog

extension Logger {
    private static let subsystem = "com.modelproxy.app"

    static let proxy  = Logger(subsystem: subsystem, category: "proxy")
    static let config = Logger(subsystem: subsystem, category: "config")
    static let stats  = Logger(subsystem: subsystem, category: "stats")
}
