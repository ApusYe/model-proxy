import Foundation

/// Immutable routing snapshot for one client port.
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
    }

    enum ResolveResult: Sendable {
        case routed(RouteTarget)
        case blocked(reason: String)
    }

    /// sourceModel -> RouteTarget, built from AppConfig.modelMappings
    private let modelMappings: [String: RouteTarget]
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
        var mappings: [String: RouteTarget] = [:]
        for mapping in config.modelMappings {
            if let vendor = config.vendors.first(where: { $0.id == mapping.targetVendorID }) {
                mappings[mapping.sourceModel] = RouteTarget(
                    baseURL: vendor.baseURL,
                    apiKey: vendor.apiKey,
                    vendorName: vendor.name,
                    vendorID: vendor.id,
                    targetModel: mapping.targetModel,
                    isPassthrough: false
                )
            }
        }
        self.modelMappings = mappings
        self.passthroughBaseURL = clientConfig.defaultUpstream
        self.unmappedPolicy = clientConfig.unmappedPolicy

        // Resolve fallback vendor for .routeAll at build time.
        if clientConfig.unmappedPolicy == .routeAll,
           let vid = clientConfig.fallbackVendorID,
           let vendor = config.vendors.first(where: { $0.id == vid }) {
            self.fallbackTarget = RouteTarget(
                baseURL: vendor.baseURL,
                apiKey: vendor.apiKey,
                vendorName: vendor.name,
                vendorID: vendor.id,
                targetModel: nil,
                isPassthrough: false
            )
        } else {
            self.fallbackTarget = nil
        }
    }

    /// Resolve a route for the given model.
    func resolve(model: String, originalAPIKey: String) -> ResolveResult {
        if let mapped = modelMappings[model] {
            return .routed(mapped)
        }

        switch unmappedPolicy {
        case .passthrough:
            return .routed(RouteTarget(
                baseURL: passthroughBaseURL,
                apiKey: originalAPIKey,
                vendorName: "passthrough",
                vendorID: nil,
                targetModel: nil,
                isPassthrough: true
            ))
        case .routeAll:
            if let fallback = fallbackTarget {
                return .routed(fallback)
            }
            // Fallback vendor not configured or deleted; fall back to passthrough.
            return .routed(RouteTarget(
                baseURL: passthroughBaseURL,
                apiKey: originalAPIKey,
                vendorName: "passthrough",
                vendorID: nil,
                targetModel: nil,
                isPassthrough: true
            ))
        case .block:
            return .blocked(reason: "Model '\(model)' is not mapped and this client is set to block unmapped models.")
        }
    }
}
