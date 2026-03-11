import Foundation

enum SigningDomain: String, Codable, CaseIterable, Sendable {
    case anthropicOfficial
    case bedrockAnthropic
    case vertexAnthropic
    case compatibleThirdParty

    var supportsAnthropicSignedReplay: Bool {
        switch self {
        case .anthropicOfficial, .bedrockAnthropic, .vertexAnthropic:
            return true
        case .compatibleThirdParty:
            return false
        }
    }

    static func infer(fromBaseURL baseURL: String) -> SigningDomain {
        guard let host = URL(string: baseURL)?.host?.lowercased() else {
            return .compatibleThirdParty
        }
        if host.contains("api.anthropic.com") {
            return .anthropicOfficial
        }
        if host.contains("bedrock") || host.contains("amazonaws.com") {
            return .bedrockAnthropic
        }
        if host.contains("aiplatform.googleapis.com") || host.contains("vertex") {
            return .vertexAnthropic
        }
        return .compatibleThirdParty
    }
}

enum TranscriptReplayPolicy: String, Codable, CaseIterable, Sendable {
    case transparent
    case portableOnly

    static func defaultPolicy(for signingDomain: SigningDomain) -> TranscriptReplayPolicy {
        signingDomain.supportsAnthropicSignedReplay ? .transparent : .portableOnly
    }
}

