import Foundation
import XCTest
import Crypto
import NIOSSH
@testable import Pervio

/// The hermetic SSH endpoint the track-A transport tests talk to, and the two
/// pieces of key material a man-in-the-middle test needs.
///
/// WHY A REAL SOCKET. Everything else in ios/Tests/ is a byte test or a fake
/// (`FakeSSH`), and that is right for stores. But host identity cannot be faked:
/// the thing that has to hold is that **swift-nio-ssh really refuses a server
/// whose key is not in the pin**, and the only way to know that is to hand it a
/// real handshake. So these tests use the repo's own throwaway sshd
/// (`server/tests/e2e_ios/setup.sh`) on 127.0.0.1:2222 — no model spend, no
/// screen side effects, and every file it owns lives in one sandbox directory
/// (its `~` is the sandbox's, NOT yours: ForceCommand re-exports HOME).
///
/// HOW IT IS FOUND, AND WHEN A SKIP IS HONEST.
///  * `PERVIO_E2E_CONFIG=<path>` — an explicit demand. If the file is missing or
///    the endpoint is dead, the tests FAIL. You asked for it; a silent skip
///    there would be the exact "green that means nothing" this suite exists to
///    prevent.
///  * otherwise the sandbox's own default paths are probed, and if none exists
///    the endpoint-dependent tests SKIP with the command that starts it. That
///    matches the repo's stance elsewhere ("you didn't ask for the paid layer"
///    is not a skip; "this layer can't run here" is) — and note the tests that
///    need NO endpoint (the pin-policy ones in `HostIdentityTests`, the
///    pre-socket cases in `ConnectFailureTests`) never skip at all, so a machine
///    without the sandbox still runs the security policy.
struct SandboxEndpoint {

    let configPath: String
    let host: String
    let port: Int
    let username: String
    let projectDir: String
    /// The OpenSSH host-key line the sandbox's sshd actually presents.
    let pinnedHostKey: String
    /// The sandbox's throwaway client private key (authorized by that sshd only).
    let privateKey: String
    /// Hop B — the daemon closest to the target. Its own host identity, and
    /// `PermitOpen` lets it carry a direct-tcpip channel to the main sshd and
    /// nowhere else. Nil on a sandbox from before the chain existed.
    let jump: JumpWire?
    /// Hop A — the OUTERMOST daemon, the one the phone dials directly. Its
    /// `PermitOpen` reaches the middle daemons and NOWHERE ELSE, so it
    /// physically cannot deliver the target: a two-hop route is the only way
    /// through, which is what makes "the route was really walked, in order"
    /// provable instead of assumed. Nil on a sandbox from before the route
    /// existed.
    let entry: JumpWire?
    /// Hop K — a middle daemon that authorizes ONLY `privateKey2`. It is the
    /// machine the per-hop-credential feature exists for: one credential cannot
    /// walk a route that crosses it, so a route through K connects if and only
    /// if the app really authenticated that hop with the hop's OWN key. Nil on a
    /// sandbox from before per-hop credentials existed.
    let keyed: JumpWire?
    /// The second client key — authorized by hop K and by nothing else here.
    let privateKey2: String?

    struct JumpWire: Decodable {
        let host: String
        let port: Int
        /// The OpenSSH host-key line this hop presents — deliberately a
        /// DIFFERENT key per hop, so pinning the wrong hop cannot pass.
        let pinnedHostKey: String
        /// This hop's DEBUG1 log. The chain tests grep it for the direct-tcpip
        /// open: the one artifact a connect that did NOT traverse this hop can
        /// never produce. The simulator shares the Mac's filesystem, so the test
        /// process can read it directly.
        let logFile: String
    }

    private struct Wire: Decodable {
        let host: String, port: Int, username: String
        let projectDir: String, pinnedHostKey: String, privateKey: String
        let jump: JumpWire?
        let entry: JumpWire?
        let keyed: JumpWire?
        let privateKey2: String?
    }

    /// Where `setup.sh` puts `config.json` when nobody overrides `PERVIO_E2E_ROOT`.
    private static var defaultConfigPaths: [String] {
        var paths: [String] = []
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty {
            paths.append((tmp as NSString).appendingPathComponent("pervio-e2e-ios/config.json"))
        }
        paths.append("/tmp/pervio-e2e-ios/config.json")
        return paths
    }

    static let startHint =
        "start it with:  PERVIO_E2E_ROOT=/tmp/pervio-e2e-ios bash server/tests/e2e_ios/setup.sh start"

    /// Load the endpoint, or skip — see the class doc for which is which.
    static func discover() throws -> SandboxEndpoint {
        let env = ProcessInfo.processInfo.environment
        if let demanded = env["PERVIO_E2E_CONFIG"], !demanded.isEmpty {
            guard let ep = try? load(demanded) else {
                XCTFail("PERVIO_E2E_CONFIG=\(demanded) was set but no usable sandbox config is "
                        + "there. An explicitly demanded endpoint that isn't running is a "
                        + "FAILURE, never a skip. \(startHint)")
                throw SandboxUnavailable()
            }
            return ep
        }
        for path in defaultConfigPaths {
            if let ep = try? load(path) { return ep }
        }
        throw XCTSkip("no sandbox SSH endpoint — \(startHint)  (or point PERVIO_E2E_CONFIG at "
                      + "an existing config.json). The pin-policy tests, which need no server, "
                      + "ran anyway.")
    }

    struct SandboxUnavailable: Error {}

    private static func load(_ path: String) throws -> SandboxEndpoint {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let w = try JSONDecoder().decode(Wire.self, from: data)
        guard !w.host.isEmpty, w.port > 0, !w.pinnedHostKey.isEmpty, !w.privateKey.isEmpty else {
            throw SandboxUnavailable()
        }
        return SandboxEndpoint(configPath: path, host: w.host, port: w.port,
                               username: w.username, projectDir: w.projectDir,
                               pinnedHostKey: w.pinnedHostKey, privateKey: w.privateKey,
                               jump: w.jump, entry: w.entry,
                               keyed: w.keyed, privateKey2: w.privateKey2)
    }

    /// A profile that connects to the sandbox correctly. Tests break exactly one
    /// field at a time from here, so a red always names the field it broke.
    var profile: ServerProfile {
        var p = ServerProfile()
        p.name = "E2E Sandbox"
        p.host = host
        p.port = port
        p.username = username
        p.projectDir = projectDir
        p.authKind = .privateKey
        p.pinnedHostKey = pinnedHostKey
        return p
    }

    /// `profile` routed through ONE hop (the jump sshd), both ends pinned
    /// honestly — the shape a profile saved by the old single-field editor
    /// decodes into. Honest skip on a sandbox that has no jump daemon.
    /// Same one-field-at-a-time discipline: chain tests break exactly one thing
    /// from here.
    func jumpProfile() throws -> ServerProfile {
        guard let jump else {
            throw XCTSkip("sandbox has no jump sshd — restart it: \(Self.startHint)")
        }
        var p = profile
        p.route = [hop(jump)]
        return p
    }

    /// `profile` routed through BOTH hops in order — A (entry) then B (jump) —
    /// with every pin honest. This is the real thing the route feature exists
    /// for, and the sandbox's `PermitOpen` makes it the ONLY way through: hop A
    /// cannot open a channel to the target, so nothing but a correctly ordered
    /// two-hop walk can connect.
    func routeProfile() throws -> ServerProfile {
        guard let entry, let jump else {
            throw XCTSkip("sandbox has no two-hop route (entry + jump sshd) — restart it: "
                          + "\(Self.startHint)")
        }
        var p = profile
        p.route = [hop(entry), hop(jump)]
        return p
    }

    /// `profile` routed A → K → C: hop 1 is the ordinary entry daemon (it takes
    /// the profile's own key), hop 2 is the daemon that authorizes ONLY the
    /// second key, and the target takes the profile's own key again. Hop 2 is
    /// marked as carrying its own private key; PUTTING that key where the app
    /// looks for it is deliberately left to the test, because where it is
    /// fetched from is part of what is being proven.
    ///
    /// The only difference from `routeProfile()` is which machine sits in the
    /// middle and what opens it — so a red here is about credentials, not about
    /// routing.
    func keyedRouteProfile() throws -> ServerProfile {
        guard let entry, let keyed, let key2 = privateKey2, !key2.isEmpty else {
            throw XCTSkip("sandbox has no hop that demands its own key (entry + keyed sshd + "
                          + "a second client key) — restart it: \(Self.startHint)")
        }
        var p = profile
        var own = hop(keyed)
        own.auth = .privateKey
        p.route = [hop(entry), own]
        return p
    }

    /// The key hop K authorizes, or an honest skip. Never falls back to the
    /// first key: a test that silently used the wrong credential here would be
    /// asserting the opposite of what it says.
    func secondPrivateKey() throws -> String {
        guard let key2 = privateKey2, !key2.isEmpty else {
            throw XCTSkip("sandbox carries no second client key — restart it: \(Self.startHint)")
        }
        return key2
    }

    /// One wire hop as the profile's own hop type, pinned honestly.
    func hop(_ wire: JumpWire) -> JumpHop {
        var h = JumpHop()
        h.host = wire.host
        h.port = wire.port
        h.pinnedHostKey = wire.pinnedHostKey
        return h
    }

    /// Everything hop B (the jump sshd) has logged so far — the traversal oracle.
    func jumpLog() -> String { log(jump) }

    /// Everything hop A (the entry sshd) has logged so far. A route that never
    /// touched hop A leaves this byte-identical, which is exactly how "the app
    /// walked BOTH hops" is told apart from "the app walked the last one".
    func entryLog() -> String { log(entry) }

    /// Everything hop K (the daemon that only knows the second key) has logged.
    func keyedLog() -> String { log(keyed) }

    private func log(_ wire: JumpWire?) -> String {
        guard let wire else { return "" }
        return (try? String(contentsOfFile: wire.logFile, encoding: .utf8)) ?? ""
    }

    // MARK: The man in the middle's key

    /// A syntactically valid OpenSSH ed25519 public-key line for a key **no one
    /// is serving** — freshly generated on every call.
    ///
    /// Freshly generated, not a checked-in fixture, on purpose: a hardcoded line
    /// could rot into something that no longer parses, and then "refused" would
    /// mean "we couldn't read your pin" instead of "that is not the server".
    /// Every test that uses this first asserts the line PARSES (see
    /// `assertParses`), so the refusal it then demands can only come from the
    /// key not matching.
    static func rogueHostKeyLine() -> String {
        let raw = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        func lengthPrefixed(_ bytes: [UInt8]) -> [UInt8] {
            let n = UInt32(bytes.count)
            return [UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff),
                    UInt8((n >> 8) & 0xff), UInt8(n & 0xff)] + bytes
        }
        let blob = lengthPrefixed(Array("ssh-ed25519".utf8)) + lengthPrefixed(Array(raw))
        return "ssh-ed25519 " + Data(blob).base64EncodedString()
    }

    /// Fails the test unless swift-nio-ssh can parse `line` as a public key —
    /// the guard that keeps "refused" from silently meaning "unreadable pin".
    static func assertParses(_ line: String, _ what: String,
                             file: StaticString = #filePath, line lineNo: UInt = #line) {
        XCTAssertNotNil(try? NIOSSHPublicKey(openSSHPublicKey: line),
                        "\(what) must be a parseable OpenSSH key line, otherwise a refusal "
                        + "proves nothing about host identity: \(line.prefix(40))…",
                        file: file, line: lineNo)
    }
}

// MARK: - Shared assertions

extension XCTestCase {

    /// Run `body`, require it to throw, and hand the error back.
    /// `XCTAssertThrowsError` cannot be used with `async` calls.
    @discardableResult
    func expectThrow(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                     _ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            XCTFail("\(what): expected a throw, but the call SUCCEEDED", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    /// The error must be the app's own `ConnectionError` of exactly `kind`.
    /// Anything else — a raw NIO/Citadel error, or the right words under the
    /// wrong kind — is the failure this suite exists to catch.
    @discardableResult
    func expectConnectionError(_ error: Error?, _ kind: SSHService.ConnectionError.Kind,
                               _ what: String,
                               file: StaticString = #filePath, line: UInt = #line)
        -> SSHService.ConnectionError?
    {
        guard let error else { return nil }
        guard let conn = error as? SSHService.ConnectionError else {
            XCTFail("\(what): expected SSHService.ConnectionError(kind: .\(kind.rawValue)) so the "
                    + "app can say what went wrong, but got a raw \(type(of: error)) — which "
                    + "reaches the user as the one generic \"couldn't connect\" line: "
                    + "\(String(reflecting: error))", file: file, line: line)
            return nil
        }
        XCTAssertEqual(conn.kind, kind, "\(what): wrong classification — message was "
                       + "\"\(conn.message)\"", file: file, line: line)
        XCTAssertFalse(conn.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "\(what): classified but with nothing to show the user", file: file, line: line)
        return conn
    }
}
