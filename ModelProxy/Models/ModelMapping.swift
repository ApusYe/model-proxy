import Foundation

/// A single global model routing rule.
/// Maps one Anthropic source model to a vendor-specific target model.
/// Global across all clients — routing rules do not differ by tool.
struct ModelMapping: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// Anthropic model ID to match exactly, e.g. "claude-haiku-4-5".
    var sourceModel: String
    /// Vendor-specific model name to substitute, e.g. "qwen-turbo".
    var targetModel: String
    /// UUID of the Vendor to route to.
    var targetVendorID: UUID

    init(
        id: UUID = UUID(),
        sourceModel: String,
        targetModel: String,
        targetVendorID: UUID
    ) {
        self.id = id
        self.sourceModel = sourceModel
        self.targetModel = targetModel
        self.targetVendorID = targetVendorID
    }
}
