import Foundation
import Observation
import OSLog

/// Owns the in-memory token stats accumulator and persists daily totals to disk.
/// @MainActor so SwiftUI can observe it without cross-actor hops (matches TrafficLog pattern).
@MainActor
@Observable
final class TokenStatsStore {

    // MARK: - Observable State

    /// Current in-memory stats for today. Reset when the calendar date rolls over.
    private(set) var stats: TokenStats = TokenStats()

    /// The calendar date these stats belong to (ISO 8601, e.g. "2026-03-06").
    private(set) var statsDate: String = ""

    // MARK: - File URL

    private static let appSupportURL: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base.appendingPathComponent("ModelProxy", isDirectory: true)
    }()

    private static func fileURL(for date: String) -> URL {
        appSupportURL.appendingPathComponent("token-stats-\(date).json")
    }

    private static func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date())
    }

    // MARK: - Init

    init() {
        let today = Self.todayString()
        self.statsDate = today
        self.stats = Self.load(for: today)
    }

    // MARK: - Accumulate

    /// Called from ProxyForwarder after a successful response with usage data.
    /// Resets the accumulator if the calendar date has rolled over since last write.
    func add(vendorID: UUID, model: String, input: Int, output: Int) {
        let today = Self.todayString()
        if today != statsDate {
            statsDate = today
            stats = TokenStats()
        }
        stats.add(vendorID: vendorID, modelID: model, input: input, output: output)
        persistAsync()
    }

    // MARK: - Computed helpers for UI

    /// Total tokens (input + output) for today across all vendors and models.
    var todayTotalTokens: Int {
        stats.totalInputTokens() + stats.totalOutputTokens()
    }

    /// Rows for the Statistics table: (vendorID, model, record), sorted by vendor then model.
    var tableRows: [(vendorID: UUID, model: String, record: ModelTokenRecord)] {
        stats.records.sorted { $0.key.uuidString < $1.key.uuidString }.flatMap { (vid, modelMap) in
            modelMap.sorted { $0.key < $1.key }.map { (model, record) in
                (vendorID: vid, model: model, record: record)
            }
        }
    }

    // MARK: - Persistence

    private func persistAsync() {
        let snapshot = DailyTokenSnapshot(
            date: statsDate,
            usageByVendorAndModel: stats.records.reduce(into: [:]) { result, pair in
                result[pair.key.uuidString] = pair.value
            }
        )
        let fileURL = Self.fileURL(for: statsDate)
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                Logger.stats.error("[TokenStatsStore] Failed to persist stats: \(error, privacy: .public)")
            }
        }
    }

    private static func load(for date: String) -> TokenStats {
        let fm = FileManager.default
        if !fm.fileExists(atPath: appSupportURL.path) {
            try? fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        }

        let url = fileURL(for: date)
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(DailyTokenSnapshot.self, from: data) else {
            return TokenStats()
        }

        var result = TokenStats()
        for (vendorIDString, modelMap) in snapshot.usageByVendorAndModel {
            guard let vendorID = UUID(uuidString: vendorIDString) else { continue }
            for (model, record) in modelMap {
                result.add(
                    vendorID: vendorID,
                    modelID: model,
                    input: record.inputTokens,
                    output: record.outputTokens
                )
            }
        }
        return result
    }
}
