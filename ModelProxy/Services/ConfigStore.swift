import Foundation
import Observation
import OSLog

/// Loads and saves AppConfig to ~/Library/Application Support/ModelProxy/config.json.
/// @MainActor because AppConfig is @Observable and mutated from SwiftUI context.
@MainActor
@Observable
final class ConfigStore {
    private(set) var config: AppConfig
    /// True if config.json was corrupt at launch and was reset to defaults.
    private(set) var didResetFromCorrupt: Bool = false

    private static var configFileURL: URL {
        AppPaths.appSupport.appendingPathComponent("config.json")
    }

    // MARK: - Init

    init() {
        let result = ConfigStore.loadOrCreateDefault()
        self.config = result.config
        self.didResetFromCorrupt = result.wasCorrupt
    }

    func clearCorruptFlag() {
        didResetFromCorrupt = false
    }

    // MARK: - Load

    private static func loadOrCreateDefault() -> (config: AppConfig, wasCorrupt: Bool) {
        let fileURL = configFileURL
        let fm = FileManager.default

        // Ensure directory exists.
        if !fm.fileExists(atPath: AppPaths.appSupport.path) {
            try? fm.createDirectory(at: AppPaths.appSupport, withIntermediateDirectories: true)
        }

        guard fm.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            let defaults = AppConfig.makeDefault()
            try? JSONEncoder.pretty.encode(defaults).write(to: fileURL)
            return (defaults, false)
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

            return (config, false)
        } catch {
            // Corrupt config: reset to defaults. StatusPopover shows one-time alert via didResetFromCorrupt flag.
            Logger.config.error("[ConfigStore] Failed to decode config.json: \(error, privacy: .public). Resetting to defaults.")
            let defaults = AppConfig.makeDefault()
            try? JSONEncoder.pretty.encode(defaults).write(to: fileURL)
            return (defaults, true)
        }
    }

    // MARK: - Save

    func save() {
        do {
            let data = try JSONEncoder.pretty.encode(config)
            try data.write(to: ConfigStore.configFileURL, options: .atomic)
        } catch {
            Logger.config.error("[ConfigStore] Failed to save config.json: \(error, privacy: .public)")
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
