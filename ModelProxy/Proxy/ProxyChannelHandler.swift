import Foundation
import NIOCore
import NIOHTTP1
import AsyncHTTPClient
import NIOPosix
import OSLog

/// NIO channel handler: accumulates a full HTTP request, then dispatches async forwarding.
/// @unchecked Sendable: safe because NIO guarantees channelRead is always called on the same EventLoop thread.
final class ProxyChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: RequestRouter
    private let httpClient: HTTPClient
    private let trafficLog: TrafficLog
    private let tokenStatsStore: TokenStatsStore

    // Accumulated state for the current request.
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?

    init(router: RequestRouter, httpClient: HTTPClient, trafficLog: TrafficLog, tokenStatsStore: TokenStatsStore) {
        self.router = router
        self.httpClient = httpClient
        self.trafficLog = trafficLog
        self.tokenStatsStore = tokenStatsStore
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)

        case .body(var buf):
            bodyBuffer?.writeBuffer(&buf)

        case .end:
            guard let head = requestHead, let body = bodyBuffer else {
                // Malformed sequence: .end without prior .head/.body. Send 400 instead of hanging.
                let ch = context.channel
                Task {
                    await ProxyForwarder.sendError(channel: ch, status: .badRequest, message: "Malformed request: missing head or body")
                }
                requestHead = nil
                bodyBuffer = nil
                return
            }
            let channel = context.channel
            let router = self.router
            let httpClient = self.httpClient
            let trafficLog = self.trafficLog
            let tokenStatsStore = self.tokenStatsStore

            Task {
                await ProxyForwarder.forward(
                    head: head,
                    body: body,
                    channel: channel,
                    router: router,
                    httpClient: httpClient,
                    trafficLog: trafficLog,
                    tokenStatsStore: tokenStatsStore
                )
            }

            // Reset for the next request on this channel (keep-alive support).
            requestHead = nil
            bodyBuffer = nil
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        AppLog.proxy.error("[ProxyChannelHandler] Channel error: \(error)")
        context.close(promise: nil)
    }
}
