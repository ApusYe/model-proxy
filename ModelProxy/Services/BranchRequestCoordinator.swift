import Foundation

protocol BranchRequestCoordinating: Actor, Sendable {
    func acquire(context: PreparedBranchContext) async -> BranchRequestAcquireDecision
    func complete(lease: BranchRequestLease, replay: ReplayableBranchResponse?) async
    func shouldCommit(lease: BranchRequestLease) async -> Bool
}

struct ReplayableBranchResponse: Sendable, Equatable {
    let statusCode: Int
    let headers: [(String, String)]
    let bodyChunks: [Data]

    static func == (lhs: ReplayableBranchResponse, rhs: ReplayableBranchResponse) -> Bool {
        lhs.statusCode == rhs.statusCode
        && lhs.headers.elementsEqual(rhs.headers, by: { $0.0 == $1.0 && $0.1 == $1.1 })
        && lhs.bodyChunks == rhs.bodyChunks
    }
}

struct BranchRequestLease: Sendable, Equatable {
    let id: UUID
    let clientName: String
    let vendorKey: String
    let lineageKey: String
    let branchKey: String
    let portableMessageHashes: [String]
    let generation: Int
}

enum BranchRequestAcquireDecision: Sendable, Equatable {
    case acquired(BranchRequestLease)
    case replay(ReplayableBranchResponse, source: BranchRequestLease)
    case waited(on: BranchRequestLease)
}

private enum JoinedBranchRequestOutcome: Sendable, Equatable {
    case replay(ReplayableBranchResponse)
    case retry
}

actor BranchRequestCoordinator: BranchRequestCoordinating {
    private struct InFlightEntry {
        let lease: BranchRequestLease
        let scopeKey: String
        var joinWaiters: [CheckedContinuation<JoinedBranchRequestOutcome, Never>]
        var releaseWaiters: [CheckedContinuation<Void, Never>]
    }

    private var entries: [UUID: InFlightEntry] = [:]
    private var latestGenerationByScope: [String: Int] = [:]

    func acquire(context: PreparedBranchContext) async -> BranchRequestAcquireDecision {
        if let exactEntry = exactEntry(for: context) {
            let outcome = await withCheckedContinuation { continuation in
                entries[exactEntry.lease.id]?.joinWaiters.append(continuation)
            }
            switch outcome {
            case .replay(let response):
                return .replay(response, source: exactEntry.lease)
            case .retry:
                return .waited(on: exactEntry.lease)
            }
        }

        if let blockingEntry = blockingEntry(for: context) {
            await withCheckedContinuation { continuation in
                entries[blockingEntry.lease.id]?.releaseWaiters.append(continuation)
            }
            return .waited(on: blockingEntry.lease)
        }

        let scopeKey = scopeKey(
            clientName: context.clientName,
            vendorKey: context.vendorKey,
            branchKey: context.branchKey
        )
        let generation = (latestGenerationByScope[scopeKey] ?? 0) + 1
        latestGenerationByScope[scopeKey] = generation

        let lease = BranchRequestLease(
            id: UUID(),
            clientName: context.clientName,
            vendorKey: context.vendorKey,
            lineageKey: context.lineageKey,
            branchKey: context.branchKey,
            portableMessageHashes: context.preparedPortableMessageHashes,
            generation: generation
        )
        entries[lease.id] = InFlightEntry(
            lease: lease,
            scopeKey: scopeKey,
            joinWaiters: [],
            releaseWaiters: []
        )
        return .acquired(lease)
    }

    func complete(lease: BranchRequestLease, replay: ReplayableBranchResponse?) async {
        guard let entry = entries.removeValue(forKey: lease.id) else { return }

        let joinOutcome = replay.map(JoinedBranchRequestOutcome.replay) ?? .retry
        for waiter in entry.joinWaiters {
            waiter.resume(returning: joinOutcome)
        }
        for waiter in entry.releaseWaiters {
            waiter.resume()
        }
    }

    func shouldCommit(lease: BranchRequestLease) async -> Bool {
        latestGenerationByScope[scopeKey(for: lease)] == lease.generation
    }

    private func exactEntry(for context: PreparedBranchContext) -> InFlightEntry? {
        entries.values.first { entry in
            entry.lease.clientName == context.clientName
            && entry.lease.vendorKey == context.vendorKey
            && entry.lease.portableMessageHashes == context.preparedPortableMessageHashes
        }
    }

    private func blockingEntry(for context: PreparedBranchContext) -> InFlightEntry? {
        entries.values
            .filter { entry in
                entry.lease.clientName == context.clientName
                && entry.lease.vendorKey == context.vendorKey
                && sharesBranchLineage(
                    lhs: entry.lease.portableMessageHashes,
                    rhs: context.preparedPortableMessageHashes
                )
            }
            .max { lhs, rhs in
                lhs.lease.portableMessageHashes.count < rhs.lease.portableMessageHashes.count
            }
    }

    private func sharesBranchLineage(lhs: [String], rhs: [String]) -> Bool {
        isPrefix(lhs, of: rhs) || isPrefix(rhs, of: lhs)
    }

    private func isPrefix(_ prefix: [String], of values: [String]) -> Bool {
        guard prefix.count <= values.count else { return false }
        return Array(values.prefix(prefix.count)) == prefix
    }

    private func scopeKey(for lease: BranchRequestLease) -> String {
        scopeKey(clientName: lease.clientName, vendorKey: lease.vendorKey, branchKey: lease.branchKey)
    }

    private func scopeKey(clientName: String, vendorKey: String, branchKey: String) -> String {
        "\(clientName)|\(vendorKey)|\(branchKey)"
    }
}
