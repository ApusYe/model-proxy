import Testing
import Foundation
@testable import ModelProxy

struct ResponseRelayTests {

    @Test func branchReplayRecorderDisablesCachingWhenChunksExceedLimit() {
        var recorder = BranchReplayRecorder(
            statusCode: 200,
            headers: [("content-type", "text/event-stream")],
            maxBytes: 8
        )

        let firstAttempt = recorder.append(Data("1234".utf8))
        #expect(firstAttempt.captured == true)
        #expect(recorder.totalBytes == 4)
        #expect(recorder.bodyChunks.count == 1)

        let secondAttempt = recorder.append(Data("56789".utf8))
        #expect(secondAttempt.captured == false)
        #expect(secondAttempt.disabledByLimit == true)
        #expect(recorder.isEnabled == false)
        #expect(recorder.totalBytes == 0)
        #expect(recorder.bodyChunks.isEmpty)
        #expect(recorder.replayableResponse() == nil)
    }

    @Test func branchReplayRecorderDisablesCachingWhenNormalizedBodyExceedsLimit() {
        var recorder = BranchReplayRecorder(
            statusCode: 200,
            headers: [("content-type", "application/json")],
            maxBytes: 4
        )

        let attempt = recorder.replace(with: Data("12345".utf8))
        #expect(attempt.captured == false)
        #expect(attempt.disabledByLimit == true)
        #expect(recorder.isEnabled == false)
        #expect(recorder.bodyChunks.isEmpty)
    }

    @Test func branchReplayRecorderBuildsReplayableResponseWhileEnabled() throws {
        var recorder = BranchReplayRecorder(
            statusCode: 200,
            headers: [("content-type", "application/json"), ("x-request-id", "1")],
            maxBytes: 32
        )

        let attempt = recorder.append(Data("{\"ok\":true}".utf8))
        #expect(attempt.captured == true)

        let replay = try #require(recorder.replayableResponse())
        #expect(replay.statusCode == 200)
        #expect(replay.bodyChunks == [Data("{\"ok\":true}".utf8)])
        #expect(replay.headers.contains { $0.0 == "content-type" && $0.1 == "application/json" })
    }
}
