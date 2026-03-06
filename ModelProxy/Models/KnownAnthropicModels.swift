import Foundation

/// Canonical list of supported Anthropic model IDs.
/// Used by RoutingTabView picker and deprecation detection on launch.
/// Update this list when Anthropic releases or retires models.
enum KnownAnthropicModels {
    static let all: [String] = [
        "claude-haiku-4-5",
        "claude-sonnet-4-6",
        "claude-opus-4-6",
        "claude-3-5-haiku-20241022",
        "claude-3-5-sonnet-20241022",
        "claude-3-opus-20240229",
    ]
}
