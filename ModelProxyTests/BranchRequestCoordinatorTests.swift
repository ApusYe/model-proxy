import Testing
import Foundation
@testable import ModelProxy

struct BranchRequestCoordinatorTests {

    @Test func exactDuplicateRequestReplaysLeaderResponse() async throws {
        let coordinator = BranchRequestCoordinator()
        let context = makeContext(hashes: ["m1", "m2"])

        let firstDecision = await coordinator.acquire(context: context)
        let leaderLease = switch firstDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected leader lease acquisition"); throw TestAbort()
        }

        let followerTask = Task {
            await coordinator.acquire(context: context)
        }
        await Task.yield()

        let replay = ReplayableBranchResponse(
            statusCode: 200,
            headers: [("content-type", "application/json")],
            bodyChunks: [Data("{\"ok\":true}".utf8)]
        )
        await coordinator.complete(lease: leaderLease, replay: replay)

        let followerDecision = await followerTask.value
        #expect(followerDecision == .replay(replay, source: leaderLease))
    }

    @Test func successorRequestWaitsThenAcquiresNewGeneration() async throws {
        let coordinator = BranchRequestCoordinator()
        let leaderContext = makeContext(hashes: ["m1", "m2"])
        let successorContext = makeContext(hashes: ["m1", "m2", "m3"])

        let leaderDecision = await coordinator.acquire(context: leaderContext)
        let leaderLease = switch leaderDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected leader lease acquisition"); throw TestAbort()
        }

        let successorTask = Task {
            await coordinator.acquire(context: successorContext)
        }
        await Task.yield()

        await coordinator.complete(lease: leaderLease, replay: nil)

        let waitedDecision = await successorTask.value
        #expect(waitedDecision == .waited(on: leaderLease))

        let successorDecision = await coordinator.acquire(context: successorContext)
        let successorLease = switch successorDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected successor acquisition after wait"); throw TestAbort()
        }
        #expect(successorLease.generation == leaderLease.generation + 1)
    }

    @Test func staleGenerationFailsCommitCheckAfterNewerAcquire() async throws {
        let coordinator = BranchRequestCoordinator()
        let context = makeContext(hashes: ["m1"])

        let firstDecision = await coordinator.acquire(context: context)
        let firstLease = switch firstDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected first lease acquisition"); throw TestAbort()
        }
        #expect(await coordinator.shouldCommit(lease: firstLease) == true)

        await coordinator.complete(lease: firstLease, replay: nil)

        let secondDecision = await coordinator.acquire(context: context)
        let secondLease = switch secondDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected second lease acquisition"); throw TestAbort()
        }

        #expect(await coordinator.shouldCommit(lease: firstLease) == false)
        #expect(await coordinator.shouldCommit(lease: secondLease) == true)
    }
}

private func makeContext(hashes: [String]) -> PreparedBranchContext {
    PreparedBranchContext(
        lineageKey: "lineage-1",
        branchKey: "branch-1",
        clientName: "Claude Code",
        vendorKey: "vendor-qwen",
        signingDomain: .compatibleThirdParty,
        replayPolicy: .portableOnly,
        preparedFullMessagesData: Data("[]".utf8),
        preparedPortableMessagesData: Data("[]".utf8),
        preparedPortableMessageHashes: hashes,
        reusedBranchHistory: false,
        reusedPortableMessageCount: 0
    )
}

private struct TestAbort: Error {}
