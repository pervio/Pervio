import XCTest
@testable import Pervio

/// A5: the route — "the phone can reach A; A can reach B; B can reach the box
/// behind it".
///
/// A profile whose `route` is non-empty must connect ProxyJump-style, hop by hop
/// IN ORDER: dial hop 1, tunnel to hop 2 through a direct-tcpip channel of hop 1,
/// … , and finally run the FULL last handshake to the target through the last
/// hop. Three things have to hold, and each gets its own oracle:
///
///  * THE BYTES REALLY GO THROUGH EVERY HOP. On this rig all three sshds sit on
///    loopback, so an implementation that ignored the route and dialed the
///    target directly would connect, run commands, and glow green. Two artifacts
///    make that impossible to fake: each hop's sshd log must GAIN a direct-tcpip
///    open across the connect (the one thing a skipped hop can never produce),
///    and the sandbox's `PermitOpen` lets hop A reach ONLY hop B — so a route
///    walked out of order, or short-circuited, cannot connect at all. Both are
///    proven independently by `setup.sh verify-chain`, which greps the same two
///    logs after a stock `ssh -J A,B` run.
///  * EVERY HOP IS STILL PINNED. Lengthening the route must never loosen the
///    security boundary: each hop's key is validated on the handshake that
///    reaches it, and the target's on the final tunneled one. A wrong pin on ANY
///    hop must refuse; an absent pin must refuse BEFORE anything is dialed.
///  * THE REFUSAL SAYS WHICH HOP. "Host key mismatch" on a three-machine route
///    is not actionable — the user has to know whether to go look at A, at B, or
///    at the target, and the three have different remedies. So the message must
///    name the hop by NUMBER and address, in the user's language.
@MainActor
final class JumpChainTests: XCTestCase {

    private let langKey = "pervio.promptLanguage"
    private var savedLang: Any?

    override func setUp() {
        super.setUp()
        savedLang = UserDefaults.standard.object(forKey: langKey)
        UserDefaults.standard.removeObject(forKey: langKey)   // shipped default: Chinese
    }
    override func tearDown() {
        if let savedLang { UserDefaults.standard.set(savedLang, forKey: langKey) }
        else { UserDefaults.standard.removeObject(forKey: langKey) }
        super.tearDown()
    }

    private func occurrences(of needle: String, in hay: String) -> Int {
        hay.components(separatedBy: needle).count - 1
    }

    /// How many direct-tcpip opens each hop's log holds right now, as a pair —
    /// the traversal counter both chain oracles read.
    private func opens(_ e: SandboxEndpoint) -> (entry: Int, jump: Int) {
        (occurrences(of: "direct-tcpip", in: e.entryLog()),
         occurrences(of: "direct-tcpip", in: e.jumpLog()))
    }

    /// The same counter for hop K, the daemon that only knows the second key.
    private func keyedOpens(_ e: SandboxEndpoint) -> Int {
        occurrences(of: "direct-tcpip", in: e.keyedLog())
    }

    // MARK: - R1: the happy path, with BOTH traversals proven

    /// R1. Honest pins on hop A, hop B and the target connect, and a command
    /// evaluates on the TARGET — with each hop's traversal proven by its own
    /// sshd log, not assumed.
    func testTwoHopRouteRunsACommandOnTheTargetThroughBothHops() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let profile = try endpoint.routeProfile()
        XCTAssertEqual(profile.routeHops.count, 2, "this test is only meaningful on a 2-hop route")

        let before = opens(endpoint)
        let service = SSHService()
        try await service.connect(profile: profile, secret: endpoint.privateKey)
        XCTAssertTrue(service.isConnected)

        let nonce = "R1-\(UUID().uuidString.prefix(8))"
        let out = try await service.runCommand("echo \(nonce)-$((6*7))")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "\(nonce)-42",
                       "the command must have run ON THE TARGET and come back whole")

        let after = opens(endpoint)
        XCTAssertGreaterThan(after.entry, before.entry,
                             "hop A's sshd log gained no direct-tcpip open across this connect — "
                             + "the route skipped the first hop, which on this loopback rig is "
                             + "exactly the hollow green a broken chain produces")
        XCTAssertGreaterThan(after.jump, before.jump,
                             "hop B's sshd log gained no direct-tcpip open — the last leg to the "
                             + "target did not go through hop B")

        await service.disconnect()
        XCTAssertFalse(service.isConnected)
    }

    /// R1. The route is an ORDER, not a set. Reversed (B first, then A) the
    /// sandbox's PermitOpen makes it impossible: hop B may only open a channel
    /// to the target, so asking it for hop A must fail — and the refusal must
    /// name hop 2, the leg that could not be opened.
    func testRouteWalkedOutOfOrderCannotConnect() async throws {
        let endpoint = try SandboxEndpoint.discover()
        var reversed = try endpoint.routeProfile()
        reversed.route.reverse()

        let service = SSHService()
        let error = await expectThrow("a route whose hops are in the wrong order") {
            try await service.connect(profile: reversed, secret: endpoint.privateKey)
        }
        let conn = error as? SSHService.ConnectionError
        XCTAssertNotNil(conn, "an unopenable leg must still arrive as the app's own error, not a "
                        + "raw NIO/Citadel type: \(String(reflecting: error))")
        let hop2 = try XCTUnwrap(reversed.routeHops.last)
        XCTAssertTrue(conn?.message.contains(L.connErrRouteHopPrefix(2, hop2.endpoint)) == true,
                      "the failure must name the hop that could not be reached (hop 2, "
                      + "\(hop2.endpoint)): \(conn?.message ?? "")")
        XCTAssertFalse(service.isConnected)
    }

    // MARK: - R2: the MIDDLE hop's key changed (the whole point of numbering)

    /// R2. THE route security assertion. Hop A is pinned honestly, and hop B is
    /// pinned with A's REAL host key — a key that genuinely exists and is
    /// genuinely served, just not by B. That is what "someone swapped the middle
    /// box" looks like from the phone, and it must be refused.
    ///
    /// The oracles make the refusal unambiguous:
    ///  * hop A's log GAINED an open — we really got to B through A, so the
    ///    refusal is about B's identity and not about the chain being down;
    ///  * hop B's log gained NOTHING — B's handshake was rejected, so no session
    ///    was ever established on it;
    ///  * the message names hop 2 and B's address, because the user has to know
    ///    which of the three machines to go and look at.
    func testMiddleHopWithASwappedHostKeyIsRefusedAndNamesHopTwo() async throws {
        let endpoint = try SandboxEndpoint.discover()
        var swapped = try endpoint.routeProfile()
        let hopA = swapped.routeHops[0]
        let hopB = swapped.routeHops[1]
        XCTAssertNotEqual(hopA.pinnedHostKey, hopB.pinnedHostKey,
                          "the two hops must have DIFFERENT host keys, otherwise pinning the "
                          + "wrong one proves nothing")
        SandboxEndpoint.assertParses(hopA.pinnedHostKey, "hop A's real host key")
        // Hop B now pins a real, live, served key — A's. B will present its own.
        swapped.route[1].pinnedHostKey = hopA.pinnedHostKey

        let before = opens(endpoint)
        let service = SSHService()
        let error = await expectThrow("a route whose middle hop presents a different host key") {
            try await service.connect(profile: swapped, secret: endpoint.privateKey)
        }
        let conn = expectConnectionError(error, .hostKeyMismatch, "hop 2's key is not what we pinned")
        XCTAssertTrue(conn?.message.contains(L.connErrRouteHopPrefix(2, hopB.endpoint)) == true,
                      "the refusal must name HOP 2 and its address (\(hopB.endpoint)) — on a "
                      + "three-machine route \"host key mismatch\" alone does not say which box "
                      + "to go and look at: \(conn?.message ?? "")")
        XCTAssertFalse(conn?.message.contains(L.connErrRouteHopPrefix(1, hopA.endpoint)) == true,
                       "it must NOT blame hop 1, whose key was fine: \(conn?.message ?? "")")
        // The WHOLE sentence, not just its parts: the hop attribution followed by
        // the shipped man-in-the-middle warning and nothing else. Composed rather
        // than transcribed so the copy stays in one place, but pinned as an
        // equality so neither half can quietly go missing — a prefix with no
        // warning, or a warning with no hop, are both regressions a `contains`
        // would wave through.
        XCTAssertEqual(conn?.message,
                       L.connErrRouteHopPrefix(2, hopB.endpoint)
                       + L.connErrHostKeyMismatch(hopB.host, hopB.port),
                       "the refusal must read as one sentence in one language")

        let after = opens(endpoint)
        XCTAssertGreaterThan(after.entry, before.entry,
                             "hop A's log must show the tunnel that carried us to B — otherwise "
                             + "the refusal happened before the route was walked and proves "
                             + "nothing about the middle hop")
        XCTAssertEqual(after.jump, before.jump,
                       "hop B must never have been asked to open a channel: its handshake was "
                       + "refused, so nothing may have run on it")
        XCTAssertFalse(service.isConnected,
                       "a refused hop must not leave a live chain behind")
        await expectThrow("running a command after a refused middle hop") {
            _ = try await service.runCommand("echo LEAKED")
        }

        // Control: same endpoint, honest pins — so the refusal above was about
        // identity, not about the route being down.
        let honest = SSHService()
        try await honest.connect(profile: try endpoint.routeProfile(), secret: endpoint.privateKey)
        XCTAssertTrue(honest.isConnected)
        await honest.disconnect()
    }

    /// R2. Same refusal for a key NOBODY serves (freshly generated, proven
    /// parseable first) — so "refused" can only mean "that is not the machine",
    /// never "we couldn't read your pin".
    func testMiddleHopWithAnUnservedKeyIsRefusedAndNamesHopTwo() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let rogue = SandboxEndpoint.rogueHostKeyLine()
        SandboxEndpoint.assertParses(rogue, "the rogue hop-2 host key")

        var mitm = try endpoint.routeProfile()
        let hopB = mitm.routeHops[1]
        mitm.route[1].pinnedHostKey = rogue

        let service = SSHService()
        let error = await expectThrow("a route whose middle hop is pinned to an unserved key") {
            try await service.connect(profile: mitm, secret: endpoint.privateKey)
        }
        let conn = expectConnectionError(error, .hostKeyMismatch, "rogue pin on hop 2")
        XCTAssertTrue(conn?.message.contains(L.connErrRouteHopPrefix(2, hopB.endpoint)) == true,
                      "the refusal must name hop 2: \(conn?.message ?? "")")
        XCTAssertFalse(service.isConnected)
    }

    /// R2. The hop number is not an English-only detail — it is the actionable
    /// part of the sentence, so it must survive the Settings language switch.
    func testTheHopNumberIsSaidInBothLanguages() throws {
        let zh = L.connErrRouteHopPrefix(2, "b:22", .chinese)
        let en = L.connErrRouteHopPrefix(2, "b:22", .english)
        XCTAssertEqual(zh, "第 2 跳(b:22) — ")
        XCTAssertEqual(en, "Hop 2 (b:22) — ")
        XCTAssertNotEqual(zh, en, "the two languages must actually differ")

        let zhTarget = L.connErrRouteTargetPrefix("c:22", .chinese)
        let enTarget = L.connErrRouteTargetPrefix("c:22", .english)
        XCTAssertEqual(zhTarget, "终点(c:22) — ")
        XCTAssertEqual(enTarget, "Target (c:22) — ")
        XCTAssertFalse(zhTarget.contains("跳"),
                       "the final machine is the destination, not a hop — calling it '第 N 跳' "
                       + "would send the user to the wrong box: \(zhTarget)")

        // The whole sentence, not just the prefix: a Chinese-speaking user must
        // get the hop number AND the man-in-the-middle warning in one language.
        let full = L.connErrRouteHopPrefix(2, "b:22", .chinese)
                 + L.connErrHostKeyMismatch("b", 22, .chinese)
        XCTAssertTrue(full.hasPrefix("第 2 跳(b:22) — 这台服务器出示的主机密钥不是本配置里固定的那一把"),
                      "the refusal a routed user reads must name the hop and then explain, in "
                      + "one language: \(full)")
    }

    // MARK: - R2b: pinning a hop in the editor — the ceremony down a route

    /// R2b. The editor's per-row "fetch this hop's key" must reach that hop
    /// THROUGH the hops above it, each pinned and validated on the way. Accept-
    /// anything applies to exactly one machine: the row being pinned.
    func testFetchingAHopsKeyTravelsThroughTheHopsAboveIt() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let profile = try endpoint.routeProfile()
        let probe = try XCTUnwrap(profile.hopProbeProfile(at: 1),
                                  "the editor must be able to aim a probe at hop 2")
        XCTAssertEqual(probe.endpoint, profile.routeHops[1].endpoint,
                       "the probe's destination is the hop being pinned")
        XCTAssertEqual(probe.routeHops.map(\.endpoint), [profile.routeHops[0].endpoint],
                       "…reached through hop 1, which stays pinned — a machine that has not "
                       + "been identified must never be the one handing over a key to trust")

        let before = opens(endpoint)
        let keys = try await SSHService().probeHostKeys(profile: probe,
                                                        secret: endpoint.privateKey)
        XCTAssertFalse(keys.isEmpty, "the probe must come back with something to eyeball")
        for line in keys { SandboxEndpoint.assertParses(line, "a probed host-key line") }
        XCTAssertGreaterThan(opens(endpoint).entry, before.entry,
                             "hop A's log gained no direct-tcpip open — the probe went straight "
                             + "at hop 2 instead of through the route above it")
    }

    /// R2b. …and it REFUSES while a hop above it is unpinned, naming that hop.
    /// Otherwise the trust ceremony could be carried out by an unverified
    /// machine, which is exactly how a man in the middle gets himself pinned.
    func testFetchingAHopsKeyRefusesWhileAnEarlierHopIsUnpinned() async throws {
        let endpoint = try SandboxEndpoint.discover()
        var profile = try endpoint.routeProfile()
        let hopA = profile.routeHops[0]
        profile.route[0].pinnedHostKey = ""
        let probe = try XCTUnwrap(profile.hopProbeProfile(at: 1))

        let before = opens(endpoint)
        let error = await expectThrow("probing hop 2 while hop 1 is unpinned") {
            _ = try await SSHService().probeHostKeys(profile: probe,
                                                     secret: endpoint.privateKey)
        }
        let conn = expectConnectionError(error, .noPin, "probe carried by an unpinned hop")
        XCTAssertTrue(conn?.message.contains(L.connErrRouteHopPrefix(1, hopA.endpoint)) == true,
                      "the refusal must name the hop whose pin is missing: \(conn?.message ?? "")")
        XCTAssertEqual(opens(endpoint).entry, before.entry,
                       "nothing may be dialed on a route with an unidentified machine in it")
    }

    // MARK: - R3: no pin anywhere on the route = no dial at all

    /// R3. An unpinned hop refuses BEFORE a socket is opened — the same
    /// no-pin-no-dial policy the direct path has always had, applied to every
    /// hop, and saying WHICH hop's pin is missing.
    func testUnpinnedMiddleHopRefusesBeforeDialingAnything() async throws {
        let endpoint = try SandboxEndpoint.discover()
        var unpinned = try endpoint.routeProfile()
        let hopB = unpinned.routeHops[1]
        unpinned.route[1].pinnedHostKey = "  \n "

        let before = opens(endpoint)
        let service = SSHService()
        let error = await expectThrow("a route with no pin for hop 2") {
            try await service.connect(profile: unpinned, secret: endpoint.privateKey)
        }
        let conn = expectConnectionError(error, .noPin, "unpinned hop 2")
        XCTAssertTrue(conn?.message.contains(L.connErrRouteHopPrefix(2, hopB.endpoint)) == true,
                      "the refusal must say it is HOP 2's pin that is missing — the other two "
                      + "machines are pinned and fine: \(conn?.message ?? "")")
        let after = opens(endpoint)
        XCTAssertEqual(after.entry, before.entry,
                       "a route with an unpinnable hop must not dial ANY of it — not even the "
                       + "hop before the bad one")
        XCTAssertEqual(after.jump, before.jump)
        XCTAssertFalse(service.isConnected)
    }

    /// R3. The FIRST hop is pinned too, and a wrong key there refuses without
    /// ever opening a tunnel anywhere.
    func testFirstHopKeyOutsideThePinIsRefusedAndNamesHopOne() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let rogue = SandboxEndpoint.rogueHostKeyLine()
        SandboxEndpoint.assertParses(rogue, "the rogue hop-1 host key")

        var mitm = try endpoint.routeProfile()
        let hopA = mitm.routeHops[0]
        mitm.route[0].pinnedHostKey = rogue

        let before = opens(endpoint)
        let service = SSHService()
        let error = await expectThrow("a route whose first hop is not the pinned machine") {
            try await service.connect(profile: mitm, secret: endpoint.privateKey)
        }
        let conn = expectConnectionError(error, .hostKeyMismatch, "hop 1 key outside the pin")
        XCTAssertTrue(conn?.message.contains(L.connErrRouteHopPrefix(1, hopA.endpoint)) == true,
                      "the refusal must name HOP 1 — hop-1 and hop-2 mismatches need different "
                      + "remedies: \(conn?.message ?? "")")
        let after = opens(endpoint)
        XCTAssertEqual(after.entry, before.entry,
                       "a hop that failed validation must never be asked to open a tunnel")
        XCTAssertEqual(after.jump, before.jump)
        XCTAssertFalse(service.isConnected)
    }

    // MARK: - R4: the TARGET is still pinned at the end of a long route

    /// R4. Honest hops, rogue TARGET pin: both tunnels open (the route did its
    /// job — both logs show it), the target answers with a key the pin does not
    /// contain, and the last tunneled handshake must refuse it exactly as a
    /// direct one would. If pinning ever applied only to the hops, whoever owns
    /// the network behind the last bastion could answer as the target.
    func testTargetKeyOutsideThePinIsRefusedAtTheEndOfTheRoute() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let rogue = SandboxEndpoint.rogueHostKeyLine()
        SandboxEndpoint.assertParses(rogue, "the rogue target host key")

        var mitm = try endpoint.routeProfile()
        mitm.pinnedHostKey = rogue

        let before = opens(endpoint)
        let service = SSHService()
        let error = await expectThrow("a route to a target whose key is not pinned") {
            try await service.connect(profile: mitm, secret: endpoint.privateKey)
        }
        let conn = expectConnectionError(error, .hostKeyMismatch, "target key outside the pin")
        XCTAssertTrue(conn?.message.contains(L.connErrRouteTargetPrefix("\(mitm.host):\(mitm.port)")) == true,
                      "the refusal must name the TARGET, so the user re-checks the right "
                      + "machine: \(conn?.message ?? "")")
        let after = opens(endpoint)
        XCTAssertGreaterThan(after.entry, before.entry,
                             "the refusal must have happened at the END of a walked route")
        XCTAssertGreaterThan(after.jump, before.jump,
                             "no direct-tcpip open on hop B means the target was dialed without "
                             + "the last hop, and this test proved nothing")
        XCTAssertFalse(service.isConnected)
    }

    // MARK: - R5: a hop that only knows ANOTHER key (per-hop credentials)
    //
    // Real paths are not uniform. A machine in the middle may accept only a
    // different key — and one credential cannot walk a route that crosses it, no
    // matter how many times you retry. The sandbox's hop K is that machine: its
    // authorized_keys holds ONLY the second client key, so A → K → C connects if
    // and only if the app authenticated hop 2 with the hop's OWN credential and
    // hops 1 and 3 with the profile's. It cannot be faked by a client that
    // "tries everything everywhere" either, because the profile's key is refused
    // by K and the second key is refused by A and C.
    //
    // `setup.sh verify-keyed` proves the rig itself the same way, with the stock
    // ssh client, before any of this means anything: K refuses key 1, accepts
    // key 2, and A → K → C runs a command on C.

    /// Point `Keychain` at an empty in-memory store for one test and put the
    /// real one back afterwards. Necessary, not merely tidy: the unit-test host
    /// is built unsigned, so every real `SecItemAdd` answers -34018 and a hop
    /// credential written to the actual keychain would silently not be there
    /// (see KeychainTests, which measured it).
    private func withFakeKeychain(_ body: (FakeKeychainStore) async throws -> Void) async rethrows {
        let real = Keychain.store
        let fake = FakeKeychainStore()
        Keychain.store = fake
        defer { Keychain.store = real }
        try await body(fake)
    }

    /// R5. THE per-hop credential assertion: hop 2 accepts ONLY its own key, the
    /// profile's credential opens hop 1 and the target, and the route connects —
    /// with both traversals proven by the hops' own logs and a command that must
    /// evaluate on the TARGET.
    ///
    /// The hop's key is put where the app reads it (the Keychain, under the
    /// profile+hop account) and nowhere else, so this exercises the whole
    /// production path — storage convention included — not a value handed
    /// straight to the transport.
    func testAHopThatOnlyKnowsItsOwnKeyIsOpenedWithTheCredentialStoredForThatHop() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let profile = try endpoint.keyedRouteProfile()
        let key2 = try endpoint.secondPrivateKey()
        XCTAssertEqual(profile.routeHops.count, 2, "this test is only meaningful on a 2-hop route")
        let hopK = profile.routeHops[1]
        XCTAssertEqual(hopK.auth, .privateKey,
                       "hop 2 must be the one carrying its own credential, or this proves nothing")
        XCTAssertNotEqual(key2, endpoint.privateKey,
                          "the hop's key and the profile's must actually DIFFER — with one key "
                          + "used twice, a connection would say nothing about which one was used")

        try await withFakeKeychain { _ in
            Keychain.set(key2, for: profile.hopSecretKey(hopK))

            let before = opens(endpoint)
            let keyedBefore = keyedOpens(endpoint)
            let service = SSHService()
            try await service.connect(profile: profile, secret: endpoint.privateKey)
            XCTAssertTrue(service.isConnected,
                          "hop 2 accepts only its own key — a route that connects here is a route "
                          + "that used the hop's credential and not the profile's")

            let nonce = "R5-\(UUID().uuidString.prefix(8))"
            let out = try await service.runCommand("echo \(nonce)-$((6*7))")
            XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "\(nonce)-42",
                           "the command must have run ON THE TARGET and come back whole")

            XCTAssertGreaterThan(opens(endpoint).entry, before.entry,
                                 "hop A's log gained no direct-tcpip open — the route skipped the "
                                 + "first hop, which on this loopback rig is exactly the hollow "
                                 + "green a broken chain produces")
            XCTAssertGreaterThan(keyedOpens(endpoint), keyedBefore,
                                 "hop K's log gained no direct-tcpip open — the last leg to the "
                                 + "target did not go through the hop with its own key")

            await service.disconnect()
            XCTAssertFalse(service.isConnected)
        }
    }

    /// R5. Take the hop's own credential away — set that hop back to the
    /// profile's credential — and the SAME route must be refused ON HOP 2, by
    /// name. This is the control that makes the test above mean something: if it
    /// connected without the per-hop key, the green up there would be free.
    ///
    /// The hop's key is deliberately left sitting in the Keychain while the hop
    /// says it uses the profile's. A "helpful" fallback that tried it anyway
    /// would connect — and would mean the setting on the screen does not decide
    /// what goes on the wire.
    func testTheSameRouteIsRefusedOnHopTwoWhenTheHopUsesTheProfilesCredential() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let key2 = try endpoint.secondPrivateKey()
        var uniform = try endpoint.keyedRouteProfile()
        uniform.route[1].auth = .profile
        let hopK = uniform.routeHops[1]

        try await withFakeKeychain { _ in
            Keychain.set(key2, for: uniform.hopSecretKey(hopK))

            let before = opens(endpoint)
            let keyedBefore = keyedOpens(endpoint)
            let service = SSHService()
            let error = await expectThrow("a route whose middle hop only knows another key, "
                                          + "walked with the profile's credential") {
                try await service.connect(profile: uniform, secret: endpoint.privateKey)
            }
            let conn = expectConnectionError(error, .authRejected,
                                             "hop 2 does not know the profile's key")
            XCTAssertEqual(conn?.message,
                           L.connErrRouteHopPrefix(2, hopK.endpoint)
                           + L.connErrAuthRejected(hopK.host, endpoint.username),
                           "the refusal must name HOP 2 and then say, in one language, that this "
                           + "machine refused these credentials — on a three-machine route "
                           + "\"authentication failed\" alone does not say which box to fix, and "
                           + "the fix here is per-hop: \(conn?.message ?? "")")
            XCTAssertFalse(conn?.message.contains(L.connErrRouteHopPrefix(1, uniform.routeHops[0].endpoint)) == true,
                           "it must NOT blame hop 1, whose credential was fine")

            XCTAssertGreaterThan(opens(endpoint).entry, before.entry,
                                 "hop A's log must show the tunnel that carried us to K — "
                                 + "otherwise the refusal happened before the route was walked "
                                 + "and says nothing about the middle hop's credential")
            XCTAssertEqual(keyedOpens(endpoint), keyedBefore,
                           "hop K must never have been asked to open a channel: it refused the "
                           + "credential, so nothing may have run on it")
            XCTAssertFalse(service.isConnected)
            await expectThrow("running a command after a refused hop credential") {
                _ = try await service.runCommand("echo LEAKED")
            }
        }
    }

    /// R5. A hop that claims its own key while the Keychain holds none refuses
    /// on THAT hop and before a socket is opened anywhere.
    ///
    /// This is not a hypothetical: profiles are ordinary JSON in UserDefaults
    /// and restore onto a new phone, while Keychain items stored
    /// `WhenUnlockedThisDeviceOnly` deliberately do not. So "the route is there,
    /// the hop's key is not" is exactly what a restored phone looks like, and it
    /// has to name the hop instead of failing somewhere down the path.
    func testAHopWhoseOwnKeyIsMissingRefusesOnThatHopWithoutDialing() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let profile = try endpoint.keyedRouteProfile()
        let hopK = profile.routeHops[1]

        try await withFakeKeychain { fake in
            let before = opens(endpoint)
            let service = SSHService()
            let error = await expectThrow("a hop that carries its own key, with none stored") {
                try await service.connect(profile: profile, secret: endpoint.privateKey)
            }
            // `.missingSecret`, not `.badPrivateKey`: since 2026-08-18 a hop whose own
            // credential is absent says so in its own words ("none is stored on this
            // phone") instead of blaming a key that was never there. This line still
            // asked for the old kind — unnoticed, because the test only runs with the
            // sandbox's keyed hop up.
            let conn = expectConnectionError(error, .missingSecret, "hop 2 has no credential")
            XCTAssertTrue(conn?.message.contains(L.connErrRouteHopPrefix(2, hopK.endpoint)) == true,
                          "the refusal must name hop 2 — the other two machines' credentials are "
                          + "right there and fine: \(conn?.message ?? "")")
            XCTAssertEqual(opens(endpoint).entry, before.entry,
                           "a route with an unusable credential must not dial ANY of it — not "
                           + "even the hop before the bad one")
            XCTAssertFalse(service.isConnected)

            // …and it looked in the ONE place the app stores such a thing. This
            // pins the account name that the editor writes and the transport
            // reads: if the two ever drift apart, every per-hop credential
            // silently becomes unreadable.
            XCTAssertTrue(fake.calls.contains("copy \(profile.hopSecretKey(hopK))"),
                          "the hop's credential must be looked up under the profile+hop account "
                          + "(\(profile.hopSecretKey(hopK))); the store saw: \(fake.calls)")
        }
    }

    // MARK: - J1-J3: one hop — the shape an old single-jump profile decodes into

    /// J1. A one-hop route still connects and still runs a command on the
    /// target, with the traversal proven. This is what every profile saved by
    /// the old single-field editor becomes, so it is a compatibility test as
    /// much as a chain test.
    func testOneHopRouteStillRunsACommandThroughTheJump() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let profile = try endpoint.jumpProfile()
        XCTAssertEqual(profile.routeHops.count, 1)

        let before = opens(endpoint)
        let service = SSHService()
        try await service.connect(profile: profile, secret: endpoint.privateKey)
        XCTAssertTrue(service.isConnected)

        let nonce = "J1-\(UUID().uuidString.prefix(8))"
        let out = try await service.runCommand("echo \(nonce)-$((6*7))")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "\(nonce)-42",
                       "the command must have run ON THE TARGET and come back whole")

        let after = opens(endpoint)
        XCTAssertGreaterThan(after.jump, before.jump,
                             "the jump sshd's log gained no direct-tcpip open across this "
                             + "connect — the bytes went STRAIGHT to the target")
        XCTAssertEqual(after.entry, before.entry,
                       "a ONE-hop route must not touch hop A at all")

        await service.disconnect()
        XCTAssertFalse(service.isConnected)
    }

    /// J2. One hop, rogue TARGET pin: refused on the tunneled handshake, and the
    /// refusal names the target.
    func testTargetKeyOutsideThePinIsRefusedThroughOneHop() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let rogue = SandboxEndpoint.rogueHostKeyLine()
        SandboxEndpoint.assertParses(rogue, "the rogue target host key")

        var mitm = try endpoint.jumpProfile()
        mitm.pinnedHostKey = rogue

        let before = opens(endpoint)
        let service = SSHService()
        let error = await expectThrow("chained connect to a target whose key is not pinned") {
            try await service.connect(profile: mitm, secret: endpoint.privateKey)
        }
        let conn = expectConnectionError(error, .hostKeyMismatch,
                                         "target key outside the pin, via jump")
        XCTAssertTrue(conn?.message.contains(":\(endpoint.port)") == true,
                      "the refusal must name the TARGET hop (port \(endpoint.port)), so the "
                      + "user re-checks the right machine: \(conn?.message ?? "")")
        XCTAssertGreaterThan(opens(endpoint).jump, before.jump,
                             "the refusal must have happened on the TUNNELED handshake — no "
                             + "direct-tcpip open means the target was dialed directly and this "
                             + "test proved nothing about the second hop")
        XCTAssertFalse(service.isConnected,
                       "a refused second-hop handshake must not leave a live chain behind")
        await expectThrow("running a command after a refused second hop") {
            _ = try await service.runCommand("echo LEAKED")
        }

        let honest = SSHService()
        try await honest.connect(profile: try endpoint.jumpProfile(),
                                 secret: endpoint.privateKey)
        XCTAssertTrue(honest.isConnected)
        await honest.disconnect()
    }

    /// J3. A rogue pin for the one hop refuses on that hop — named by number and
    /// address — and without ever opening a tunnel.
    func testJumpKeyOutsideThePinIsRefused() async throws {
        let endpoint = try SandboxEndpoint.discover()
        var mitm = try endpoint.jumpProfile()
        let hop = mitm.routeHops[0]
        let rogue = SandboxEndpoint.rogueHostKeyLine()
        SandboxEndpoint.assertParses(rogue, "the rogue jump host key")
        mitm.route[0].pinnedHostKey = rogue

        let before = opens(endpoint)
        let service = SSHService()
        let error = await expectThrow("chained connect via a jump whose key is not pinned") {
            try await service.connect(profile: mitm, secret: endpoint.privateKey)
        }
        let conn = expectConnectionError(error, .hostKeyMismatch, "jump key outside the pin")
        XCTAssertTrue(conn?.message.contains(L.connErrRouteHopPrefix(1, hop.endpoint)) == true,
                      "the refusal must name the JUMP hop (\(hop.endpoint)) — hop and target "
                      + "mismatches need different remedies: \(conn?.message ?? "")")
        XCTAssertEqual(opens(endpoint).jump, before.jump,
                       "a jump host that failed validation must never be asked to open a tunnel")
        XCTAssertFalse(service.isConnected)
    }

    /// J3. No pin for the hop = refuse BEFORE dialing anything, naming the hop.
    func testUnpinnedJumpHostRefusesToDial() async throws {
        let endpoint = try SandboxEndpoint.discover()
        var unpinned = try endpoint.jumpProfile()
        let hop = unpinned.routeHops[0]
        unpinned.route[0].pinnedHostKey = "  \n "

        let service = SSHService()
        let error = await expectThrow("chained connect with no pin for the jump host") {
            try await service.connect(profile: unpinned, secret: endpoint.privateKey)
        }
        let conn = expectConnectionError(error, .noPin, "unpinned jump host")
        XCTAssertTrue(conn?.message.contains(hop.host) == true,
                      "the refusal must say it is the JUMP host's pin that is missing — the "
                      + "target's pin is right there and fine: \(conn?.message ?? "")")
        XCTAssertFalse(service.isConnected)
    }
}
