import Foundation
import CryptoKit

struct ToolUseIDNormalizationResult: Sendable {
    let messages: [[String: Any]]
    let normalizedToolUseCount: Int
    let normalizedToolResultCount: Int

    var changed: Bool {
        normalizedToolUseCount > 0 || normalizedToolResultCount > 0
    }
}

struct ToolUseIDNormalizer {
    nonisolated init() {}

    nonisolated static func normalizeMessages(_ messages: [[String: Any]]) -> ToolUseIDNormalizationResult {
        var state = ToolIDState()
        var normalizedMessages: [[String: Any]] = []
        var normalizedToolUseCount = 0
        var normalizedToolResultCount = 0

        for message in messages {
            let normalized = normalizeMessage(
                message,
                state: &state,
                normalizedToolUseCount: &normalizedToolUseCount,
                normalizedToolResultCount: &normalizedToolResultCount
            )
            normalizedMessages.append(normalized)
        }

        return ToolUseIDNormalizationResult(
            messages: normalizedMessages,
            normalizedToolUseCount: normalizedToolUseCount,
            normalizedToolResultCount: normalizedToolResultCount
        )
    }

    nonisolated static func normalizeMessage(_ message: [String: Any]) -> [String: Any] {
        var state = ToolIDState()
        var normalizedToolUseCount = 0
        var normalizedToolResultCount = 0
        return normalizeMessage(
            message,
            state: &state,
            normalizedToolUseCount: &normalizedToolUseCount,
            normalizedToolResultCount: &normalizedToolResultCount
        )
    }

    nonisolated static func stableSafeID(for original: String) -> String {
        if isValidToolID(original) {
            return original
        }

        let stemScalars = original.unicodeScalars.map { scalar -> Character in
            if isValidScalar(scalar) {
                return Character(String(scalar))
            }
            return "_"
        }
        let stem = String(stemScalars)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        let prefix = stem.isEmpty ? "tool" : String(stem.prefix(24))
        let digest = SHA256.hash(data: Data(original.utf8))
        let hashPrefix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "toolu_\(prefix)_\(hashPrefix)"
    }

    nonisolated static func isValidToolID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return id.unicodeScalars.allSatisfy(isValidScalar(_:))
    }

    private nonisolated static func normalizeMessage(
        _ message: [String: Any],
        state: inout ToolIDState,
        normalizedToolUseCount: inout Int,
        normalizedToolResultCount: inout Int
    ) -> [String: Any] {
        guard let content = message["content"] as? [Any] else {
            return message
        }

        var normalizedMessage = message
        normalizedMessage["content"] = content.map { block in
            guard var dictionary = block as? [String: Any] else {
                return block
            }

            switch (dictionary["type"] as? String)?.lowercased() {
            case "tool_use":
                guard let originalID = dictionary["id"] as? String else {
                    return dictionary
                }
                let normalizedID = normalizedID(for: originalID, state: &state)
                if normalizedID != originalID {
                    dictionary["id"] = normalizedID
                    normalizedToolUseCount += 1
                }
                return dictionary

            case "tool_result":
                guard let originalID = dictionary["tool_use_id"] as? String else {
                    return dictionary
                }
                let normalizedID = normalizedID(for: originalID, state: &state)
                if normalizedID != originalID {
                    dictionary["tool_use_id"] = normalizedID
                    normalizedToolResultCount += 1
                }
                return dictionary

            default:
                return dictionary
            }
        }
        return normalizedMessage
    }

    private nonisolated static func normalizedID(
        for originalID: String,
        state: inout ToolIDState
    ) -> String {
        if let cached = state.rewrittenIDs[originalID] {
            return cached
        }
        if isValidToolID(originalID) {
            return originalID
        }
        let safeID = stableSafeID(for: originalID)
        state.rewrittenIDs[originalID] = safeID
        return safeID
    }

    private nonisolated static func isValidScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 95, 97...122, 45:
            return true
        default:
            return false
        }
    }
}

private struct ToolIDState {
    var rewrittenIDs: [String: String] = [:]
}
