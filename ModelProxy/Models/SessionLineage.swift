import Foundation

struct BranchTranscript: Sendable {
    let lineageKey: String
    let branchKey: String
    let clientName: String
    let vendorKey: String
    let signingDomain: SigningDomain
    let replayPolicy: TranscriptReplayPolicy
    var fullMessagesData: Data
    var portableMessagesData: Data
    var portableMessageHashes: [String]
    var lastUpdatedAt: Date
}

struct ConversationLineage: Sendable {
    let lineageKey: String
    let clientName: String
    var branches: [String: BranchTranscript]
    var lastUpdatedAt: Date
}

struct PreparedBranchContext: Sendable {
    let lineageKey: String
    let branchKey: String
    let clientName: String
    let vendorKey: String
    let signingDomain: SigningDomain
    let replayPolicy: TranscriptReplayPolicy
    let preparedFullMessagesData: Data
    let preparedPortableMessagesData: Data
    let preparedPortableMessageHashes: [String]
    let reusedBranchHistory: Bool
    let reusedPortableMessageCount: Int
}

struct PreparedRequest: Sendable {
    let bodyData: Data
    let context: PreparedBranchContext?
    let projectedPortableMessagesData: Data?
}

struct PortableAssistantTurn: Sendable {
    let fullMessageData: Data
    let portableMessageData: Data
}
