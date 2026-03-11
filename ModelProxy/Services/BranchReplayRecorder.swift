import Foundation

struct ReplayCaptureAttempt: Sendable, Equatable {
    let captured: Bool
    let disabledByLimit: Bool
    let attemptedBytes: Int
}

struct BranchReplayRecorder: Sendable {
    private let statusCode: Int
    private let headers: [(String, String)]
    private let maxBytes: Int
    private(set) var totalBytes: Int = 0
    private(set) var bodyChunks: [Data] = []
    private(set) var isEnabled: Bool = true

    init(
        statusCode: Int,
        headers: [(String, String)],
        maxBytes: Int = ResponseRelay.maxReplayBodyBytes
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.maxBytes = maxBytes
    }

    mutating func append(_ data: Data) -> ReplayCaptureAttempt {
        guard isEnabled else {
            return ReplayCaptureAttempt(captured: false, disabledByLimit: false, attemptedBytes: data.count)
        }
        let nextBytes = totalBytes + data.count
        guard nextBytes <= maxBytes else {
            disable()
            return ReplayCaptureAttempt(captured: false, disabledByLimit: true, attemptedBytes: data.count)
        }
        totalBytes = nextBytes
        bodyChunks.append(data)
        return ReplayCaptureAttempt(captured: true, disabledByLimit: false, attemptedBytes: data.count)
    }

    mutating func replace(with data: Data) -> ReplayCaptureAttempt {
        guard isEnabled else {
            return ReplayCaptureAttempt(captured: false, disabledByLimit: false, attemptedBytes: data.count)
        }
        guard data.count <= maxBytes else {
            disable()
            return ReplayCaptureAttempt(captured: false, disabledByLimit: true, attemptedBytes: data.count)
        }
        totalBytes = data.count
        bodyChunks = [data]
        return ReplayCaptureAttempt(captured: true, disabledByLimit: false, attemptedBytes: data.count)
    }

    func replayableResponse() -> ReplayableBranchResponse? {
        guard isEnabled else { return nil }
        return ReplayableBranchResponse(
            statusCode: statusCode,
            headers: headers,
            bodyChunks: bodyChunks
        )
    }

    private mutating func disable() {
        // Once replay capture exceeds the configured limit we keep the recorder disabled for the
        // rest of the response; re-enabling mid-stream would produce a partial cached replay.
        isEnabled = false
        totalBytes = 0
        bodyChunks.removeAll(keepingCapacity: false)
    }
}
