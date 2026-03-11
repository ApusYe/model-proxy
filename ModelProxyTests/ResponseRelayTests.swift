import Testing
import Foundation
@testable import ModelProxy

struct ResponseRelayTests {

    @Test func replayCaptureStateDisablesCachingWhenChunksExceedLimit() {
        var capture = ResponseRelay.ReplayCaptureState(maxBytes: 8)

        #expect(capture.append(Data("1234".utf8)) == true)
        #expect(capture.totalBytes == 4)
        #expect(capture.bodyChunks.count == 1)
        #expect(capture.append(Data("56789".utf8)) == false)
        #expect(capture.isEnabled == false)
        #expect(capture.totalBytes == 0)
        #expect(capture.bodyChunks.isEmpty)
    }

    @Test func replayCaptureStateDisablesCachingWhenNormalizedBodyExceedsLimit() {
        var capture = ResponseRelay.ReplayCaptureState(maxBytes: 4)

        #expect(capture.replace(with: Data("12345".utf8)) == false)
        #expect(capture.isEnabled == false)
        #expect(capture.bodyChunks.isEmpty)
    }
}
