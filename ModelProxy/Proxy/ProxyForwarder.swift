import Foundation
import NIOCore
import NIOHTTP1
import NIOFoundationCompat
import AsyncHTTPClient
import OSLog

/// Async forwarding logic, called from a Task inside ProxyChannelHandler.
enum ProxyForwarder {

    static func forward(
        head: HTTPRequestHead,
        body: ByteBuffer,
        channel: any Channel,
        router: RequestRouter,
        httpClient: HTTPClient,
        trafficLog: TrafficLog,
        tokenStatsStore: TokenStatsStore
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
            Logger.proxy.info("[Proxy] \(head.method.rawValue, privacy: .public) \(head.uri, privacy: .public) model=\(model, privacy: .public) BLOCKED")
            let blockedEntry = TrafficEntry(model: model, routeType: .blocked, httpStatus: 403)
            await MainActor.run { trafficLog.append(blockedEntry) }
            await Self.sendError(channel: channel, status: .forbidden, message: reason)
            return
        }

        // Log request routing (no API keys or body content).
        let routeType = target.isPassthrough ? "passthrough" : "mapped → \(target.vendorName)"
        Logger.proxy.info("[Proxy] \(head.method.rawValue, privacy: .public) \(head.uri, privacy: .public) model=\(model, privacy: .public) \(routeType, privacy: .public) → \(target.baseURL, privacy: .public)")

        // 3. Build upstream URL.
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
            if lower == "host" || lower == "connection" || lower == "transfer-encoding" { continue }
            upstreamHeaders.add(name: name, value: value)
        }

        if !target.isPassthrough {
            upstreamHeaders.remove(name: "authorization")
            upstreamHeaders.remove(name: "x-api-key")
            upstreamHeaders.add(name: "Authorization", value: "Bearer \(target.apiKey)")
            upstreamHeaders.add(name: "x-api-key", value: target.apiKey)
        }

        if let host = URL(string: target.baseURL)?.host {
            upstreamHeaders.remove(name: "host")
            upstreamHeaders.add(name: "Host", value: host)
        }

        // 5. Prepare request body — modify model field if mapped.
        var bodyData = body.getData(at: body.readerIndex, length: body.readableBytes) ?? Data()

        if let targetModel = target.targetModel {
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

        let entryRouteType: TrafficEntry.RouteType = target.isPassthrough
            ? .passthrough
            : .mapped(vendorName: target.vendorName)

        let upstreamResponse: HTTPClientResponse
        do {
            upstreamResponse = try await httpClient.execute(upstreamRequest, timeout: .seconds(120))
        } catch {
            let entry = TrafficEntry(model: model, routeType: entryRouteType, httpStatus: 502)
            await MainActor.run { trafficLog.append(entry) }
            await Self.sendError(channel: channel, status: .badGateway, message: "Upstream unreachable: \(error)")
            return
        }

        // 7. Build usage callback (only for mapped/fallback routes with a known vendor UUID).
        // Stats key by target model (vendor-facing name), falling back to source model if no mapping.
        let statsModel = target.targetModel ?? model
        let onUsage: ResponseRelay.UsageCallback? = target.vendorID.map { vendorID in
            { [tokenStatsStore] input, output in
                Task { @MainActor in
                    tokenStatsStore.add(vendorID: vendorID, model: statsModel, input: input, output: output)
                }
            }
        }

        // 8. Relay response.
        await ResponseRelay.relay(
            upstreamResponse: upstreamResponse,
            to: channel,
            onUsage: onUsage
        )

        // 9. Publish traffic event with actual upstream status code.
        let statusCode = Int(upstreamResponse.status.code)
        let entry = TrafficEntry(model: model, routeType: entryRouteType, httpStatus: statusCode)
        await MainActor.run { trafficLog.append(entry) }
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
