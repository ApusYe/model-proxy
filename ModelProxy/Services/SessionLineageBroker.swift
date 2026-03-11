import Foundation
import OSLog

protocol SessionLineageBrokering: Actor, Sendable {
    func prepareRequest(
        bodyData: Data,
        clientName: String,
        target: RoutingSnapshot.RouteTarget
    ) throws -> PreparedRequest

    func commitResponse(
        context: PreparedBranchContext,
        assistantTurn: PortableAssistantTurn
    ) throws

    func branches(for clientName: String) -> [BranchTranscript]
}

actor SessionLineageBroker: SessionLineageBrokering {
    private let projector: any TranscriptProjecting
    private let fingerprint: any ConversationFingerprinting
    private var lineages: [String: ConversationLineage] = [:]
    private let maxCachedLineagesPerClient = 24

    init(
        projector: any TranscriptProjecting = TranscriptProjector(),
        fingerprint: any ConversationFingerprinting = ConversationFingerprint()
    ) {
        self.projector = projector
        self.fingerprint = fingerprint
    }

    func prepareRequest(
        bodyData: Data,
        clientName: String,
        target: RoutingSnapshot.RouteTarget
    ) throws -> PreparedRequest {
        let prepared = try projector.prepareRequest(
            bodyData: bodyData,
            clientName: clientName,
            target: target,
            existingBranches: branches(for: clientName),
            fingerprint: fingerprint
        )
        if let context = prepared.context {
            AppLog.proxy.debug(
                "[Proxy] [Lineage] client=\(context.clientName) lineage=\(context.lineageKey) branch=\(context.branchKey) vendor=\(context.vendorKey) replay=\(context.replayPolicy.rawValue) reused=\(context.reusedBranchHistory) reusedPortable=\(context.reusedPortableMessageCount)"
            )
        }
        return prepared
    }

    func commitResponse(
        context: PreparedBranchContext,
        assistantTurn: PortableAssistantTurn
    ) throws {
        let fullMessagesData = try TranscriptProjector.appendMessage(
            assistantTurn.fullMessageData,
            to: context.preparedFullMessagesData
        )
        let portableMessagesData = try TranscriptProjector.appendMessage(
            assistantTurn.portableMessageData,
            to: context.preparedPortableMessagesData
        )
        let portableHash = fingerprint.sha256Hex(assistantTurn.portableMessageData)

        var lineage = lineages[context.lineageKey] ?? ConversationLineage(
            lineageKey: context.lineageKey,
            clientName: context.clientName,
            branches: [:],
            lastUpdatedAt: .now
        )
        lineage.branches[context.branchKey] = BranchTranscript(
            lineageKey: context.lineageKey,
            branchKey: context.branchKey,
            clientName: context.clientName,
            vendorKey: context.vendorKey,
            signingDomain: context.signingDomain,
            replayPolicy: context.replayPolicy,
            fullMessagesData: fullMessagesData,
            portableMessagesData: portableMessagesData,
            portableMessageHashes: context.preparedPortableMessageHashes + [portableHash],
            lastUpdatedAt: .now
        )
        lineage.lastUpdatedAt = .now
        lineages[context.lineageKey] = lineage
        trimLineages(for: context.clientName)
    }

    func branches(for clientName: String) -> [BranchTranscript] {
        lineages.values
            .filter { $0.clientName == clientName }
            .flatMap { $0.branches.values }
    }

    private func trimLineages(for clientName: String) {
        let matchingKeys = lineages.values
            .filter { $0.clientName == clientName }
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
            .map(\.lineageKey)

        guard matchingKeys.count > maxCachedLineagesPerClient else { return }
        for lineageKey in matchingKeys.dropFirst(maxCachedLineagesPerClient) {
            lineages.removeValue(forKey: lineageKey)
        }
    }
}
