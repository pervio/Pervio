import Foundation
import Citadel
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// Something that can open a byte stream to a TCP port on the Mac's own
/// loopback: the SSH connection in the app (a direct-tcpip channel, the same
/// kind a jump host rides), a plain socket in the tests.
protocol TunnelOpener: AnyObject {
    /// A channel whose inbound and outbound data are `ByteBuffer`s.
    func openStream(toLoopbackPort port: Int) async throws -> Channel
}

/// The web preview's pipe (2026-11-06, the person's ask: see the Mac's dev
/// server on the phone): a listener on the PHONE's loopback whose every
/// connection is carried through `opener` to ONE port on the Mac's loopback.
/// Only 127.0.0.1 on the Mac is ever the target — the phone picks a port, not
/// a host. Lives while the preview is on screen; `stop()` closes the listener
/// and every stream through it, so nothing stays open behind the person's back.
final class SSHTunnel {
    let opener: TunnelOpener
    let targetPort: Int
    private let group: EventLoopGroup
    private var server: Channel?
    private let streams = NIOLockedValueBox<[ObjectIdentifier: Channel]>([:])
    private(set) var localPort: Int = 0

    /// One loop for every tunnel the app opens: the relay does no work of its own.
    static let sharedGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    init(opener: TunnelOpener, targetPort: Int, group: EventLoopGroup = SSHTunnel.sharedGroup) {
        self.opener = opener
        self.targetPort = targetPort
        self.group = group
    }

    /// Binds the phone's 127.0.0.1 — on `preferred` when that port is free
    /// (a page's own absolute localhost:3000 links then keep working), else on
    /// any free port. Returns the local port the page is served on.
    func start(preferring preferred: Int? = nil) async throws -> Int {
        let opener = self.opener, target = targetPort, streams = self.streams
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { local in
                // The relay goes on at once and QUEUES what the page sends until
                // the far end exists (a browser talks first); the stream to the
                // Mac is opened alongside, and once it is there the queue drains
                // into it. Nothing here depends on when NIO starts reading.
                let relay = TunnelRelay()
                let added = local.pipeline.addHandler(relay)
                Task {
                    do {
                        let remote = try await opener.openStream(toLoopbackPort: target)
                        streams.withLockedValue { $0[ObjectIdentifier(local)] = local }
                        local.closeFuture.whenComplete { _ in
                            streams.withLockedValue { _ = $0.removeValue(forKey: ObjectIdentifier(local)) }
                        }
                        try await remote.pipeline.addHandler(TunnelRelay(to: local)).get()
                        local.eventLoop.execute { relay.attach(remote) }
                    } catch {
                        local.close(promise: nil)                 // no far end: the page's connection ends
                    }
                }
                return added
            }
        var bound: Channel? = nil
        if let preferred, preferred > 0 {
            bound = try? await bootstrap.bind(host: "127.0.0.1", port: preferred).get()
        }
        let channel: Channel
        if let bound { channel = bound } else { channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get() }
        server = channel
        localPort = channel.localAddress?.port ?? 0
        return localPort
    }

    /// Closes the listener and every connection through it.
    func stop() async {
        let open = streams.withLockedValue { s -> [Channel] in let v = Array(s.values); s.removeAll(); return v }
        for ch in open { ch.close(promise: nil) }
        if let server { try? await server.close().get() }
        server = nil
        localPort = 0
    }
}

/// Copies what one side reads onto the other, and ends the partner when its
/// own side ends — one per direction, the whole relay. Made without a partner
/// it queues what it reads until `attach` names one (the page's first bytes
/// arrive before the stream to the Mac is open). Every call lands on the
/// channel's own event loop.
final class TunnelRelay: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private var partner: Channel?
    private var queued: [ByteBuffer] = []
    private var ended = false
    init(to partner: Channel? = nil) { self.partner = partner }

    func attach(_ channel: Channel) {
        partner = channel
        if ended { channel.close(promise: nil); return }
        for buf in queued { channel.writeAndFlush(buf, promise: nil) }
        queued.removeAll()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        if let partner { partner.writeAndFlush(buf, promise: nil) } else { queued.append(buf) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        ended = true
        partner?.close(promise: nil)
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ended = true
        context.close(promise: nil)
        partner?.close(promise: nil)
    }
}

extension SSHService: TunnelOpener {
    /// A direct-tcpip channel to the Mac's own loopback — the target host is
    /// fixed here, so a preview can only ever reach the Mac itself. sshd with
    /// `AllowTcpForwarding no` refuses the channel; the preview says so.
    func openStream(toLoopbackPort port: Int) async throws -> Channel {
        guard let client = self.client else { throw ConnectionError(message: "Not connected") }
        let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        return try await client.createDirectTCPIPChannel(
            using: SSHChannelType.DirectTCPIP(targetHost: "127.0.0.1", targetPort: port, originatorAddress: origin)
        ) { channel in channel.eventLoop.makeSucceededVoidFuture() }
    }
}
