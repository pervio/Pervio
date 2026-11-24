import XCTest
@testable import Pervio

/// A5b: the upgrade from "one jump host" to "a route" must cost nobody anything.
///
/// Profiles live in UserDefaults as JSON written by the SHIPPED build. Two kinds
/// of them exist on real phones right now, and both have to keep working with no
/// migration step, no re-pinning, and no re-typing:
///
///   1. **No jump at all** — the overwhelming majority. These must decode to an
///      EMPTY route and then take the direct connect path, byte for byte: the
///      same code, the same refusals, the same sentences. A route feature that
///      re-words the ordinary "wrong host key" message has broken the app for
///      everyone who never asked for a route. So the direct path's messages are
///      pinned here VERBATIM — if someone reworks them, this test is where they
///      find out that the change is user-visible.
///   2. **One jump host** (`jumpHost`/`jumpPort`/`jumpUsername`/
///      `jumpPinnedHostKey`) — these must decode into a one-element route with
///      exactly the same address, port, username and pin. Nothing is rewritten
///      on disk to make that happen; the decoder just reads the old shape.
///
/// The live half (a legacy profile really connecting, direct, while both hop
/// daemons stay untouched) is at the bottom and needs the sandbox; the decode
/// half needs nothing and always runs.
@MainActor
final class RouteCompatibilityTests: XCTestCase {

    private let langKey = "pervio.promptLanguage"
    private var savedLang: Any?

    override func setUp() {
        super.setUp()
        savedLang = UserDefaults.standard.object(forKey: langKey)
        // The byte-for-byte security-copy pins below are the zh variants; pin
        // the language (the shipped DEFAULT is English since 2026-09-01).
        UserDefaults.standard.set("zh", forKey: langKey)
    }
    override func tearDown() {
        if let savedLang { UserDefaults.standard.set(savedLang, forKey: langKey) }
        else { UserDefaults.standard.removeObject(forKey: langKey) }
        super.tearDown()
    }

    private func decode(_ json: String) throws -> ServerProfile {
        try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
    }

    // MARK: - Old JSON, no jump fields: an empty route and the direct path

    func testProfileSavedBeforeRoutesExistedHasAnEmptyRoute() throws {
        // Exactly the shape the shipped build writes for a plain server.
        let p = try decode("""
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"Box","host":"box.example",
         "port":22,"username":"me","projectDir":"~/app","authKind":"privateKey",
         "pinnedHostKey":"ssh-ed25519 AAAA","permissionMode":"auto","model":"opus",
         "effort":"","runMode":false,"launcherDir":"~/.pervio/bin","backend":"claude"}
        """)
        XCTAssertTrue(p.route.isEmpty, "a profile that never had a jump host must have no route")
        XCTAssertFalse(p.usesRoute, "…and must therefore take the direct connect path")
        XCTAssertEqual(p.host, "box.example")
        XCTAssertEqual(p.pinnedHostKey, "ssh-ed25519 AAAA")
        XCTAssertEqual(p.username, "me")
    }

    /// The direct path's refusals, pinned verbatim. These are what a user with
    /// no route reads today; the route work must not touch a byte of them.
    func testDirectPathRefusalsAreUnchangedByTheRouteFeature() async throws {
        var profile = ServerProfile()
        profile.host = "127.0.0.1"
        profile.port = 2                      // deliberately dead: nothing may dial
        profile.username = "nobody"
        profile.pinnedHostKey = ""
        XCTAssertTrue(profile.route.isEmpty)

        // A REAL key: `connect` parses the credential before it looks at the
        // pin, so a junk secret would answer .badPrivateKey and this test would
        // be measuring the wrong refusal entirely.
        let service = SSHService()
        let error = await expectThrow("direct connect with no pin") {
            try await service.connect(profile: profile,
                                      secret: HostIdentityTests.wellFormedEd25519Key)
        }
        let conn = expectConnectionError(error, .noPin, "direct, unpinned")
        XCTAssertEqual(conn?.message,
            "没有固定主机密钥 —— 拒绝连接(不固定就等于信任任何一台应答的服务器,"
            + "中间人可以直接接管)。把服务器的主机密钥填进这个配置:在服务器上跑  "
            + "ssh-keyscan -t ed25519 <host>  ,把 \"ssh-ed25519 AAAA…\" 那一行"
            + "粘进「Pinned host key」。",
            "the no-route refusal must be the SHIPPED sentence, byte for byte — a user "
            + "who never asked for a route must not notice this feature exists. In "
            + "particular it must carry NO hop prefix: there is no hop.")
        XCTAssertFalse(conn?.message.contains("跳") == true,
                       "a direct connection has no hops, so nothing may be numbered")

        var unusable = profile
        unusable.pinnedHostKey = "ssh-dss AAAAB3NzaC1kc3M=\nnot-a-key-at-all\n"
        let e2 = await expectThrow("direct connect with an unparseable pin") {
            try await SSHService().connect(profile: unusable,
                                           secret: HostIdentityTests.wellFormedEd25519Key)
        }
        let c2 = expectConnectionError(e2, .unusablePin, "direct, unusable pin")
        XCTAssertEqual(c2?.message,
            "固定的主机密钥里没有一行能解析(1 行被跳过)。请重新从服务器取回主机密钥,再信任一次。",
            "the unusable-pin refusal must be the SHIPPED sentence, byte for byte")
    }

    /// The host-key-mismatch sentence a direct profile gets, pinned verbatim at
    /// the classifier — the one message the user must never learn to ignore.
    func testDirectMismatchSentenceIsUnchanged() {
        var profile = ServerProfile()
        profile.host = "box.example"
        profile.port = 2022
        profile.username = "me"
        let conn = SSHService.hostKeyMismatchRefusal(profile: profile)
        XCTAssertEqual(conn.kind, .hostKeyMismatch)
        XCTAssertEqual(conn.message,
            "这台服务器出示的主机密钥不是本配置里固定的那一把 —— 连接已拒绝。"
            + "可能是服务器重装换了新主机密钥,也可能在 box.example:2022 上应答的根本是别人。"
            + "在你亲自到那台服务器上核对指纹之前,不要重新固定:"
            + "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub",
            "the direct mismatch sentence must be the SHIPPED one, byte for byte — this is "
            + "the security copy a user reads at the worst possible moment")
        XCTAssertFalse(conn.message.contains("第 1 跳"),
                       "a direct connection has no hop 1")
    }

    // MARK: - Old JSON, one jump host: a one-element route, nothing re-typed

    func testLegacySingleJumpProfileDecodesAsAOneHopRoute() throws {
        let p = try decode("""
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3302","name":"Behind","host":"inner.example",
         "port":2200,"username":"me","projectDir":"~/app","authKind":"privateKey",
         "pinnedHostKey":"ssh-ed25519 TARGETKEY","permissionMode":"auto",
         "jumpHost":"bastion.example","jumpPort":2022,"jumpUsername":"jumper",
         "jumpPinnedHostKey":"ssh-ed25519 JUMPKEY"}
        """)
        XCTAssertEqual(p.routeHops.count, 1,
                       "a saved jump host must become the first (and only) hop of a route")
        let hop = try XCTUnwrap(p.routeHops.first)
        XCTAssertEqual(hop.host, "bastion.example")
        XCTAssertEqual(hop.port, 2022)
        XCTAssertEqual(hop.username, "jumper")
        XCTAssertEqual(hop.pinnedHostKey, "ssh-ed25519 JUMPKEY")
        // The target is untouched — it was never the jump host's business.
        XCTAssertEqual(p.host, "inner.example")
        XCTAssertEqual(p.port, 2200)
        XCTAssertEqual(p.pinnedHostKey, "ssh-ed25519 TARGETKEY")
    }

    /// A hop with no username of its own borrows the target's, exactly as the
    /// single-field jump host always did.
    func testLegacyJumpWithoutItsOwnUsernameBorrowsTheTargets() throws {
        let p = try decode("""
        {"host":"inner.example","port":22,"username":"me","pinnedHostKey":"ssh-ed25519 T",
         "jumpHost":"bastion.example","jumpPort":22,"jumpUsername":"",
         "jumpPinnedHostKey":"ssh-ed25519 J"}
        """)
        let hop = try XCTUnwrap(p.routeHops.first)
        XCTAssertEqual(hop.username, "", "the stored hop keeps the blank the user left")
        XCTAssertEqual(p.hopProfile(hop).username, "me",
                       "…and the connection resolves it to the target's username")
    }

    /// A saved EMPTY jump host is not a hop. (The old editor left the field
    /// present-but-blank the moment anyone tapped into it.)
    func testLegacyBlankJumpHostIsNotAHop() throws {
        let p = try decode("""
        {"host":"box.example","port":22,"username":"me","pinnedHostKey":"ssh-ed25519 T",
         "jumpHost":"","jumpPort":22,"jumpUsername":"","jumpPinnedHostKey":""}
        """)
        XCTAssertTrue(p.route.isEmpty)
        XCTAssertFalse(p.usesRoute)
    }

    /// A profile saved by the NEW build carries `route`, and that is what wins —
    /// including an explicitly empty one, so "I deleted my route" survives a
    /// relaunch even if a stale legacy key is still in the JSON.
    func testAnExplicitRouteWinsOverLegacyFields() throws {
        let p = try decode("""
        {"host":"box.example","port":22,"username":"me","pinnedHostKey":"ssh-ed25519 T",
         "jumpHost":"stale.example","jumpPinnedHostKey":"ssh-ed25519 STALE",
         "route":[]}
        """)
        XCTAssertTrue(p.route.isEmpty,
                      "an explicit empty route means the user removed it — a leftover legacy "
                      + "key must not resurrect a hop")
    }

    func testRouteRoundTripsThroughJSON() throws {
        var p = ServerProfile()
        p.host = "c.example"; p.username = "me"; p.pinnedHostKey = "ssh-ed25519 T"
        var a = JumpHop(); a.host = "a.example"; a.port = 2201; a.pinnedHostKey = "ssh-ed25519 A"
        var b = JumpHop(); b.host = "b.example"; b.port = 2202; b.username = "other"
        b.pinnedHostKey = "ssh-ed25519 B"
        p.route = [a, b]

        let back = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.route.map(\.host), ["a.example", "b.example"],
                       "hop ORDER is the whole meaning of a route — it must survive a save")
        XCTAssertEqual(back.route.map(\.port), [2201, 2202])
        XCTAssertEqual(back.route.map(\.username), ["", "other"])
        XCTAssertEqual(back.route.map(\.pinnedHostKey), ["ssh-ed25519 A", "ssh-ed25519 B"])
        XCTAssertEqual(back.route.map(\.id), p.route.map(\.id),
                       "hop identity must be stable across a save, or the editor's rows would "
                       + "shuffle under the user's finger after a relaunch")
    }

    // MARK: - Old JSON, no per-hop credentials: nothing changes, byte for byte

    /// A hop written before per-hop credentials existed carries no `auth` key at
    /// all, and must decode to the profile's own credential — the behaviour it
    /// has always had. This is the whole compatibility story for the feature:
    /// a phone full of saved routes must not notice it shipped.
    func testHopsSavedBeforePerHopCredentialsUseTheProfilesOwn() throws {
        let p = try decode("""
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3303","host":"inner.example","port":22,
         "username":"me","authKind":"privateKey","pinnedHostKey":"ssh-ed25519 T",
         "route":[{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3311","host":"a.example","port":22,
                   "username":"","pinnedHostKey":"ssh-ed25519 A"},
                  {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3312","host":"b.example","port":2022,
                   "username":"jumper","pinnedHostKey":"ssh-ed25519 B"}]}
        """)
        XCTAssertEqual(p.route.map(\.auth), [.profile, .profile],
                       "a hop with no stored auth uses the server's own credential")
        XCTAssertFalse(p.route.contains { $0.hasOwnCredential })
        // …and that is not merely a label: the hop connects with the profile's
        // auth KIND and the profile's SECRET, with nothing looked up anywhere.
        for hop in p.routeHops {
            XCTAssertEqual(p.hopProfile(hop).authKind, .privateKey)
            XCTAssertEqual(SSHService.hopSecret(hop, of: p, profileSecret: "THE-ONE-KEY",
                                                lookup: { _ in
                XCTFail("an ordinary hop must not consult the Keychain at all")
                return "SOMETHING-ELSE"
            }), "THE-ONE-KEY")
        }
    }

    /// The same profile, but the target authenticates with a PASSWORD: its hops
    /// still follow it. `.profile` means "whatever the server uses", not
    /// "a private key".
    func testDefaultHopsFollowAPasswordProfilesAuthKind() throws {
        let p = try decode("""
        {"host":"inner.example","port":22,"username":"me","authKind":"password",
         "pinnedHostKey":"ssh-ed25519 T",
         "route":[{"host":"a.example","port":22,"username":"","pinnedHostKey":"ssh-ed25519 A"}]}
        """)
        let hop = try XCTUnwrap(p.routeHops.first)
        XCTAssertEqual(p.hopProfile(hop).authKind, .password)
    }

    /// A legacy single-jump profile's hop is an ordinary hop in this respect too.
    func testTheLegacyJumpHostUsesTheProfilesCredential() throws {
        let p = try decode("""
        {"host":"inner.example","port":2200,"username":"me","pinnedHostKey":"ssh-ed25519 T",
         "jumpHost":"bastion.example","jumpPort":2022,"jumpUsername":"jumper",
         "jumpPinnedHostKey":"ssh-ed25519 J"}
        """)
        XCTAssertEqual(try XCTUnwrap(p.routeHops.first).auth, .profile)
    }

    /// ENCODING is the other half, and the strict one: a route of ordinary hops
    /// must write the SAME FIELDS with the same values it wrote before per-hop
    /// credentials existed, and no `auth` anywhere. Otherwise every saved profile
    /// grows a key on the next save, and a downgraded build reads back JSON its
    /// own decoder never wrote.
    ///
    /// Compared as a decoded object rather than as a string: `JSONEncoder` emits
    /// a keyed container's keys in hash order, not declaration order, so the
    /// byte sequence was never stable to begin with — asserting on it would pin
    /// a Foundation implementation detail and call it compatibility. The field
    /// SET and its values are the thing that actually has to hold.
    func testAnOrdinaryHopEncodesWithoutAnAuthFieldAtAll() throws {
        var hop = JumpHop()
        hop.id = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3311")!
        hop.host = "a.example"; hop.port = 2201; hop.username = "jumper"
        hop.pinnedHostKey = "ssh-ed25519 A"

        let data = try JSONEncoder().encode(hop)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys),
                       ["id", "host", "port", "username", "pinnedHostKey"],
                       "an ordinary hop must write exactly the fields it always wrote — "
                       + "nothing added, nothing dropped")
        XCTAssertNil(object["auth"],
                     "the default must not be written down: a field nobody chose does not "
                     + "belong in every user's saved profile")
        XCTAssertEqual(object["id"] as? String, "3F2504E0-4F89-11D3-9A0C-0305E82C3311")
        XCTAssertEqual(object["host"] as? String, "a.example")
        XCTAssertEqual(object["port"] as? Int, 2201)
        XCTAssertEqual(object["username"] as? String, "jumper")
        XCTAssertEqual(object["pinnedHostKey"] as? String, "ssh-ed25519 A")

        // And the round trip is what a relaunch does: the same hop comes back,
        // id included (it is half the address of any credential stored later).
        XCTAssertEqual(try JSONDecoder().decode(JumpHop.self, from: data), hop)
    }

    /// …and a hop that DOES carry its own credential writes exactly one more
    /// key: which kind. Never the material — that is what the Keychain is for,
    /// and a private key in UserDefaults would be a backup-able plaintext key.
    func testAHopWithItsOwnCredentialWritesTheKindAndNeverTheSecret() throws {
        var hop = JumpHop()
        hop.host = "b.example"; hop.pinnedHostKey = "ssh-ed25519 B"
        hop.auth = .password

        let json = String(decoding: try JSONEncoder().encode(hop), as: UTF8.self)
        XCTAssertTrue(json.contains(#""auth":"password""#), "the KIND is saved: \(json)")
        let back = try JSONDecoder().decode(JumpHop.self, from: Data(json.utf8))
        XCTAssertEqual(back.auth, .password)
        XCTAssertEqual(back.id, hop.id, "…and the id, which is half the credential's address")

        // Nothing that could be a secret is in the encodable surface at all —
        // there is no property to hold one, and this is the assertion that
        // notices if someone ever adds one "just for convenience".
        var withSecrets = ServerProfile()
        withSecrets.route = [hop]
        let profileJSON = String(decoding: try JSONEncoder().encode(withSecrets), as: UTF8.self)
        for forbidden in ["password\":\"hunter", "BEGIN OPENSSH", "secret", "credential"] {
            XCTAssertFalse(profileJSON.contains(forbidden),
                           "a persisted profile must carry no credential material: \(forbidden)")
        }
    }

    /// Blank rows the editor may leave behind are not hops — they must never
    /// turn into a dial to "" or, worse, into a silently skipped pin check.
    func testBlankHopRowsAreIgnoredByTheConnection() throws {
        var p = ServerProfile()
        p.host = "c.example"; p.username = "me"; p.pinnedHostKey = "ssh-ed25519 T"
        var blank = JumpHop()
        var real = JumpHop(); real.host = "a.example"; real.pinnedHostKey = "ssh-ed25519 A"
        blank.host = "   "
        p.route = [blank, real]
        XCTAssertEqual(p.routeHops.map(\.host), ["a.example"],
                       "an empty row is a row the user has not filled in yet, not a hop")
    }

    // MARK: - Live: a legacy no-route profile still connects DIRECT

    /// The behavioural half of "byte for byte": a profile with no route connects
    /// to the sandbox target and runs a command, and NEITHER hop daemon sees a
    /// thing. A route implementation that quietly routed everything would still
    /// pass a connect test — it would not pass this one.
    func testLegacyNoRouteProfileStillConnectsDirectlyAndTouchesNoHop() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let direct = endpoint.profile
        XCTAssertTrue(direct.route.isEmpty)

        let entryBefore = endpoint.entryLog()
        let jumpBefore = endpoint.jumpLog()

        let service = SSHService()
        try await service.connect(profile: direct, secret: endpoint.privateKey)
        let nonce = "D1-\(UUID().uuidString.prefix(8))"
        let out = try await service.runCommand("echo \(nonce)-$((6*7))")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "\(nonce)-42")
        await service.disconnect()

        XCTAssertEqual(endpoint.entryLog(), entryBefore,
                       "a profile with no route must not touch hop A — not one log line")
        XCTAssertEqual(endpoint.jumpLog(), jumpBefore,
                       "a profile with no route must not touch hop B — not one log line")
    }
}
