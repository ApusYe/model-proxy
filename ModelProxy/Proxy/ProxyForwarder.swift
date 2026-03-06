import Foundation
import NIOCore
import NIOHTTP1
import NIOFoundationCompat
import AsyncHTTPClient

/// Async forwarding logic, called from a Task inside ProxyChannelHandler.
enum ProxyForwarder {

    static func forward(
        head: HTTPRequestHead,
        body: ByteBuffer,
        channel: any Channel,
        router: RequestRouter,
        httpClient: HTTPClient
    ) async {
        // 1. Extract original API key (support both x-api-key and Authorization: Bearer).
        let originalAPIKey = Self.extractAPIKey(from: head.headers)

        // 2. Resolve route.
        let resolveResult: RoutingSnapshot.ResolveResult
        let model: String
        do {
            (resolveResult, model) = try await router.resolve(bodyBytes: body, originalAPIKey: originalAPIKey)
        } catch {
            await Self.sendError(channel: channel, status: .badRequest, message: "Bad request: \(error)")
            return
        }

        let target: RoutingSnapshot.RouteTarget
        switch resolveResult {
        case .routed(let t):
            target = t
        case .blocked(let reason):
            print("[Proxy] \(head.method.rawValue) \(head.uri) model=\(model) BLOCKED")
            await Self.sendError(channel: channel, status: .forbidden, message: reason)
            return
        }

        // Log request routing (no API keys or body content).
        let routeType = target.isPassthrough ? "passthrough" : "mapped → \(target.vendorName)"
        print("[Proxy] \(head.method.rawValue) \(head.uri) model=\(model) \(routeType) → \(target.baseURL)")

        // 3. Build upstream URL.
        // target.baseURL is either the vendor's baseURL (mapped) or the client's defaultUpstream (passthrough).
        // head.uri is the request path from the client (e.g., "/v1/messages").
        let finalURLString = target.baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
            + head.uri

        guard let _ = URL(string: finalURLString) else {
            await Self.sendError(channel: channel, status: .badRequest, message: "Invalid upstream URL: \(finalURLString)")
            return
        }

        // 4. Build upstream request headers.
        var upstreamHeaders = HTTPHeaders()
        for (name, value) in head.headers {
            let lower = name.lowercased()
            // Strip hop-by-hop and host headers; we will set them fresh.
            if lower == "host" || lower == "connection" || lower == "transfer-encoding" { continue }
            upstreamHeaders.add(name: name, value: value)
        }

        if !target.isPassthrough {
            // Inject vendor API key for mapped requests.
            upstreamHeaders.remove(name: "authorization")
            upstreamHeaders.remove(name: "x-api-key")
            upstreamHeaders.add(name: "Authorization", value: "Bearer \(target.apiKey)")
            upstreamHeaders.add(name: "x-api-key", value: target.apiKey)
        }

        // Update Host header to match upstream destination.
        if let host = URL(string: target.baseURL)?.host {
            upstreamHeaders.remove(name: "host")
            upstreamHeaders.add(name: "Host", value: host)
        }

        // 5. Prepare request body — modify model field if mapped.
        var bodyData = body.getData(at: body.readerIndex, length: body.readableBytes) ?? Data()

        // If targetModel is set (mapped model), replace the model field in the JSON body.
        if let targetModel = target.targetModel {
            // Parse JSON, replace model field, re-encode.
            if var jsonBody = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                jsonBody["model"] = targetModel
                bodyData = (try? JSONSerialization.data(withJSONObject: jsonBody)) ?? bodyData
            }
        }

        // 6. Send upstream request via AsyncHTTPClient.
        var upstreamRequest: HTTPClientRequest
        do {
            upstreamRequest = HTTPClientRequest(url: finalURLString)
            upstreamRequest.method = head.method
            upstreamRequest.headers = upstreamHeaders
            upstreamRequest.body = .bytes(bodyData)
        }

        let upstreamResponse: HTTPClientResponse
        do {
            upstreamResponse = try await httpClient.execute(upstreamRequest, timeout: .seconds(120))
        } catch {
            await Self.sendError(channel: channel, status: .badGateway, message: "Upstream unreachable: \(error)")
            return
        }

        // 7. Relay response (delegates to ResponseRelay).
        await ResponseRelay.relay(
            upstreamResponse: upstreamResponse,
            to: channel
        )
    }

    // MARK: - Helpers

    private static func extractAPIKey(from headers: HTTPHeaders) -> String {
        if let bearer = headers.first(name: "authorization") {
            return bearer.hasPrefix("Bearer ") ? String(bearer.dropFirst(7)) : bearer
        }
        return headers.first(name: "x-api-key") ?? ""
    }

    static func sendError(channel: any Channel, status: HTTPResponseStatus, message: String) async {
        let bodyData = Data(message.utf8)
        var responseHead = HTTPResponseHead(version: .http1_1, status: status)
        responseHead.headers.add(name: "Content-Type", value: "text/plain")
        responseHead.headers.add(name: "Content-Length", value: "\(bodyData.count)")
        responseHead.headers.add(name: "Connection", value: "close")

        var buf = channel.allocator.buffer(capacity: bodyData.count)
        buf.writeBytes(bodyData)

        _ = try? await channel.writeAndFlush(
            NIOAny(HTTPServerResponsePart.head(responseHead))
        ).get()
        _ = try? await channel.writeAndFlush(
            NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf)))
        ).get()
        _ = try? await channel.writeAndFlush(
            NIOAny(HTTPServerResponsePart.end(nil))
        ).get()
        try? await channel.close().get()
    }
}
