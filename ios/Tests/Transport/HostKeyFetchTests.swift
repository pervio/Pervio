import XCTest
import NIOCore
import NIOPosix
import NIOSSH
import Crypto
@testable import Pervio

/// "Fetch host key" in the add-server form exists so a person can look at a
/// fingerprint BEFORE trusting a machine. So it has to learn the key without
/// logging in: whatever answers at that address is, at that moment, a stranger,
/// and a password offered to a stranger is a password lost.
///
/// These tests stand up that stranger — an SSH server in this process that
/// accepts every login and writes down what it was offered — and ask the app to
/// fetch its key. No sandbox sshd is needed, so they never skip.
final class HostKeyFetchTests: XCTestCase {

    /// Accepts anyone, and remembers what each login attempt carried.
    private final class Impostor: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        var offers: [String] { lock.lock(); defer { lock.unlock() }; return seen }

        var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .all }

        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            let what: String
            switch request.request {
            case .password(let p): what = "password \(p.password)"
            case .publicKey: what = "public key"
            case .hostBased: what = "host based"
            case .none: what = "none"
            }
            lock.lock(); seen.append("\(request.username): \(what)"); lock.unlock()
            responsePromise.succeed(.success)
        }
    }

    private struct Server {
        let group: MultiThreadedEventLoopGroup
        let channel: Channel
        let port: Int
        let hostKey: NIOSSHPrivateKey
        let auth: Impostor

        func stop() async {
            try? await channel.close().get()
            try? await group.shutdownGracefully()
        }
    }

    private func startImpostor() async throws -> Server {
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let auth = Impostor()
        // The app advertises one MAC on purpose (see AESCTRETM.swift), as a real
        // sshd does; a stock NIOSSH server offers none of it and the handshake
        // would end in "negotiation failure" before any key is shown. Give the
        // stranger the same scheme so the two can get as far as a real pair does.
        var config = SSHServerConfiguration(hostKeys: [hostKey], userAuthDelegate: auth)
        config.transportProtectionSchemes.append(AES128CTRETM.self)
        let serverConfig = config
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.addHandler(NIOSSHHandler(
                    role: .server(serverConfig),
                    allocator: ch.allocator,
                    // Anything a logged-in client then asks for is turned down at
                    // once, so a client that DID log in fails fast instead of hanging.
                    inboundChildChannelInitializer: { child, _ in
                        child.eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
                    }))
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(channel.localAddress?.port)
        return Server(group: group, channel: channel, port: port, hostKey: hostKey, auth: auth)
    }

    private func profile(port: Int, auth: ServerProfile.AuthKind) -> ServerProfile {
        var p = ServerProfile()
        p.host = "127.0.0.1"
        p.port = port
        p.username = "someone"
        p.authKind = auth
        p.pinnedHostKey = ""
        return p
    }

    /// The whole point. A person who logs in with a password taps "Fetch host
    /// key": the server must be shown NO login at all — not the password, not
    /// even the user name — and the app must still come back with the key.
    func testPasswordNeverReachesAServerWhoseKeyIsNotTrustedYet() async throws {
        let server = try await startImpostor()
        let password = "correct-horse-not-for-strangers"

        var keys: [String]?
        var thrown: Error?
        do {
            keys = try await SSHService().probeHostKeys(
                profile: profile(port: server.port, auth: .password), secret: password)
        } catch {
            thrown = error
        }
        // Anything in flight has landed by now: the handshake is over either way.
        try await Task.sleep(nanoseconds: 400_000_000)
        let offers = server.auth.offers
        await server.stop()

        XCTAssertEqual(offers, [],
                       "the server was offered a login before its key was trusted — with a "
                       + "password profile that is the password itself, handed to whoever answered")
        XCTAssertFalse(offers.contains { $0.contains(password) }, "the password went out on the wire")
        XCTAssertEqual(keys, [String(openSSHPublicKey: server.hostKey.publicKey)],
                       "the fetch must come back with exactly the key the server presented"
                       + (thrown.map { " — it threw \($0)" } ?? ""))
    }

    /// Nothing the person typed is needed to SEE a key, so the fetch works
    /// before a credential has been entered at all — and what it returns is a
    /// line the pin can use as it is: parseable, normalized, fingerprintable.
    func testKeyIsFetchedWithNoCredentialAndIsPinnableAsIs() async throws {
        let server = try await startImpostor()
        let keys = try await SSHService().probeHostKeys(
            profile: profile(port: server.port, auth: .privateKey), secret: "")
        try await Task.sleep(nanoseconds: 400_000_000)
        let offers = server.auth.offers
        await server.stop()

        XCTAssertEqual(offers, [], "a key profile must not be offered to an unverified server either")
        let line = try XCTUnwrap(keys.first)
        XCTAssertEqual(keys.count, 1, "one handshake presents one key")
        XCTAssertEqual(try NIOSSHPublicKey(openSSHPublicKey: line), server.hostKey.publicKey,
                       "the line must parse back to the very key the server holds — that is what "
                       + "a later connect compares against")
        XCTAssertEqual(line, SSHService.normalizeHostKeyLine(line), "already a bare 'type blob' line")
        XCTAssertNotNil(SSHService.hostKeyFingerprint(line), "the person has to be shown a fingerprint")
    }

    /// A machine that is not there is an error with words, never an empty
    /// answer that reads as "this server has no key".
    func testNothingListeningIsAnErrorNotAnEmptyAnswer() async throws {
        let server = try await startImpostor()
        let port = server.port
        await server.stop()

        do {
            let keys = try await SSHService().probeHostKeys(
                profile: profile(port: port, auth: .password), secret: "whatever")
            XCTFail("expected an error, got \(keys)")
        } catch {
            // any thrown error is the right shape; the form shows its description
        }
    }
}
