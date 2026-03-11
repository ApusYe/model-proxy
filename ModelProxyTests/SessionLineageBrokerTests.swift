import Testing
import Foundation
import NIOCore
@testable import ModelProxy

@MainActor
struct SessionLineageBrokerTests {

    @Test func brokerStoresVendorLocalAssistantTurnForNextBranchRequest() async throws {
        let broker = SessionLineageBroker()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )

        let firstRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [["role": "user", "content": "Inspect the diff"]]
        ], options: [.sortedKeys])

        let prepared = try await broker.prepareRequest(
            bodyData: firstRequest,
            clientName: "Claude Code",
            target: target
        )
        let context = try #require(prepared.context)
        let assistantTurn = PortableAssistantTurn(
            fullMessageData: try JSONSerialization.data(withJSONObject: [
                "role": "assistant",
                "content": [
                    ["type": "thinking", "thinking": "private branch reasoning", "signature": "qwen_sig"],
                    ["type": "text", "text": "I inspected the diff"]
                ]
            ], options: [.sortedKeys]),
            portableMessageData: try JSONSerialization.data(withJSONObject: [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "I inspected the diff"]
                ]
            ], options: [.sortedKeys])
        )

        try await broker.commitResponse(context: context, assistantTurn: assistantTurn)

        let secondRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [
                ["role": "user", "content": "Inspect the diff"],
                ["role": "assistant", "content": [["type": "text", "text": "I inspected the diff"]]],
                ["role": "user", "content": "Write the commit message"]
            ]
        ], options: [.sortedKeys])

        let secondPrepared = try await broker.prepareRequest(
            bodyData: secondRequest,
            clientName: "Claude Code",
            target: target
        )

        let json = try #require(try JSONSerialization.jsonObject(with: secondPrepared.bodyData) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let restoredBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(restoredBlocks.count == 2)
        #expect(restoredBlocks.first?["signature"] as? String == "qwen_sig")
    }

    @Test func brokerScopesBranchCacheByClientName() async throws {
        let broker = SessionLineageBroker()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )

        let request = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [["role": "user", "content": "Task"]]
        ], options: [.sortedKeys])

        let prepared = try await broker.prepareRequest(bodyData: request, clientName: "Claude Code", target: target)
        let context = try #require(prepared.context)
        try await broker.commitResponse(
            context: context,
            assistantTurn: PortableAssistantTurn(
                fullMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [["type": "text", "text": "done"]]
                ], options: [.sortedKeys]),
                portableMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [["type": "text", "text": "done"]]
                ], options: [.sortedKeys])
            )
        )

        #expect(await broker.branches(for: "Claude Code").count == 1)
        #expect(await broker.branches(for: "Codex").isEmpty)
    }

    @Test func brokerReusesBranchAfterSSECommitWithoutContentBlockStop() async throws {
        let broker = SessionLineageBroker()
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer()
        let allocator = ByteBufferAllocator()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )

        let firstRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [["role": "user", "content": "Inspect the diff"]]
        ], options: [.sortedKeys])

        let prepared = try await broker.prepareRequest(
            bodyData: firstRequest,
            clientName: "Claude Code",
            target: target
        )
        let context = try #require(prepared.context)

        let events = [
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I inspected the diff\"}}\n\n"
        ]

        for event in events {
            var buffer = allocator.buffer(capacity: event.utf8.count)
            buffer.writeString(event)
            _ = try normalizer.push(chunk: buffer)
        }

        let finishedTurn = try normalizer.finish()
        let assistantTurn = try #require(finishedTurn)
        try await broker.commitResponse(context: context, assistantTurn: assistantTurn)

        let secondRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [
                ["role": "user", "content": "Inspect the diff"],
                ["role": "assistant", "content": [["type": "text", "text": "I inspected the diff"]]],
                ["role": "user", "content": "Write the commit message"]
            ]
        ], options: [.sortedKeys])

        let secondPrepared = try await broker.prepareRequest(
            bodyData: secondRequest,
            clientName: "Claude Code",
            target: target
        )

        #expect(secondPrepared.context?.reusedBranchHistory == true)
        #expect(secondPrepared.context?.reusedPortableMessageCount == 2)
    }
}
