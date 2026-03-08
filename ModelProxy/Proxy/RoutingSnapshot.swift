import Foundation
import OSLog

/// Routing snapshot for one client port.
/// Built from AppConfig global mappings + the ClientConfig for the receiving port.
/// Captured at request time; safe to use from any concurrency context.
struct RoutingSnapshot: Sendable {

    struct RouteTarget: Sendable {
        /// Vendor baseURL, e.g. "https://dashscope.aliyuncs.com/compatible-mode"
        let baseURL: String
        /// Vendor API key (empty string = use original key from request)
        let apiKey: String
        let vendorName: String
        /// Vendor UUID for token stats keying; nil for passthrough routes.
        let vendorID: UUID?
        /// Replacement model name; nil = no model field substitution
        let targetModel: String?
        /// true = pure passthrough — proxy does not touch headers, key, or body
        let isPassthrough: Bool
        /// Per-vendor connect timeout in seconds.
        let connectTimeoutSeconds: Int
        /// Per-vendor read timeout in seconds.
        let readTimeoutSeconds: Int
    }

    // MARK: - Failover state

    enum ActiveTarget: Sendable {
        case primary
        case backup
    }

    struct RouteState: Sendable {
        var failCount: Int = 0
        var activeTarget: ActiveTarget = .primary
    }

    enum ResolveResult: Sendable {
        case routed(RouteTarget)
        case blocked(reason: String)
    }

    /// sourceModel -> [RouteTarget], built from AppConfig.modelMappings.
    /// Array: first = primary, second = backup (if present).
    private let modelMappings: [String: [RouteTarget]]
    /// Per-model failover state (failCount + activeTarget). Keyed by sourceModel.
    private var routeStates: [String: RouteState]
    /// Passthrough target for unmapped models: the client's configured defaultUpstream.
    private let passthroughBaseURL: String
    /// Policy for unmapped models.
    private let unmappedPolicy: UnmappedModelPolicy
    /// Fallback vendor target (resolved at snapshot build time); used when policy is .routeAll.
    private let fallbackTarget: RouteTarget?

    /// Build a snapshot for a specific client port.
    /// - Parameters:
    ///   - config: full AppConfig (provides global modelMappings + vendor lookup)
    ///   - clientConfig: the ClientConfig whose port received the request
    init(from config: AppConfig, for clientConfig: ClientConfig) {
        var mappings: [String: [RouteTarget]] = [:]
        for mapping in config.modelMappings {
            guard let vendor = config.vendors.first(where: { $0.id == mapping.targetVendorID }) else {
                continue
            }
            let primary = RouteTarget(
                baseURL: vendor.baseURL,
                apiKey: vendor.apiKey,
                vendorName: vendor.name,
                vendorID: vendor.id,
                targetModel: mapping.targetModel,
                isPassthrough: false,
                connectTimeoutSeconds: vendor.connectTimeoutSeconds,
                readTimeoutSeconds: vendor.readTimeoutSeconds
            )
            var targets = [primary]

            // Build backup target if configured and compatible.
            if let backupVendorID = mapping.backupTargetVendorID,
               let backupVendor = config.vendors.first(where: { $0.id == backupVendorID }),
               backupVendor.compatibleClientID == nil || backupVendor.compatibleClientID == clientConfig.id {
                let backup = RouteTarget(
                    baseURL: backupVendor.baseURL,
                    apiKey: backupVendor.apiKey,
                    vendorName: backupVendor.name,
                    vendorID: backupVendor.id,
                    targetModel: mapping.backupTargetModel ?? mapping.targetModel,
                    isPassthrough: false,
                    connectTimeoutSeconds: backupVendor.connectTimeoutSeconds,
                    readTimeoutSeconds: backupVendor.readTimeoutSeconds
                )
                targets.append(backup)
            }

            mappings[mapping.sourceModel] = targets
        }
        self.modelMappings = mappings
        self.routeStates = [:]
        self.passthroughBaseURL = clientConfig.defaultUpstream
        self.unmappedPolicy = clientConfig.unmappedPolicy

        // Resolve fallback vendor for .routeAll at build time.
        if clientConfig.unmappedPolicy == .routeAll,
           let vid = clientConfig.fallbackVendorID,
           let vendor = config.vendors.first(where: { $0.id == vid }) {
            let resolvedModel: String? = {
                guard let m = clientConfig.fallbackTargetModel, !m.isEmpty else { return nil }
                return m
            }()
            self.fallbackTarget = RouteTarget(
                baseURL: vendor.baseURL,
                apiKey: vendor.apiKey,
                vendorName: vendor.name,
                vendorID: vendor.id,
                targetModel: resolvedModel,
                isPassthrough: false,
                connectTimeoutSeconds: vendor.connectTimeoutSeconds,
                readTimeoutSeconds: vendor.readTimeoutSeconds
            )
        } else {
            self.fallbackTarget = nil
        }
    }

    /// Resolve a route for the given model.
    func resolve(model: String, originalAPIKey: String) -> (result: ResolveResult, state: RouteState) {
        // Exact match first, then prefix match (longest-prefix-wins).
        if let targets = modelMappings[model]
            ?? modelMappings.filter({ model.hasPrefix($0.key) }).max(by: { $0.key.count < $1.key.count })?.value {
            let state = routeStates[model] ?? RouteState()
            let target = selectTarget(from: targets, state: state)
            return (.routed(target), state)
        }

        let defaultState = RouteState()
        switch unmappedPolicy {
        case .passthrough:
            return (.routed(RouteTarget(
                baseURL: passthroughBaseURL,
                apiKey: originalAPIKey,
                vendorName: "passthrough",
                vendorID: nil,
                targetModel: nil,
                isPassthrough: true,
                connectTimeoutSeconds: 10,
                readTimeoutSeconds: 120
            )), defaultState)
        case .routeAll:
            if let fallback = fallbackTarget {
                return (.routed(fallback), defaultState)
            }
            AppLog.proxy.warning("[RoutingSnapshot] routeAll fallback vendor missing or deleted for model '\(model)'; falling back to passthrough")
            return (.routed(RouteTarget(
                baseURL: passthroughBaseURL,
                apiKey: originalAPIKey,
                vendorName: "passthrough",
                vendorID: nil,
                targetModel: nil,
                isPassthrough: true,
                connectTimeoutSeconds: 10,
                readTimeoutSeconds: 120
            )), defaultState)
        case .block:
            return (.blocked(reason: "Model '\(model)' is not mapped and this client is set to block unmapped models."), defaultState)
        }
    }

    /// Returns all targets for a mapped model (for failover use by ProxyForwarder).
    /// Returns nil if model is not mapped.
    func targets(for model: String) -> [RouteTarget]? {
        modelMappings[model]
            ?? modelMappings.filter({ model.hasPrefix($0.key) }).max(by: { $0.key.count < $1.key.count })?.value
    }

    /// Write back mutated failover state from ProxyForwarder.
    mutating func updateRouteState(for model: String, state: RouteState) {
        routeStates[model] = state
    }

    // MARK: - Private

    private func selectTarget(from targets: [RouteTarget], state: RouteState) -> RouteTarget {
        switch state.activeTarget {
        case .primary:
            return targets[0]
        case .backup:
            // Guard: if no backup exists, fall back to primary.
            return targets.count > 1 ? targets[1] : targets[0]
        }
    }
}
