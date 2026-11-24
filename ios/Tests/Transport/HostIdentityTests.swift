import XCTest
import NIOSSH
@testable import Pervio

/// A1-A3: who are we actually talking to?
///
/// The pinned host key is the ONLY thing standing between this app and a
/// man-in-the-middle. Everything the phone sends afterwards — the private paths,
/// the prompts, and `pervio-chat`, which is remote code execution by design —
/// travels through whatever server answered. So "the pin is enforced" is not a
/// nicety; it is the security boundary of the product.
///
/// What is asserted here, and why each one is worth a socket:
///  * A1 the correct key + the correct pin really connect, and really run a
///    command (a pin so strict that nothing connects is not security);
///  * A2 a server whose key is NOT in the pin is REFUSED — with the pin proven
///    parseable first, so "refused" can only mean "that is not the server";
///  * A3 with no pin at all the connect is refused BEFORE a socket is opened
///    (there is deliberately no trust-on-first-use on this path), while
///    `probeHostKeys` — the editor's "Fetch host key" button — is the one and
///    only call that talks to an unpinned machine, it does so WITHOUT logging
///    in (HostKeyFetchTests holds that half), and the fingerprint it shows for
///    eyeballing matches what `ssh-keygen -lf` says.
@MainActor
final class HostIdentityTests: XCTestCase {

    // MARK: - A3: no pin, no connection (the policy tests — no server needed)

    /// A3. An empty pin must be refused, and refused BEFORE the socket.
    ///
    /// The port is deliberately dead (2, where nothing listens). If the pin
    /// check ever moved below `SSHClient.connect`, this test would come back
    /// with a `.portClosed` (or a raw NIO error) instead of `.noPin`, which is
    /// the whole point: the app must not dial a server it cannot identify.
    func testEmptyPinIsRefusedBeforeAnySocketIsOpened() async throws {
        var profile = ServerProfile()
        profile.host = "127.0.0.1"
        profile.port = 2
        profile.username = "nobody"
        profile.pinnedHostKey = ""

        let service = SSHService()
        let error = await expectThrow("connect with no pinned host key") {
            try await service.connect(profile: profile, secret: Self.wellFormedEd25519Key)
        }
        let conn = expectConnectionError(error, .noPin, "empty pin")
        XCTAssertEqual(conn?.kind, .noPin,
                       "an empty pin must be its own refusal, not a network error — otherwise "
                       + "the app dialled a server it could not identify")
        // The refusal has to tell the user WHY, and it follows the Settings
        // language like every other app-authored string (UIStrings.L) — so name
        // the attack in the language THIS run is in. Both phrases are written
        // out here, not read back from the code under test.
        let mitm = PromptLanguage.current == .chinese ? "中间人" : "man-in-the-middle"
        XCTAssertTrue(conn?.message.contains(mitm) == true,
                      "the refusal has to tell the user WHY, not just that it failed: "
                      + "\(conn?.message ?? "")")
        XCTAssertFalse(service.isConnected, "nothing may be left connected after a refusal")
    }

    /// A3. A pin of only whitespace/newlines is the same as no pin — a user who
    /// pasted a blank line has not pinned anything.
    func testWhitespaceOnlyPinIsRefused() async throws {
        var profile = ServerProfile()
        profile.host = "127.0.0.1"
        profile.port = 2
        profile.username = "nobody"
        profile.pinnedHostKey = "  \n\t \r\n "

        let service = SSHService()
        let error = await expectThrow("connect with a whitespace pin") {
            try await service.connect(profile: profile, secret: Self.wellFormedEd25519Key)
        }
        expectConnectionError(error, .noPin, "whitespace-only pin")
    }

    /// A3. A pin that contains something, but nothing swift-nio-ssh can parse,
    /// must be refused with its OWN message — "re-fetch the key", not
    /// "no pin" and not a network error. (DSA is the real-world case: OpenSSH
    /// still prints such lines, swift-nio-ssh cannot read them.)
    func testPinThatParsesToNothingIsRefusedWithItsOwnMessage() async throws {
        var profile = ServerProfile()
        profile.host = "127.0.0.1"
        profile.port = 2
        profile.username = "nobody"
        profile.pinnedHostKey = "ssh-dss AAAAB3NzaC1kc3M=\nnot-a-key-at-all\n"

        let service = SSHService()
        let error = await expectThrow("connect with an unparseable pin") {
            try await service.connect(profile: profile, secret: Self.wellFormedEd25519Key)
        }
        let conn = expectConnectionError(error, .unusablePin, "unparseable pin")
        XCTAssertNotEqual(conn?.kind, .noPin,
                          "\"I can't read your pin\" and \"you have no pin\" need different "
                          + "answers: only one of them is fixed by re-fetching the key")
    }

    /// A3. A pin pasted with Windows line endings must still be SEVERAL keys.
    ///
    /// In Swift a CRLF is ONE Character, so `c == "\n" || c == "\r"` is false for
    /// it and a CRLF-separated pin was never split: two host keys became one
    /// line, the line normalized to garbage, nothing parsed, and the profile
    /// refused to connect — a lockout caused entirely by which editor the user
    /// copied from. A server offers ed25519 AND rsa AND ecdsa and negotiates one,
    /// so pinning "all of them" is the normal case, and this is how a normal case
    /// dies quietly.
    func testPinSplitsOnEveryFlavourOfLineEnding() {
        let ed = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO0TgdTkvKxl0dD5Ms2tBlfEOIUuadZ8vHvcDuWkXyEu"
        let rsa = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQAB"

        XCTAssertEqual(SSHService.hostKeyLines(from: "\(ed)\r\n\(rsa)"), [ed, rsa],
                       "CRLF (a Windows paste) must separate two keys, not glue them together")
        XCTAssertEqual(SSHService.hostKeyLines(from: "\(ed)\n\(rsa)"), [ed, rsa], "LF")
        XCTAssertEqual(SSHService.hostKeyLines(from: "\(ed)\r\(rsa)"), [ed, rsa], "CR (old Mac)")
        XCTAssertEqual(SSHService.hostKeyLines(from: "\r\n\(ed)\r\n\r\n\(rsa)\r\n"), [ed, rsa],
                       "blank lines around and between the keys are not keys")
        XCTAssertEqual(SSHService.hostKeyLines(from: "\(ed) me@laptop\r\n\(rsa) me@laptop\r\n"),
                       [ed, rsa], "trailing comments are valid OpenSSH and must be dropped")
        XCTAssertEqual(SSHService.hostKeyLines(from: "   \r\n\t\n  "), [],
                       "whitespace is not a key")

        // The normalizer's own contract: whatever it is handed, what comes back
        // is a bare "type blob" pair with NO line break inside it. It is reached
        // from the probe path too, where the bytes are whatever the server's
        // `cat` produced, so it may not assume the caller already split cleanly.
        let glued = SSHService.normalizeHostKeyLine("\(ed)\r\n\(rsa)")
        XCTAssertEqual(glued, ed,
                       "a line that still has a CRLF in it must be cut at the CRLF, not carried "
                       + "through as one unparseable blob")
        XCTAssertFalse(glued.contains(where: { $0.isNewline }),
                       "a normalized host-key line may never contain a line break")
        SandboxEndpoint.assertParses(glued, "the normalized line")
    }

    /// A3. The fingerprint the user eyeballs before pinning must be the same
    /// string `ssh-keygen -lf` prints. Checked against vectors OpenSSH itself
    /// produced (not against a second copy of our own arithmetic), because a
    /// fingerprint that disagrees with ssh-keygen is worse than none: the user
    /// compares it to the server's output and would approve a mismatch.
    func testFingerprintMatchesSSHKeygen() {
        XCTAssertEqual(
            SSHService.hostKeyFingerprint(
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO0TgdTkvKxl0dD5Ms2tBlfEOIUuadZ8vHvcDuWkXyEu"),
            "SHA256:0sMfmn9c2xBny94eHIg/DWg8JjRihAr3pPjK3BUuI2o",
            "ed25519 fingerprint must match `ssh-keygen -lf`")
        XCTAssertEqual(
            SSHService.hostKeyFingerprint(
                "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOlZtEmufYAY8PiRZkHw9B/xk0kRge2AdIeqUaA/ts"
                + "CNRnTbpcKY3JoPnddAMbp+q2+tOa78yzu1WlACpRnIMGdVSLuSybv8RvxL+xAEJku28WdUoCgkoF"
                + "9zUUEKxQnZdrVtmwUVi9v6Jo7aqCdFTGFrpCENG65JOjvY0GyX2Hh8z/OFTnNc3Hejepe5WJx/eA"
                + "ICJ3NxQ/IQM0k+d7sj3P/wyG2cwaPoK3ReQFwWjb0bhl0mOZVgEkY0YXHK8gNU5+jS3CgQmZlcUs"
                + "wXNPrQIpXQNwxl01hNtLk/JV0Oao8igiQ0kjdmCjtQm9bIwdc3W02Vh9B5DMALch7ZJGW4tD"),
            "SHA256:dsRvLSPctrlpxMOtMkwhODGHpJnc11udVzVLFcnJxZw",
            "rsa fingerprint must match `ssh-keygen -lf`")
        // A trailing comment is valid OpenSSH and must not change the fingerprint —
        // the user pastes whatever ssh-keyscan gave them.
        XCTAssertEqual(
            SSHService.hostKeyFingerprint(
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO0TgdTkvKxl0dD5Ms2tBlfEOIUuadZ8vHvcDuWkXyEu"
                + " someone@somewhere"),
            "SHA256:0sMfmn9c2xBny94eHIg/DWg8JjRihAr3pPjK3BUuI2o")
        XCTAssertNil(SSHService.hostKeyFingerprint("ssh-ed25519"),
                     "a line with no key blob has no fingerprint to show")
    }

    // MARK: - A1: the happy path

    /// A1. The correct client key and the correct pin connect to the real sshd
    /// and run a real command.
    ///
    /// The command carries a nonce the test made up and computes something the
    /// remote shell has to actually evaluate, so a green cannot come from an
    /// echoed prompt, a cached buffer, or an empty string.
    func testCorrectKeyAndPinnedHostKeyConnectAndRunACommand() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let service = SSHService()
        try await service.connect(profile: endpoint.profile, secret: endpoint.privateKey)
        defer { Task { await service.disconnect() } }

        XCTAssertTrue(service.isConnected)
        let nonce = "A1-\(UUID().uuidString.prefix(8))"
        let out = try await service.runCommand("echo \(nonce)-$((6*7))")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "\(nonce)-42",
                       "the command must have run ON THE SERVER and come back whole")
    }

    // MARK: - A2: a key that is not the pinned one is refused (the MITM case)

    /// A2. THE security assertion. The sandbox sshd is exactly where it was and
    /// answers exactly as before; only the pin says a different key. That is
    /// byte-for-byte what a client sees when someone else answers on the
    /// server's address — and it must be refused.
    ///
    /// Three things keep this from being a hollow green:
    ///  * the rogue line is asserted PARSEABLE first, so the refusal is a key
    ///    mismatch and not "we couldn't read your pin";
    ///  * the same test proves the SAME service object connects with the honest
    ///    pin, so the refusal isn't the endpoint being down;
    ///  * `isConnected` must be false afterwards — a rejected handshake may not
    ///    leave a usable channel behind.
    func testServerKeyOutsideThePinIsRefused() async throws {
        let endpoint = try SandboxEndpoint.discover()

        let rogue = SandboxEndpoint.rogueHostKeyLine()
        SandboxEndpoint.assertParses(rogue, "the rogue host key")
        XCTAssertNotEqual(SSHService.normalizeHostKeyLine(rogue),
                          SSHService.normalizeHostKeyLine(endpoint.pinnedHostKey),
                          "the rogue key must actually differ from the server's")

        var mitm = endpoint.profile
        mitm.pinnedHostKey = rogue
        let service = SSHService()
        let error = await expectThrow("connect to a server whose key is not pinned") {
            try await service.connect(profile: mitm, secret: endpoint.privateKey)
        }
        expectConnectionError(error, .hostKeyMismatch, "host key outside the pin")
        XCTAssertFalse(service.isConnected,
                       "a refused handshake must not leave a live connection behind")
        await expectThrow("running a command after a refused handshake") {
            _ = try await service.runCommand("echo LEAKED")
        }

        // Control: the very same endpoint accepts the honest pin, so the refusal
        // above was about identity and not about the server being unreachable.
        let honest = SSHService()
        try await honest.connect(profile: endpoint.profile, secret: endpoint.privateKey)
        XCTAssertTrue(honest.isConnected)
        await honest.disconnect()
    }

    /// A2. The pin parser is deliberately tolerant — it SKIPS lines it cannot
    /// read so one stray paste doesn't disable a good key. Tolerance must never
    /// slide into acceptance: a pin made of one rogue key plus junk still has to
    /// refuse this server. (If `.trustedKeys` ever degraded to
    /// `.acceptAnything()` on a partly-bad pin, only this test would notice.)
    func testTolerantPinNeverDegradesIntoAcceptingAnyServer() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let rogue = SandboxEndpoint.rogueHostKeyLine()
        SandboxEndpoint.assertParses(rogue, "the rogue host key")

        var mitm = endpoint.profile
        mitm.pinnedHostKey = "ssh-dss AAAAB3NzaC1kc3M=\r\n\(rogue)\n### not a key ###\n"
        let service = SSHService()
        let error = await expectThrow("connect with a tolerant pin that omits the real key") {
            try await service.connect(profile: mitm, secret: endpoint.privateKey)
        }
        expectConnectionError(error, .hostKeyMismatch,
                              "rogue key + junk lines")
        XCTAssertFalse(service.isConnected)
    }

    /// A2. The mirror image, and the reason the tolerant parser exists: the real
    /// key surrounded by junk (a CRLF paste, a DSA line, a trailing comment)
    /// still connects. Without this, "refuse everything" would pass A2 and the
    /// product would be unusable.
    func testRealKeyStillConnectsWhenThePinCarriesJunkAroundIt() async throws {
        let endpoint = try SandboxEndpoint.discover()
        var profile = endpoint.profile
        profile.pinnedHostKey =
            "ssh-dss AAAAB3NzaC1kc3M=\r\n"
            + endpoint.pinnedHostKey + " pasted-with-a-comment\r\n"
            + SandboxEndpoint.rogueHostKeyLine() + "\n"

        let service = SSHService()
        try await service.connect(profile: profile, secret: endpoint.privateKey)
        XCTAssertTrue(service.isConnected)
        let out = try await service.runCommand("echo A2-TOLERANT-OK")
        XCTAssertTrue(out.contains("A2-TOLERANT-OK"))
        await service.disconnect()
    }

    /// A2. The real rotation: the runner stopped the sandbox sshd, generated a
    /// NEW host key, and started it again on the same address. `PERVIO_E2E_STALE_PIN`
    /// carries the line that server used to present. Connecting with it must be
    /// refused — this is the case that actually happens to users (a rebuilt box,
    /// or an attacker), and the one that must never silently succeed.
    ///
    /// Skipped only when the runner did not rotate anything. `layer_ios_unit` in
    /// scripts/lib/layers.sh is what rotates it (`setup.sh rotate`) and hands the
    /// pre-rotation line over as `TEST_RUNNER_PERVIO_E2E_STALE_PIN`; that layer
    /// also re-runs THIS test with the CURRENT key as the "stale" pin and
    /// requires it to go red, so the assertion below is not decoration.
    func testPinFromBeforeAHostKeyRotationIsRefused() async throws {
        let endpoint = try SandboxEndpoint.discover()
        guard let stale = ProcessInfo.processInfo.environment["PERVIO_E2E_STALE_PIN"],
              !stale.isEmpty else {
            throw XCTSkip("no PERVIO_E2E_STALE_PIN — the runner did not rotate the sandbox host "
                          + "key for this run, so there is no 'before' key to present.")
        }
        SandboxEndpoint.assertParses(stale, "the pre-rotation host key")
        XCTAssertNotEqual(SSHService.normalizeHostKeyLine(stale),
                          SSHService.normalizeHostKeyLine(endpoint.pinnedHostKey),
                          "PERVIO_E2E_STALE_PIN is the key the server presents NOW — nothing "
                          + "was rotated, so this test would prove nothing")

        var stalePinned = endpoint.profile
        stalePinned.pinnedHostKey = stale
        let service = SSHService()
        let error = await expectThrow("connect with the pin from before the rotation") {
            try await service.connect(profile: stalePinned, secret: endpoint.privateKey)
        }
        expectConnectionError(error, .hostKeyMismatch, "stale pin after host-key rotation")
        XCTAssertFalse(service.isConnected)
    }

    // MARK: - A3: the one deliberate look at an unpinned machine

    /// A3. `probeHostKeys` is the editor's "Fetch host key": it is the ONLY call
    /// that will talk to a machine with no pin, and it exists so the user can
    /// read a fingerprint and pin it on purpose. So, with the very same
    /// empty-pin profile that `connect` refuses, the probe must go through —
    /// with NO credential, because it does not log in — and whatever it hands
    /// back must be pinnable (parseable and fingerprintable) and must be a key
    /// this sshd really holds, because the next thing the user does is trust it.
    func testProbeHostKeysIsTheOnlyAcceptAnythingPath() async throws {
        let endpoint = try SandboxEndpoint.discover()
        var unpinned = endpoint.profile
        unpinned.pinnedHostKey = ""

        // Same profile, same server: connect refuses …
        let service = SSHService()
        let error = await expectThrow("connect without a pin") {
            try await service.connect(profile: unpinned, secret: endpoint.privateKey)
        }
        expectConnectionError(error, .noPin, "connect with no pin")

        // … and the explicit fetch does not — and needs nothing the person typed.
        let probe = SSHService()
        let keys = try await probe.probeHostKeys(profile: unpinned, secret: "")
        await probe.disconnect()
        XCTAssertFalse(keys.isEmpty, "a real sshd presents a key during the handshake")
        let real = Set(SSHService.hostKeyLines(from: endpoint.profile.pinnedHostKey))
        for line in keys {
            XCTAssertTrue(real.contains(line),
                          "the fetched key must be one this sshd really holds (the sandbox's "
                          + "own pin lists them) — got \(line.prefix(28))…")
            SandboxEndpoint.assertParses(line, "a key returned by probeHostKeys")
            XCTAssertNotNil(SSHService.hostKeyFingerprint(line),
                            "the user has to be shown a fingerprint for \(line.prefix(20))…")
            XCTAssertEqual(line, SSHService.normalizeHostKeyLine(line),
                           "probed keys must already be normalized 'type blob' lines — a comment "
                           + "or a stray CR in the pin is what breaks pinning later")
        }
    }

    // MARK: - Material

    /// A syntactically valid, unencrypted OpenSSH ed25519 private key that no
    /// server here authorizes. Used by the pre-socket tests so the private-key
    /// parse always succeeds and the refusal under test is the only thing that
    /// can fail. Throwaway: generated for this file, authorized nowhere.
    static let wellFormedEd25519Key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACBakF6Yccyscr6Bn8MOAWvJqJiHhWmphHXHewCxNOSHhAAAAJjiy5EH4suR
    BwAAAAtzc2gtZWQyNTUxOQAAACBakF6Yccyscr6Bn8MOAWvJqJiHhWmphHXHewCxNOSHhA
    AAAED4CvvolgCeilAgRj6rHuHk6VFoMVWbz2hc6mhBAY8bMlqQXphxzKxyvoGfww4Ba8mo
    mIeFaamEdcd7ALE05IeEAAAAE3BlcnZpby11bmF1dGhvcml6ZWQBAg==
    -----END OPENSSH PRIVATE KEY-----
    """
}
