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
