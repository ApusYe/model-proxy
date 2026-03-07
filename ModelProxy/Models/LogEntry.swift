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
