import Foundation

/// Checks configured model mappings against the known Anthropic model list.
/// Returns the set of source model IDs that are no longer in KnownAnthropicModels.all.
enum DeprecationChecker {
    /// Returns source model strings that are not in KnownAnthropicModels.all.
    static func staleSourceModels(in mappings: [ModelMapping]) -> [String] {
        let known = Set(KnownAnthropicModels.all)
        return mappings
            .map(\.sourceModel)
            .filter { !known.contains($0) }
    }
}
