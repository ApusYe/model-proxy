import Foundation
import Observation

/// Loads and saves AppConfig to ~/Library/Application Support/ModelProxy/config.json.
/// @MainActor because AppConfig is @Observable and mutated from SwiftUI context.
@MainActor
@Observable
final class ConfigStore {
    private(set) var config: AppConfig

    private static let appSupportURL: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base.appendingPathComponent("ModelProxy", isDirectory: true)
    }()

    private static var configFileURL: URL {
        appSupportURL.appendingPathComponent("config.json")
    }

    // MARK: - Init

    init() {
        self.config = ConfigStore.loadOrCreateDefault()
    }

    // MARK: - Load

    private static func loadOrCreateDefault() -> AppConfig {
        let fileURL = configFileURL
        let fm = FileManager.default

        // Ensure directory exists.
        if !fm.fileExists(atPath: appSupportURL.path) {
            try? fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        }

        guard fm.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            let defaults = AppConfig.makeDefault()
            try? JSONEncoder.pretty.encode(defaults).write(to: fileURL)
            return defaults
        }

        do {
            var config = try JSONDecoder().decode(AppConfig.self, from: data)

            // Migration 1: strip trailing /v1 from baseURLs (Phase 2 convention change).
            for i in 0..<config.vendors.count {
                if config.vendors[i].baseURL.hasSuffix("/v1") {
                    config.vendors[i].baseURL = String(config.vendors[i].baseURL.dropLast(3))
                }
            }

            // Migration 2: clients missing defaultUpstream get a sensible default.
            for i in 0..<config.clients.count {
                if config.clients[i].defaultUpstream.isEmpty {
                    config.clients[i].defaultUpstream = config.clients[i].clientName
                        .lowercased().contains("claude")
                        ? "https://api.anthropic.com"
                        : "https://api.openai.com"
                }
            }

            return config
        } catch {
            // Corrupt config: reset to defaults.
            // Phase 6 will add a user confirmation dialog before resetting.
            print("[ConfigStore] Failed to decode config.json: \(error). Resetting to defaults.")
            let defaults = AppConfig.makeDefault()
            try? JSONEncoder.pretty.encode(defaults).write(to: fileURL)
            return defaults
        }
    }

    // MARK: - Save

    func save() {
        do {
            let data = try JSONEncoder.pretty.encode(config)
            try data.write(to: ConfigStore.configFileURL, options: .atomic)
        } catch {
            print("[ConfigStore] Failed to save config.json: \(error)")
        }
    }

    /// Save config and push updated routing snapshot to running listeners.
    /// Call this from Settings UI after any config change.
    func saveAndReload(proxyServer: ProxyServer) {
        save()
        proxyServer.updateRouting(config: config)
    }
}

// MARK: - JSONEncoder helper

private extension JSONEncoder {
    nonisolated(unsafe) static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
