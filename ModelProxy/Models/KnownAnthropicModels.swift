import Foundation

/// Preset Anthropic model IDs shown in the RoutingTabView source model picker.
/// Users can also type custom model IDs not in this list.
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
