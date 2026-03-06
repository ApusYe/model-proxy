import Foundation
import NIOCore
import NIOFoundationCompat

/// Thread-safe routing resolver.
/// Holds an atomic snapshot of routing config; swapped on config change (Phase 3).
actor RequestRouter {

    private var snapshot: RoutingSnapshot

    init(snapshot: RoutingSnapshot) {
        self.snapshot = snapshot
    }

    /// Atomically replace the routing table. In-flight requests keep the old snapshot.
    func updateSnapshot(_ newSnapshot: RoutingSnapshot) {
        self.snapshot = newSnapshot
    }

    /// Parse raw HTTP body bytes, extract the `model` field, and return a resolved target.
    /// - Parameter bodyBytes: accumulated request body buffer.
    /// - Parameter originalAPIKey: Authorization value from the incoming request.
    /// - Returns: RouteTarget with resolved base URL and API key, plus extracted model string.
    func resolve(
        bodyBytes: ByteBuffer,
        originalAPIKey: String
    ) throws -> (result: RoutingSnapshot.ResolveResult, model: String) {
        guard let data = bodyBytes.getData(at: bodyBytes.readerIndex, length: bodyBytes.readableBytes) else {
            throw RouterError.unreadableBody
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? String, !model.isEmpty else {
            throw RouterError.missingModelField
        }
        let result = snapshot.resolve(model: model, originalAPIKey: originalAPIKey)
        return (result, model)
    }
}

enum RouterError: Error, CustomStringConvertible {
    case unreadableBody
    case missingModelField

    var description: String {
        switch self {
        case .unreadableBody:   return "Request body could not be read as bytes"
        case .missingModelField: return "Request JSON missing or empty 'model' field"
        }
    }
}
