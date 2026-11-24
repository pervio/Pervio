import XCTest
@testable import Pervio

/// A4: every way a connect can fail must land on its OWN answer.
///
/// The failure this suite exists to prevent is a specific, and until now real,
/// one: `SSHService.connect` let Citadel's and NIO's errors escape untouched,
/// and `pervioErrorText` (PervioApp.swift) turns anything that is not a
/// `ConnectionError` into ONE generic line. So "someone else is answering on
/// your server's address" (`Citadel.InvalidHostKey`), "nothing is listening"
/// (`NIOConnectionError`, ECONNREFUSED), "that hostname does not exist"
/// (`NIOConnectionError`, DNS) and "the server rejected your key"
/// (`SSHClientError.allAuthenticationOptionsFailed`) all reached the user as the
/// same sentence. Two costs, one of them severe:
///  * the ordinary ones are unfixable by the user — you cannot tell a typo in
///    the hostname from a dead port from a key you forgot to authorize;
///  * and a REJECTED MAN-IN-THE-MIDDLE looked exactly like a network hiccup, so
///    the natural reaction was to retry, and nobody ever learned that the host
///    key had changed.
///
/// Hence: each case gets a `ConnectionError` with its own `kind`, and this file
/// asserts the kinds, asserts the messages are pairwise different, and asserts
/// each message names the thing that is actually wrong.
@MainActor
final class ConnectFailureTests: XCTestCase {

    // MARK: - Cases that need no server

    /// A4. A private key the parser cannot read is the user's own fixable
    /// mistake (a passphrase, a PuTTY key, a truncated paste) and must say so.
    func testUnreadablePrivateKeyIsItsOwnError() async throws {
        var profile = ServerProfile()
        profile.host = "127.0.0.1"
        profile.port = 2
        profile.username = "nobody"
        profile.pinnedHostKey = SandboxEndpoint.rogueHostKeyLine()

        let service = SSHService()
        let error = await expectThrow("connect with a key that isn't a key") {
            try await service.connect(profile: profile, secret: "-----BEGIN? no.")
        }
        let conn = expectConnectionError(error, .badPrivateKey, "unparseable private key")
        // Named in the language the app is set to (UIStrings.L drives this copy
        // too); both words are spelled out here rather than read off the code.
        let theKey = PromptLanguage.current == .chinese ? "私钥" : "key"
        XCTAssertTrue(conn?.message.lowercased().contains(theKey) == true,
                      "the message must name the private key as the problem: "
                      + "\(conn?.message ?? "")")
    }

    // MARK: - Cases that need the sandbox endpoint

    /// A4. Nothing listening on the port. Port 2 on the sandbox's own host, so
    /// DNS resolves and only the TCP connect fails — the two must not be
    /// confused for each other.
    func testClosedPortIsItsOwnError() async throws {
        let endpoint = try SandboxEndpoint.discover()
        var profile = endpoint.profile
        profile.port = 2

        let service = SSHService()
        let error = await expectThrow("connect to a port nothing listens on") {
            try await service.connect(profile: profile, secret: endpoint.privateKey)
        }
        let conn = expectConnectionError(error, .portClosed, "closed port")
        XCTAssertTrue(conn?.message.contains("2") == true,
                      "the message must name the port the user has to fix: \(conn?.message ?? "")")
        XCTAssertFalse(service.isConnected)
    }

    /// A4. A hostname that does not resolve. `.invalid` is reserved by RFC 2606
    /// precisely so it can never exist, which keeps this test off the network.
    func testUnknownHostIsItsOwnError() async throws {
        let endpoint = try SandboxEndpoint.discover()
        var profile = endpoint.profile
        profile.host = "pervio-no-such-host.invalid"

        let service = SSHService()
        let error = await expectThrow("connect to a hostname that does not exist") {
            try await service.connect(profile: profile, secret: endpoint.privateKey)
        }
        let conn = expectConnectionError(error, .hostNotFound, "unknown host")
        XCTAssertTrue(conn?.message.contains("pervio-no-such-host.invalid") == true,
                      "the message must quote the address that could not be found: "
                      + "\(conn?.message ?? "")")
        XCTAssertFalse(service.isConnected)
    }

    /// A4. The server is reachable and its host key is the pinned one — it just
    /// will not accept this key. That is an authorized_keys problem on the
    /// server, and telling the user "couldn't connect" sends them to look at
    /// their network instead.
    func testRejectedCredentialsAreTheirOwnError() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let service = SSHService()
        let error = await expectThrow("connect with a key the server does not authorize") {
            try await service.connect(profile: endpoint.profile,
                                      secret: HostIdentityTests.wellFormedEd25519Key)
        }
        let conn = expectConnectionError(error, .authRejected, "unauthorized key")
        XCTAssertTrue(conn?.message.contains(endpoint.username) == true,
                      "the message must name the account that was refused: \(conn?.message ?? "")")
        XCTAssertFalse(service.isConnected)
    }

    /// A4. Same server, same authorized key, a username that does not exist.
    /// Also an authentication refusal — grouped on purpose, because from the
    /// client there is nothing to tell them apart, and inventing a distinction
    /// the wire does not carry would be a lie.
    func testUnknownAccountIsAlsoAnAuthenticationRefusal() async throws {
        let endpoint = try SandboxEndpoint.discover()
        var profile = endpoint.profile
        profile.username = "pervio-no-such-account"

        let service = SSHService()
        let error = await expectThrow("connect as an account that does not exist") {
            try await service.connect(profile: profile, secret: endpoint.privateKey)
        }
        expectConnectionError(error, .authRejected, "unknown account")
    }

    // MARK: - The whole point: they must be told apart

    /// A4. Collects the five distinguishable failures plus the host-key mismatch
    /// and asserts that no two of them read the same.
    ///
    /// This is the assertion the requirement is actually about. A per-case
    /// `kind` check can be satisfied by six different labels on six copies of
    /// the same sentence; what has to hold is that the user gets six different
    /// answers, and that none of them is the generic fallback.
    func testEveryConnectFailureReadsDifferently() async throws {
        let endpoint = try SandboxEndpoint.discover()

        var cases: [(SSHService.ConnectionError.Kind, ServerProfile, String)] = []

        var noPin = endpoint.profile;      noPin.pinnedHostKey = ""
        var badPin = endpoint.profile;     badPin.pinnedHostKey = "ssh-dss AAAAB3NzaC1kc3M="
        var mitm = endpoint.profile;       mitm.pinnedHostKey = SandboxEndpoint.rogueHostKeyLine()
        var deadPort = endpoint.profile;   deadPort.port = 2
        var noHost = endpoint.profile;     noHost.host = "pervio-no-such-host.invalid"

        cases.append((.noPin, noPin, endpoint.privateKey))
        cases.append((.unusablePin, badPin, endpoint.privateKey))
        cases.append((.hostKeyMismatch, mitm, endpoint.privateKey))
        cases.append((.portClosed, deadPort, endpoint.privateKey))
        cases.append((.hostNotFound, noHost, endpoint.privateKey))
        cases.append((.authRejected, endpoint.profile, HostIdentityTests.wellFormedEd25519Key))
        cases.append((.badPrivateKey, endpoint.profile, "nonsense"))

        var messages: [SSHService.ConnectionError.Kind: String] = [:]
        for (kind, profile, secret) in cases {
            let service = SSHService()
            let error = await expectThrow("connect (\(kind.rawValue))") {
                try await service.connect(profile: profile, secret: secret)
            }
            guard let conn = expectConnectionError(error, kind, kind.rawValue) else { continue }
            messages[kind] = conn.message
        }

        XCTAssertEqual(messages.count, cases.count,
                       "every one of these failures must produce a ConnectionError")
        XCTAssertEqual(Set(messages.values).count, messages.count,
                       "two failures share the same wording, so the user cannot tell them "
                       + "apart: \(messages)")
        for (kind, message) in messages {
            XCTAssertGreaterThan(message.count, 20,
                                 ".\(kind.rawValue) must actually explain itself: \"\(message)\"")
        }
    }
}
