import Foundation
import CryptoKit

protocol ConversationFingerprinting: Sendable {
    nonisolated func sha256Hex(_ data: Data) -> String
}

struct ConversationFingerprint: ConversationFingerprinting {
    nonisolated init() {}

    nonisolated func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
