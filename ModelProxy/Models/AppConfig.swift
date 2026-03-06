import Foundation
import Observation

/// Top-level configuration container.
/// Loaded from and persisted to config.json by ConfigStore.
/// `@Observable` so SwiftUI views automatically update when properties change.
@Observable
final class AppConfig: Codable {
    var vendors: [Vendor]
    var clients: [ClientConfig]
    /// Global model routing rules, shared across all clients.
    var modelMappings: [ModelMapping]

    // MARK: - Init

    init(
        vendors: [Vendor] = [],
        clients: [ClientConfig] = [],
        modelMappings: [ModelMapping] = []
    ) {
        self.vendors = vendors
        self.clients = clients
        self.modelMappings = modelMappings
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case vendors
        case clients
        case modelMappings
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vendors = try container.decode([Vendor].self, forKey: .vendors)
        clients = try container.decode([ClientConfig].self, forKey: .clients)
        modelMappings = (try? container.decode([ModelMapping].self, forKey: .modelMappings)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vendors, forKey: .vendors)
        try container.encode(clients, forKey: .clients)
        try container.encode(modelMappings, forKey: .modelMappings)
    }
}

// MARK: - Default config

extension AppConfig {
    /// Sensible defaults created on first launch.
    static func makeDefault() -> AppConfig {
        let claudeCodeClient = ClientConfig(
            clientName: "Claude Code",
            port: 8080,
            defaultUpstream: "https://api.anthropic.com"
        )
        let codexClient = ClientConfig(
            clientName: "Codex",
            port: 8081,
            defaultUpstream: "https://api.openai.com"
        )
        return AppConfig(
            vendors: [],
            clients: [claudeCodeClient, codexClient],
            modelMappings: []
        )
    }
}
