import Testing
import Foundation
import NIOCore
@testable import ModelProxy

struct BranchMergeReducerTests {

    @Test func reducerRemovesThinkingAndSignatureFromPortableTurn() throws {
        let reducer = BranchMergeReducer()
        let turn = try reducer.reduceAssistantMessage([
            "role": "assistant",
            "content": [
                ["type": "thinking", "thinking": "private", "signature": "sig_1"],
                ["type": "tool_use", "id": "tool_1", "name": "git_status", "input": [:]],
                ["type": "text", "text": "Done"]
            ]
        ])

        let portable = try #require(try JSONSerialization.jsonObject(with: turn.portableMessageData) as? [String: Any])
        let blocks = try #require(portable["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks.contains { $0["type"] as? String == "tool_use" })
        #expect(blocks.contains { $0["type"] as? String == "text" })
        #expect(!blocks.contains { $0["type"] as? String == "thinking" })
    }

    @Test func jsonNormalizerStripsReplaySensitiveBlocksFromResponse() throws {
        let normalizer = PortableContentNormalizer()
        let response = try JSONSerialization.data(withJSONObject: [
            "id": "msg_1",
            "role": "assistant",
            "content": [
                ["type": "thinking", "thinking": "secret", "signature": "sig_qwen"],
                ["type": "text", "text": "Commit created"]
            ]
        ], options: [.sortedKeys])

        let normalized = try normalizer.normalizeJSONBody(response)
        let json = try #require(try JSONSerialization.jsonObject(with: normalized.bodyData) as? [String: Any])
        let blocks = try #require(json["content"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks.first?["text"] as? String == "Commit created")
        #expect(normalized.assistantTurn != nil)
    }

    @Test func sseNormalizerSuppressesThinkingEventsButKeepsFullTurnInternally() throws {
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer()
        let allocator = ByteBufferAllocator()

        let events = [
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"sig_qwen\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"secret\"}}\n\n",
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Visible output\"}}\n\n",
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n"
        ]

        var output = Data()
        for event in events {
            var buffer = allocator.buffer(capacity: event.utf8.count)
            buffer.writeString(event)
            let normalizedEvents = try normalizer.push(chunk: buffer)
            normalizedEvents.forEach { output.append($0) }
        }

        let text = String(data: output, encoding: .utf8) ?? ""
        #expect(!text.contains("\"thinking\""))
        #expect(text.contains("Visible output"))

        let finishedTurn = try normalizer.finish()
        let assistantTurn = try #require(finishedTurn)
        let fullJSONObject = try JSONSerialization.jsonObject(with: assistantTurn.fullMessageData)
        let full = try #require(fullJSONObject as? [String: Any])
        let fullBlocks = try #require(full["content"] as? [[String: Any]])
        #expect(fullBlocks.count == 2)
        #expect(fullBlocks.first?["type"] as? String == "thinking")
    }

    @Test func sseNormalizerFinalizesActiveBlocksWhenStreamEndsWithoutBlockStop() throws {
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer()
        let allocator = ByteBufferAllocator()

        let events = [
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Committed successfully\"}}\n\n"
        ]

        for event in events {
            var buffer = allocator.buffer(capacity: event.utf8.count)
            buffer.writeString(event)
            _ = try normalizer.push(chunk: buffer)
        }

        let completedTurn = try normalizer.finish()
        let finishedTurn = try #require(completedTurn)
        let portableJSONObject = try JSONSerialization.jsonObject(with: finishedTurn.portableMessageData)
        let portable = try #require(portableJSONObject as? [String: Any])
        let blocks = try #require(portable["content"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks.first?["text"] as? String == "Committed successfully")
    }
}
