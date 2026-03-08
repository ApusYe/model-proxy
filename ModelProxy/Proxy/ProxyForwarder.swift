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
        var routeState: RoutingSnapshot.RouteState
        do {
            (resolveResult, model, routeState) = try await router.resolve(bodyBytes: body, originalAPIKey: originalAPIKey)
        } catch {
            await Self.sendError(channel: channel, status: .badRequest, message: "Bad request: \(error)")
            return
        }

        let target: RoutingSnapshot.RouteTarget
        switch resolveResult {
        case .routed(let t):
            target = t
        case .blocked(let reason):
            AppLog.proxy.info("[Proxy] \(head.method.rawValue) \(head.uri) model=\(model) BLOCKED")
            let blockedEntry = TrafficEntry(model: model, routeType: .blocked, httpStatus: 403)
            await MainActor.run { trafficLog.append(blockedEntry) }
            await Self.sendError(channel: channel, status: .forbidden, message: reason)
            return
        }

        // Log request routing (no API keys or body content).
        let routeType = target.isPassthrough ? "passthrough" : "mapped → \(target.vendorName)"
        AppLog.proxy.info("[Proxy] \(head.method.rawValue) \(head.uri) model=\(model) \(routeType) → \(target.baseURL)")

        // 3. Preserve original body BEFORE model field replacement (needed for failover retry).
        let originalBodyData = body.getData(at: body.readerIndex, length: body.readableBytes) ?? Data()

        // 4. Build and send upstream request.
        let (upstreamResponse, usedTarget) = await Self.executeWithFailover(
            head: head,
            originalBodyData: originalBodyData,
            primaryTarget: target,
            model: model,
            router: router,
            httpClient: httpClient,
            routeState: &routeState
        )

        // 5. Write back mutated route state.
        await router.updateRouteState(model: model, state: routeState)

        guard let upstreamResponse, let usedTarget else {
            // executeWithFailover already sent error to channel on total failure.
            let duration = Date.now.timeIntervalSince(Date.now)
            let entryRouteType: TrafficEntry.RouteType = target.isPassthrough
                ? .passthrough
                : .mapped(targetModel: target.targetModel ?? model)
            let entry = TrafficEntry(model: model, routeType: entryRouteType, httpStatus: 502, duration: duration)
            await MainActor.run { trafficLog.append(entry) }
            await Self.sendError(channel: channel, status: .badGateway, message: "Upstream unreachable")
            return
        }

        // 6. Build usage callback for the vendor that actually served the request.
        let statsModel = usedTarget.targetModel ?? model
        let entryRouteType: TrafficEntry.RouteType = usedTarget.isPassthrough
            ? .passthrough
            : .mapped(targetModel: usedTarget.targetModel ?? model)

        let onUsage: ResponseRelay.UsageCallback? = usedTarget.vendorID.map { vendorID in
            { [tokenStatsStore] input, output in
                Task { @MainActor in
                    tokenStatsStore.add(vendorID: vendorID, model: statsModel, input: input, output: output)
                }
            }
        }

        // 7. Log status with readable text.
        let statusCode = Int(upstreamResponse.status.code)
        AppLog.proxy.debug("[Proxy] Response: \(statusCode) \(HTTPStatusText.text(for: statusCode)) model=\(model) vendor=\(usedTarget.vendorName)")

        // 8. Relay response.
        await ResponseRelay.relay(
            upstreamResponse: upstreamResponse,
            to: channel,
            onUsage: onUsage
        )

        // 9. Publish traffic event with actual upstream status code.
        let startTime = Date.now
        let duration = Date.now.timeIntervalSince(startTime)
        let entry = TrafficEntry(model: model, routeType: entryRouteType, httpStatus: statusCode, duration: duration)
        await MainActor.run { trafficLog.append(entry) }
    }

    // MARK: - Failover logic

    /// Execute upstream request with optional 429 failover to backup target.
    /// Returns the response and the target that was actually used, or (nil, nil) on total failure.
    private static func executeWithFailover(
        head: HTTPRequestHead,
        originalBodyData: Data,
        primaryTarget: RoutingSnapshot.RouteTarget,
        model: String,
        router: RequestRouter,
        httpClient: HTTPClient,
        routeState: inout RoutingSnapshot.RouteState
    ) async -> (HTTPClientResponse?, RoutingSnapshot.RouteTarget?) {

        // Try with primary (or current active) target.
        let primaryResponse = await Self.executeUpstream(
            head: head,
            originalBodyData: originalBodyData,
            target: primaryTarget,
            httpClient: httpClient
        )

        guard let primaryResponse else {
            // Network-level failure (unreachable).
            routeState.failCount += 1
            if routeState.failCount >= 10 {
                routeState.activeTarget = (routeState.activeTarget == .primary) ? .backup : .primary
                routeState.failCount = 0
            }
            return (nil, nil)
        }

        let statusCode = Int(primaryResponse.status.code)

        // Success: reset failCount.
        if statusCode < 400 {
            routeState.failCount = 0
            return (primaryResponse, primaryTarget)
        }

        // 429 on mapped route: try failover to backup.
        if statusCode == 429 && !primaryTarget.isPassthrough {
            routeState.failCount += 1
            if routeState.failCount >= 10 {
                routeState.activeTarget = (routeState.activeTarget == .primary) ? .backup : .primary
                routeState.failCount = 0
            }

            // Get backup targets from router.
            if let allTargets = await router.targets(for: model), allTargets.count > 1 {
                let backupTarget = (primaryTarget.vendorID == allTargets[0].vendorID) ? allTargets[1] : allTargets[0]
                AppLog.proxy.info("[Proxy] Rate limited on \(primaryTarget.vendorName), failing over to \(backupTarget.vendorName)")

                let backupResponse = await Self.executeUpstream(
                    head: head,
                    originalBodyData: originalBodyData,
                    target: backupTarget,
                    httpClient: httpClient
                )
                if let backupResponse {
                    if Int(backupResponse.status.code) < 400 {
                        routeState.failCount = 0
                    }
                    return (backupResponse, backupTarget)
                }
            }

            // No backup or backup also failed: return original 429.
            return (primaryResponse, primaryTarget)
        }

        // Non-429 error: forward as-is, increment failCount.
        if statusCode >= 400 {
            routeState.failCount += 1
            if routeState.failCount >= 10 {
                routeState.activeTarget = (routeState.activeTarget == .primary) ? .backup : .primary
                routeState.failCount = 0
            }
        }

        return (primaryResponse, primaryTarget)
    }

    /// Build and execute a single upstream request for a given target.
    private static func executeUpstream(
        head: HTTPRequestHead,
        originalBodyData: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient
    ) async -> HTTPClientResponse? {
        let finalURLString = target.baseURL.trimmingCharacters(in: .init(charactersIn: "/")) + head.uri
        guard URL(string: finalURLString) != nil else { return nil }

        // Build headers.
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

        // Replace model field using ORIGINAL body.
        var bodyData = originalBodyData
        if let targetModel = target.targetModel {
            bodyData = Self.replaceModelField(in: bodyData, with: targetModel)
        }

        var upstreamRequest = HTTPClientRequest(url: finalURLString)
        upstreamRequest.method = head.method
        upstreamRequest.headers = upstreamHeaders
        upstreamRequest.body = .bytes(bodyData)

        do {
            // Note: readTimeoutSeconds is used as the overall request deadline (connect + transfer).
            // AsyncHTTPClient doesn't support per-request connect timeout; connectTimeoutSeconds
            // is set at the HTTPClient pool level in ProxyServer.start().
            return try await httpClient.execute(upstreamRequest, timeout: .seconds(Int64(target.readTimeoutSeconds)))
        } catch {
            AppLog.proxy.error("[Proxy] Upstream error for \(target.vendorName): \(error)")
            return nil
        }
    }

    // MARK: - Helpers

    /// Replace the "model" field value in raw JSON bytes without full re-serialization.
    /// Preserves all other bytes exactly (critical for thinking block signature integrity).
    private static func replaceModelField(in data: Data, with newModel: String) -> Data {
        guard let bodyString = String(data: data, encoding: .utf8) else { return data }
        let pattern = #""model"\s*:\s*"[^"]*""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: bodyString, range: NSRange(bodyString.startIndex..., in: bodyString)),
              let range = Range(match.range, in: bodyString) else {
            return data
        }
        var result = bodyString
        result.replaceSubrange(range, with: #""model": "\#(newModel)""#)
        return Data(result.utf8)
    }

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

        _ = try? await channel.write(
            NIOAny(HTTPServerResponsePart.head(responseHead))
        ).get()
        _ = try? await channel.write(
            NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf)))
        ).get()
        _ = try? await channel.writeAndFlush(
            NIOAny(HTTPServerResponsePart.end(nil))
        ).get()
        try? await channel.close().get()
    }
}
