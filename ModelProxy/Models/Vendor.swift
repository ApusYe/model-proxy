import Foundation

/// A single upstream API provider.
struct Vendor: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// Base URL of the vendor's API (without version path),
    /// e.g. "https://dashscope.aliyuncs.com/compatible-mode".
    /// The request URI (including "/v1/...") is appended directly.
    var baseURL: String
    /// API key stored in plaintext in config.json (personal-use tool; not Keychain by design).
    var apiKey: String

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        apiKey: String
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}
