import Foundation

protocol BranchMergeReducing: Sendable {
    nonisolated func reduceAssistantMessage(_ message: [String: Any]) throws -> PortableAssistantTurn
}

struct BranchMergeReducer: BranchMergeReducing {
    nonisolated init() {}

    nonisolated func reduceAssistantMessage(_ message: [String: Any]) throws -> PortableAssistantTurn {
        let fullMessageData = try TranscriptProjector.encodeJSONObject(message)
        let portableMessage = TranscriptProjector.makePortableMessage(from: message) ?? message
        let portableMessageData = try TranscriptProjector.encodeJSONObject(portableMessage)
        return PortableAssistantTurn(
            fullMessageData: fullMessageData,
            portableMessageData: portableMessageData
        )
    }
}
