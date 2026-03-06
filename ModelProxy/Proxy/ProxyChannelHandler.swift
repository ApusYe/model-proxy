import Foundation
import NIOCore
import NIOHTTP1
import AsyncHTTPClient
import NIOPosix

/// NIO channel handler: accumulates a full HTTP request, then dispatches async forwarding.
final class ProxyChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: RequestRouter
    private let httpClient: HTTPClient
    private let trafficLog: TrafficLog

    // Accumulated state for the current request.
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?

    init(router: RequestRouter, httpClient: HTTPClient, trafficLog: TrafficLog) {
        self.router = router
        self.httpClient = httpClient
        self.trafficLog = trafficLog
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
            guard let head = requestHead, let body = bodyBuffer else { return }
            let channel = context.channel
            let router = self.router
            let httpClient = self.httpClient
            let trafficLog = self.trafficLog

            // Bridge NIO to Swift async: safe because channel is Sendable via NIO's own conformance.
            Task {
                await ProxyForwarder.forward(
                    head: head,
                    body: body,
                    channel: channel,
                    router: router,
                    httpClient: httpClient,
                    trafficLog: trafficLog
                )
            }

            // Reset for the next request on this channel (keep-alive support).
            requestHead = nil
            bodyBuffer = nil
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[ProxyChannelHandler] Channel error: \(error)")
        context.close(promise: nil)
    }
}
