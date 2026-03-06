import Foundation
import NIOCore
import NIOHTTP1
import AsyncHTTPClient

enum ResponseRelay {

    /// Relay an AsyncHTTPClient response (headers + body) back to a NIO client channel.
    /// Writes each body chunk immediately as it arrives — no buffering for SSE.
    static func relay(upstreamResponse: HTTPClientResponse, to channel: any Channel) async {
        // 1. Forward status + response headers.
        var responseHead = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: Int(upstreamResponse.status.code))
        )
        for (name, value) in upstreamResponse.headers {
            let lower = name.lowercased()
            // Strip hop-by-hop headers.
            if lower == "transfer-encoding" || lower == "connection" { continue }
            responseHead.headers.add(name: name, value: value)
        }

        // Add Connection: close since we always close after this response (Phase 2 behavior).
        // This prevents clients from attempting keep-alive reuse and getting reset errors.
        responseHead.headers.add(name: "connection", value: "close")

        do {
            try await channel.writeAndFlush(
                NIOAny(HTTPServerResponsePart.head(responseHead))
            ).get()

            // 2. Stream body chunks as they arrive.
            for try await chunk in upstreamResponse.body {
                try await channel.writeAndFlush(
                    NIOAny(HTTPServerResponsePart.body(.byteBuffer(chunk)))
                ).get()
            }

            // 3. Signal end of response.
            try await channel.writeAndFlush(
                NIOAny(HTTPServerResponsePart.end(nil))
            ).get()

        } catch {
            // Channel may already be closed (client disconnected mid-stream); log and continue.
            print("[ResponseRelay] Write error (client may have disconnected): \(error)")
        }

        // Close the client connection unless keep-alive was negotiated.
        // For simplicity in Phase 2, always close after each response.
        // Phase 3+ can add keep-alive support when the UI is in place.
        try? await channel.close().get()
    }
}
