import Foundation

/// Policy for handling models that have no routing rule.
enum UnmappedModelPolicy: String, Codable, CaseIterable, Sendable {
    /// Forward to defaultUpstream unchanged (current key, current model).
    case passthrough
    /// Forward to a chosen fallback vendor (vendor's key, original model name).
    case routeAll
    /// Reject with HTTP 403.
    case block
}

/// Configuration for a single AI client tool (e.g., Claude Code or Codex).
/// Each client gets its own proxy port. The proxy identifies the tool by port and
/// uses `defaultUpstream` as the passthrough target for unmapped models.
struct ClientConfig: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// Display name, e.g. "Claude Code" or "Codex".
    var clientName: String
    /// Localhost port this client's proxy listener binds to.
    var port: Int
    /// Passthrough target URL for unmapped models.
    /// Claude Code default: "https://api.anthropic.com"
    /// Codex default: configured per-installation endpoint.
    var defaultUpstream: String
    /// How to handle models with no routing rule.
    var unmappedPolicy: UnmappedModelPolicy
    /// Vendor to route unmapped models to when policy is `.routeAll`.
    var fallbackVendorID: UUID?

    init(
        id: UUID = UUID(),
        clientName: String,
        port: Int,
        defaultUpstream: String,
        unmappedPolicy: UnmappedModelPolicy = .passthrough,
        fallbackVendorID: UUID? = nil
    ) {
        self.id = id
        self.clientName = clientName
        self.port = port
        self.defaultUpstream = defaultUpstream
        self.unmappedPolicy = unmappedPolicy
        self.fallbackVendorID = fallbackVendorID
    }

    // MARK: - Codable (legacy-tolerant)

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        clientName = try c.decode(String.self, forKey: .clientName)
        port = try c.decode(Int.self, forKey: .port)
        defaultUpstream = (try? c.decode(String.self, forKey: .defaultUpstream)) ?? ""
        unmappedPolicy = (try? c.decode(UnmappedModelPolicy.self, forKey: .unmappedPolicy)) ?? .passthrough
        fallbackVendorID = try? c.decode(UUID.self, forKey: .fallbackVendorID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(clientName, forKey: .clientName)
        try c.encode(port, forKey: .port)
        try c.encode(defaultUpstream, forKey: .defaultUpstream)
        try c.encode(unmappedPolicy, forKey: .unmappedPolicy)
        try c.encodeIfPresent(fallbackVendorID, forKey: .fallbackVendorID)
    }

    enum CodingKeys: String, CodingKey {
        case id, clientName, port, defaultUpstream, unmappedPolicy, fallbackVendorID
    }
}
