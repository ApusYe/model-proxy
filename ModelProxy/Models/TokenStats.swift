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
