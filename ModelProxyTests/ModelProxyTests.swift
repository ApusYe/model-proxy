import Testing
import Foundation
import NIOCore
@testable import ModelProxy

struct ModelProxyTests {

    // MARK: - Vendor round-trip

    @Test func vendorCodableRoundTrip() throws {
        let original = Vendor(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "DashScope",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode",
            apiKey: "test-key-placeholder"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Vendor.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - ClientConfig round-trip

    @Test func clientConfigCodableRoundTrip() throws {
        let original = ClientConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            clientName: "Claude Code",
            port: 8080,
            defaultUpstream: "https://api.anthropic.com"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClientConfig.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - ClientConfig migration (old JSON without defaultUpstream)

    @Test func clientConfigDecodesLegacyJSON() throws {
        // Old format: has modelMappings, no defaultUpstream
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000003",
            "clientName": "Claude Code",
            "port": 8080,
            "modelMappings": {"claude-haiku-4-5": {"targetModel": "qwen-turbo", "targetVendorID": "00000000-0000-0000-0000-000000000002"}}
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ClientConfig.self, from: legacyJSON)
        #expect(decoded.clientName == "Claude Code")
        #expect(decoded.port == 8080)
        #expect(decoded.defaultUpstream == "") // empty = needs migration in ConfigStore
    }

    // MARK: - ModelMapping round-trip

    @Test func modelMappingCodableRoundTrip() throws {
        let vendorID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let original = ModelMapping(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            sourceModel: "claude-haiku-4-5",
            targetModel: "qwen-turbo",
            targetVendorID: vendorID
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelMapping.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - AppConfig round-trip

    @Test func appConfigCodableRoundTrip() throws {
        let config = AppConfig.makeDefault()
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.vendors.count == config.vendors.count)
        #expect(decoded.clients.count == config.clients.count)
        #expect(decoded.modelMappings.count == config.modelMappings.count)
        #expect(decoded.clients.first?.port == config.clients.first?.port)
        #expect(decoded.clients.first?.defaultUpstream == config.clients.first?.defaultUpstream)
    }

    // MARK: - AppConfig default shape

    @Test func defaultConfigHasExpectedShape() {
        let config = AppConfig.makeDefault()
        #expect(config.vendors.isEmpty)
        #expect(config.clients.count == 2)
        #expect(config.clients[0].clientName == "Claude Code")
        #expect(config.clients[0].port == 8080)
        #expect(config.clients[0].defaultUpstream == "https://api.anthropic.com")
        #expect(config.clients[1].clientName == "Codex")
        #expect(config.clients[1].port == 8081)
        #expect(config.modelMappings.isEmpty)
    }

    // MARK: - RoutingSnapshot: mapped model

    @Test func routingSnapshotResolvesMappedModel() {
        let vendor = Vendor(name: "DashScope", baseURL: "https://dashscope.aliyuncs.com/compatible-mode", apiKey: "dash-test-key")
        let mapping = ModelMapping(sourceModel: "claude-haiku-4-5", targetModel: "qwen-turbo", targetVendorID: vendor.id)
        let client = ClientConfig(clientName: "Claude Code", port: 8080, defaultUpstream: "https://api.anthropic.com")
        let config = AppConfig(vendors: [vendor], clients: [client], modelMappings: [mapping])
        let snapshot = RoutingSnapshot(from: config, for: client)

        let result = snapshot.resolve(model: "claude-haiku-4-5", originalAPIKey: "original-key")
        guard case .routed(let target) = result else {
            Issue.record("Expected .routed, got \(result)")
            return
        }
        #expect(!target.isPassthrough)
        #expect(target.baseURL == "https://dashscope.aliyuncs.com/compatible-mode")
        #expect(target.apiKey == "dash-test-key")
        #expect(target.targetModel == "qwen-turbo")
    }

    // MARK: - RoutingSnapshot: unmapped model passthrough

    @Test func routingSnapshotPassthroughUnmappedModel() {
        let client = ClientConfig(clientName: "Claude Code", port: 8080, defaultUpstream: "https://api.anthropic.com")
        let config = AppConfig(vendors: [], clients: [client], modelMappings: [])
        let snapshot = RoutingSnapshot(from: config, for: client)

        let result = snapshot.resolve(model: "claude-opus-4-6", originalAPIKey: "my-key")
        guard case .routed(let target) = result else {
            Issue.record("Expected .routed, got \(result)")
            return
        }
        #expect(target.isPassthrough)
        #expect(target.baseURL == "https://api.anthropic.com")
        #expect(target.apiKey == "my-key")
        #expect(target.targetModel == nil)
    }

    // MARK: - RoutingSnapshot: different client uses different defaultUpstream

    @Test func routingSnapshotUsesClientDefaultUpstream() {
        let codexClient = ClientConfig(clientName: "Codex", port: 8081, defaultUpstream: "https://api.openai.com")
        let config = AppConfig(vendors: [], clients: [codexClient], modelMappings: [])
        let snapshot = RoutingSnapshot(from: config, for: codexClient)

        let result = snapshot.resolve(model: "some-model", originalAPIKey: "key")
        guard case .routed(let target) = result else {
            Issue.record("Expected .routed, got \(result)")
            return
        }
        #expect(target.isPassthrough)
        #expect(target.baseURL == "https://api.openai.com")
    }

    // MARK: - UnmappedModelPolicy: block

    @Test func routingSnapshotBlocksUnmappedModel() {
        let client = ClientConfig(clientName: "Claude Code", port: 8080, defaultUpstream: "https://api.anthropic.com", unmappedPolicy: .block)
        let config = AppConfig(vendors: [], clients: [client], modelMappings: [])
        let snapshot = RoutingSnapshot(from: config, for: client)

        let result = snapshot.resolve(model: "claude-opus-4-6", originalAPIKey: "my-key")
        guard case .blocked = result else {
            Issue.record("Expected .blocked, got \(result)")
            return
        }
    }

    // MARK: - UnmappedModelPolicy: routeAll

    @Test func routingSnapshotRouteAllUnmappedModel() {
        let vendor = Vendor(name: "Fallback", baseURL: "https://fallback.example.com", apiKey: "fallback-test-key")
        let client = ClientConfig(clientName: "Claude Code", port: 8080, defaultUpstream: "https://api.anthropic.com", unmappedPolicy: .routeAll, fallbackVendorID: vendor.id)
        let config = AppConfig(vendors: [vendor], clients: [client], modelMappings: [])
        let snapshot = RoutingSnapshot(from: config, for: client)

        let result = snapshot.resolve(model: "claude-opus-4-6", originalAPIKey: "my-key")
        guard case .routed(let target) = result else {
            Issue.record("Expected .routed, got \(result)")
            return
        }
        #expect(!target.isPassthrough)
        #expect(target.baseURL == "https://fallback.example.com")
        #expect(target.apiKey == "fallback-test-key")
        #expect(target.targetModel == nil) // keeps original model name
    }

    // MARK: - Legacy JSON decodes unmappedPolicy as .passthrough

    @Test func clientConfigLegacyDefaultsToPassthrough() throws {
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000099",
            "clientName": "Test",
            "port": 9999,
            "defaultUpstream": "https://example.com"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ClientConfig.self, from: legacyJSON)
        #expect(decoded.unmappedPolicy == .passthrough)
        #expect(decoded.fallbackVendorID == nil)
    }

    // MARK: - TokenStats accumulation

    @Test func tokenStatsAccumulation() {
        var stats = TokenStats()
        let vendorID = UUID()
        stats.add(vendorID: vendorID, modelID: "claude-haiku-4-5", input: 100, output: 50)
        stats.add(vendorID: vendorID, modelID: "claude-haiku-4-5", input: 200, output: 75)
        #expect(stats.totalInputTokens() == 300)
        #expect(stats.totalOutputTokens() == 125)
    }

    // MARK: - ResponseRelay: Anthropic streaming usage extraction

    @Test func extractUsageFromAnthropicSSEStream() {
        // message_start carries input_tokens in message.usage
        let messageStart = """
        data: {"type":"message_start","message":{"usage":{"input_tokens":150,"output_tokens":0}}}

        """
        // message_delta carries output_tokens in top-level usage
        let messageDelta = """
        data: {"type":"message_delta","usage":{"output_tokens":42}}

        """
        let allocator = ByteBufferAllocator()
        var buf1 = allocator.buffer(capacity: messageStart.utf8.count)
        buf1.writeString(messageStart)
        let (input1, output1) = ResponseRelay.extractUsageFromSSEChunk(buf1)
        #expect(input1 == 150)
        #expect(output1 == 0)

        var buf2 = allocator.buffer(capacity: messageDelta.utf8.count)
        buf2.writeString(messageDelta)
        let (input2, output2) = ResponseRelay.extractUsageFromSSEChunk(buf2)
        #expect(input2 == 0)
        #expect(output2 == 42)
    }

    // MARK: - ResponseRelay: OpenAI streaming usage extraction

    @Test func extractUsageFromOpenAISSEStream() {
        let chunk = """
        data: {"choices":[],"usage":{"prompt_tokens":200,"completion_tokens":80}}

        """
        let allocator = ByteBufferAllocator()
        var buf = allocator.buffer(capacity: chunk.utf8.count)
        buf.writeString(chunk)
        let (input, output) = ResponseRelay.extractUsageFromSSEChunk(buf)
        #expect(input == 200)
        #expect(output == 80)
    }

    // MARK: - ResponseRelay: Non-streaming Anthropic JSON

    @Test func extractUsageFromAnthropicJSONBody() {
        let json = """
        {"usage":{"input_tokens":100,"cache_read_input_tokens":50,"output_tokens":30}}
        """.data(using: .utf8)!
        let result = ResponseRelay.extractUsageFromJSONBody(json)
        #expect(result != nil)
        #expect(result?.0 == 150) // input_tokens + cache_read_input_tokens
        #expect(result?.1 == 30)
    }

    // MARK: - ResponseRelay: Non-streaming OpenAI JSON

    @Test func extractUsageFromOpenAIJSONBody() {
        let json = """
        {"usage":{"prompt_tokens":300,"completion_tokens":120}}
        """.data(using: .utf8)!
        let result = ResponseRelay.extractUsageFromJSONBody(json)
        #expect(result != nil)
        #expect(result?.0 == 300)
        #expect(result?.1 == 120)
    }

    // MARK: - ResponseRelay: Missing/malformed usage

    @Test func extractUsageFromMissingUsageReturnsNil() {
        let json = """
        {"id":"msg_123","content":[]}
        """.data(using: .utf8)!
        let result = ResponseRelay.extractUsageFromJSONBody(json)
        #expect(result == nil)
    }

    @Test func extractUsageFromSSEChunkWithNoUsage() {
        let chunk = """
        data: {"type":"content_block_delta","delta":{"text":"hello"}}

        """
        let allocator = ByteBufferAllocator()
        var buf = allocator.buffer(capacity: chunk.utf8.count)
        buf.writeString(chunk)
        let (input, output) = ResponseRelay.extractUsageFromSSEChunk(buf)
        #expect(input == 0)
        #expect(output == 0)
    }

    @Test func extractUsageFromSSEDoneMarker() {
        let chunk = "data: [DONE]\n\n"
        let allocator = ByteBufferAllocator()
        var buf = allocator.buffer(capacity: chunk.utf8.count)
        buf.writeString(chunk)
        let (input, output) = ResponseRelay.extractUsageFromSSEChunk(buf)
        #expect(input == 0)
        #expect(output == 0)
    }

    // MARK: - DailyTokenSnapshot round-trip

    @Test func dailyTokenSnapshotRoundTrip() throws {
        let vendorID = UUID()
        let record = ModelTokenRecord(inputTokens: 500, outputTokens: 200)
        let snapshot = DailyTokenSnapshot(
            date: "2026-03-06",
            usageByVendorAndModel: [vendorID.uuidString: ["claude-sonnet-4-6": record]]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DailyTokenSnapshot.self, from: data)
        #expect(decoded.date == snapshot.date)
        #expect(decoded.usageByVendorAndModel[vendorID.uuidString]?["claude-sonnet-4-6"] == record)
    }
}
