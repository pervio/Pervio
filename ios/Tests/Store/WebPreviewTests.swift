import XCTest
import NIOCore
import NIOPosix
@testable import Pervio

/// The web preview (2026-11-06): which links are "a page on the Mac", what the
/// Mac reports as listening, and the tunnel itself — a loopback listener whose
/// every connection is piped to one port, here through a plain socket instead
/// of SSH so the relay logic is tested on its own.
struct TunnelTestTimeout: Error {}

final class WebPreviewTests: XCTestCase {

    func testOnlyLoopbackLinksOpenThePreview() {
        XCTAssertTrue(WebPreview.isLocal(URL(string: "http://localhost:3000/app")!))
        XCTAssertTrue(WebPreview.isLocal(URL(string: "http://127.0.0.1:8000")!))
        XCTAssertTrue(WebPreview.isLocal(URL(string: "https://localhost")!))
        XCTAssertTrue(WebPreview.isLocal(URL(string: "http://0.0.0.0:5173/")!))
        XCTAssertFalse(WebPreview.isLocal(URL(string: "https://github.com/pervio")!), "the web is Safari's")
        XCTAssertFalse(WebPreview.isLocal(URL(string: "pervio-file:///~/a.txt")!), "a Mac file link is the file preview's")
        XCTAssertFalse(WebPreview.isLocal(URL(string: "ssh://localhost")!), "only http(s)")
        XCTAssertEqual(WebPreview.port(of: URL(string: "http://localhost:3000/x")!), 3000)
        XCTAssertEqual(WebPreview.port(of: URL(string: "http://localhost/")!), 80, "the scheme's default")
        XCTAssertEqual(WebPreview.port(of: URL(string: "https://localhost/")!), 443)
        XCTAssertEqual(WebPreview.path(of: URL(string: "http://localhost:3000")!), "/")
        XCTAssertEqual(WebPreview.path(of: URL(string: "http://localhost:3000/docs?x=1")!), "/docs?x=1")
        XCTAssertEqual(WebPreview.rewrite(URL(string: "http://localhost:3000/docs?x=1")!, toLocalPort: 54321)?.absoluteString,
                       "http://127.0.0.1:54321/docs?x=1", "the page's own absolute link, re-aimed at the phone's end")
    }

    func testListeningPortsDecodeFromTheMacsRows() throws {
        let rows = try JSONDecoder().decode([ListeningPort].self, from: Data(
            #"[{"port":3000,"bind":"loopback","process":"node","pid":42,"since":1792500000},{"port":8080,"bind":"all","process":"nginx","pid":7,"since":0},{"process":"broken"}]"#.utf8))
        XCTAssertEqual(rows.map(\.port), [3000, 8080, 0], "a broken row decodes to port 0 (the service drops it) instead of failing the list")
        XCTAssertTrue(rows[0].isLoopback); XCTAssertFalse(rows[1].isLoopback)
        XCTAssertNotNil(rows[0].sinceDate); XCTAssertNil(rows[1].sinceDate, "0 = the Mac could not say")
    }

    /// A test "Mac": an echo server on the phone's loopback; the opener dials it
    /// with a plain socket, the way the app dials with a direct-tcpip channel.
    private final class SocketOpener: TunnelOpener {
        let group: EventLoopGroup; let port: Int
        var opened = 0
        init(group: EventLoopGroup, port: Int) { self.group = group; self.port = port }
        func openStream(toLoopbackPort port: Int) async throws -> Channel {
            XCTAssertEqual(port, self.port, "the tunnel asks for the port it was made for")
            opened += 1
            return try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: self.port).get()
        }
    }

    private final class Echo: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.writeAndFlush(data, promise: nil) }
    }

    /// Reads everything until the far end closes, then hands it over.
    private final class Collector: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let promise: EventLoopPromise<String>
        private var text = ""
        private var done = false
        init(promise: EventLoopPromise<String>) { self.promise = promise }
        private func finish() { if !done { done = true; promise.succeed(text) } }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var b = unwrapInboundIn(data); text += b.readString(length: b.readableBytes) ?? ""
            if text.hasSuffix("\n") { finish(); context.close(promise: nil) }
        }
        func channelInactive(context: ChannelHandlerContext) { finish(); context.fireChannelInactive() }
        func errorCaught(context: ChannelHandlerContext, error: Error) { finish(); context.close(promise: nil) }
    }

    func testBytesGoThroughTheTunnelAndBackAndStopClosesEverything() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let echo = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(Echo()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let macPort = echo.localAddress!.port!
        let opener = SocketOpener(group: group, port: macPort)
        let tunnel = SSHTunnel(opener: opener, targetPort: macPort, group: group)
        let local = try await tunnel.start()
        XCTAssertGreaterThan(local, 0, "a free port on the phone's loopback")
        XCTAssertNotEqual(local, macPort, "the Mac's port was taken here (by the test's own echo), so another was picked")

        // Two conversations through the one tunnel, each its own stream to the Mac.
        for word in ["hello tunnel\n", "second line\n"] {
            let promise = group.next().makePromise(of: String.self)
            let client = try await ClientBootstrap(group: group)
                .channelInitializer { $0.pipeline.addHandler(Collector(promise: promise)) }
                .connect(host: "127.0.0.1", port: local).get()
            var buf = client.allocator.buffer(capacity: 32); buf.writeString(word)
            try await client.writeAndFlush(buf).get()
            let timeout = group.next().scheduleTask(in: .seconds(15)) { promise.fail(TunnelTestTimeout()) }
            let back = try await promise.futureResult.get()
            timeout.cancel()
            XCTAssertEqual(back, word, "what went in came back through the Mac's echo")
        }
        XCTAssertEqual(opener.opened, 2, "one stream to the Mac per connection on the phone")

        await tunnel.stop()
        do {
            _ = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: local).get()
            XCTFail("the listener must be gone after stop")
        } catch { /* refused: nothing listens behind the person's back */ }
        try await echo.close().get()
    }

    func testTheTunnelPrefersTheMacsPortNumberWhenFree() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let echo = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(Echo()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let macPort = echo.localAddress!.port!
        // Pretend the Mac's service is on a port that IS free here.
        let probe = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let free = probe.localAddress!.port!
        try await probe.close().get()
        let tunnel = SSHTunnel(opener: SocketOpener(group: group, port: macPort), targetPort: macPort, group: group)
        let local = try await tunnel.start(preferring: free)
        XCTAssertEqual(local, free, "a page's absolute localhost:<port> links keep working when the phone has that port free")
        await tunnel.stop()
        try await echo.close().get()
    }
}
