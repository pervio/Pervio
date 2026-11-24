import XCTest
import NIO
import NIOSSH
@preconcurrency import Citadel
@testable import Pervio

/// A5c: a hop with its OWN credential — where the material lives, which hop it
/// belongs to, when it is thrown away, and what actually goes on the wire.
///
/// The live half of this feature is in `JumpChainTests` (R5): a real sshd that
/// authorizes only a second key, walked through a real route. That rig proves
/// the private-key path end to end and cannot be faked. What it CANNOT prove is
/// the password path: the sandbox daemons run `UsePAM no` /
/// `PasswordAuthentication no` — a throwaway sshd started as an unprivileged
/// user has no account it could accept a password for, and standing one up
/// would mean touching the machine's real auth stack. So the password path is
/// pinned one layer lower, at the seam where "this hop uses a password" stops
/// being a stored enum and becomes the offer Citadel sends: the test builds the
/// auth method the connect path would build and reads the offer out of Citadel's
/// own delegate.
///
/// SAID PLAINLY, because a green must not claim more than it proved:
///   * the PRIVATE-KEY per-hop path is proven against a real sshd (JumpChainTests R5);
///   * the PASSWORD per-hop path is proven up to the authentication offer —
///     the username and the password bytes handed to Citadel — and NOT against
///     a live sshd. Nothing here shows an sshd accepting that password.
@MainActor
final class HopCredentialTests: XCTestCase {

    private var realStore: KeychainStore!
    private var fake = FakeKeychainStore()
    /// The AppStore cases below really persist, so this suite borrows the app's
    /// profile list and gives it back exactly as it found it.
    private let profilesKey = "pervio.profiles.v1"
    private var savedProfiles: Data?

    override func setUp() {
        super.setUp()
        realStore = Keychain.store
        fake = FakeKeychainStore()
        Keychain.store = fake
        savedProfiles = UserDefaults.standard.data(forKey: profilesKey)
        UserDefaults.standard.removeObject(forKey: profilesKey)
    }
    override func tearDown() {
        Keychain.store = realStore      // never leave the app pointed at a fake
        if let savedProfiles { UserDefaults.standard.set(savedProfiles, forKey: profilesKey) }
        else { UserDefaults.standard.removeObject(forKey: profilesKey) }
        super.tearDown()
    }

    // MARK: - Helpers

    private func routedProfile() -> ServerProfile {
        var p = ServerProfile()
        p.name = "Behind two boxes"
        p.host = "target.example"
        p.port = 22
        p.username = "me"
        p.pinnedHostKey = "ssh-ed25519 TARGET"
        var a = JumpHop(); a.host = "a.example"; a.pinnedHostKey = "ssh-ed25519 A"
        var b = JumpHop(); b.host = "b.example"; b.port = 2022; b.pinnedHostKey = "ssh-ed25519 B"
        p.route = [a, b]
        return p
    }

    /// The offer `method` would put on the wire, read out of Citadel's own
    /// delegate rather than out of a copy of our intentions. `EmbeddedEventLoop`
    /// keeps it synchronous and socket-free: `nextAuthenticationType` completes
    /// the promise inline, and `run()` drains the callback.
    private func offer(_ method: SSHAuthenticationMethod,
                       available: NIOSSHAvailableUserAuthenticationMethods)
        throws -> NIOSSHUserAuthenticationOffer?
    {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        method.nextAuthenticationType(availableMethods: available, nextChallengePromise: promise)
        var outcome: Result<NIOSSHUserAuthenticationOffer?, Error>?
        promise.futureResult.whenComplete { outcome = $0 }
        loop.run()
        guard let outcome else {
            XCTFail("Citadel neither offered nor refused — the promise was never completed")
            return nil
        }
        return try outcome.get()
    }

    // MARK: - The password path, at the seam (NOT against a live sshd)

    /// A hop set to its own password authenticates with PASSWORD auth, carrying
    /// the password stored for THAT hop and the username that hop connects as.
    ///
    /// Three things could go wrong here and every one of them is silent: the hop
    /// could be built as a private-key offer (its password would be parsed as a
    /// key and refused), it could carry the PROFILE's secret instead of the
    /// hop's (the bug this whole feature exists to prevent, and one that would
    /// send the profile's private key to a machine as a password), or it could
    /// carry the right secret under the wrong username.
    func testAPasswordHopOffersPasswordAuthWithThatHopsStoredPassword() throws {
        var profile = routedProfile()
        profile.route[1].auth = .password
        profile.route[1].username = "bastionuser"
        let hop = profile.routeHops[1]

        Keychain.set("hunter2-for-hop-B", for: profile.hopSecretKey(hop))
        Keychain.set("-----BEGIN OPENSSH PRIVATE KEY-----", for: profile.id.uuidString)

        let hopProfile = profile.hopProfile(hop)
        XCTAssertEqual(hopProfile.authKind, .password,
                       "the hop's kind must follow the hop, not the profile")
        let secret = SSHService.hopSecret(hop, of: profile,
                                          profileSecret: "-----BEGIN OPENSSH PRIVATE KEY-----")
        XCTAssertEqual(secret, "hunter2-for-hop-B",
                       "the hop must be opened with ITS OWN stored secret")

        let method = try SSHService().makeAuthMethod(profile: hopProfile, secret: secret)
        let sent = try XCTUnwrap(offer(method, available: .all),
                                 "Citadel must offer something for a password hop")
        guard case .password(let password) = sent.offer else {
            return XCTFail("the hop must authenticate with PASSWORD auth, but Citadel was "
                           + "handed \(sent.offer) — a password sent as a private key is "
                           + "refused, and the user is told their key is unparseable")
        }
        XCTAssertEqual(password.password, "hunter2-for-hop-B",
                       "the password on the wire must be the one stored for this hop")
        XCTAssertNotEqual(password.password, "-----BEGIN OPENSSH PRIVATE KEY-----",
                          "the PROFILE's secret must never reach a hop that has its own")
        XCTAssertEqual(sent.username, "bastionuser",
                       "…as the username this hop connects with, not the target's")
    }

    /// A password hop refuses to authenticate at all against a server that does
    /// not offer password auth, instead of silently sending something else. This
    /// is Citadel's behaviour, pinned because it is what turns "this hop is
    /// configured wrong" into a refusal rather than a hang.
    func testAPasswordHopIsRefusedByAServerThatOffersOnlyPublicKeyAuth() throws {
        var profile = routedProfile()
        profile.route[1].auth = .password
        let hop = profile.routeHops[1]
        Keychain.set("hunter2", for: profile.hopSecretKey(hop))

        let method = try SSHService().makeAuthMethod(
            profile: profile.hopProfile(hop),
            secret: SSHService.hopSecret(hop, of: profile, profileSecret: "irrelevant"))
        XCTAssertThrowsError(try offer(method, available: .publicKey),
                             "a password offered to a publickey-only server must fail loudly")
    }

    /// A password is not a private key, and the private-key branch would refuse
    /// it. So the hop's KIND is what decides — proven by the fact that building
    /// a password hop from a string no key parser could accept does not throw.
    func testAPasswordHopDoesNotGoThroughThePrivateKeyParser() throws {
        var profile = routedProfile()
        profile.route[1].auth = .password
        let hop = profile.routeHops[1]
        Keychain.set("not a key at all", for: profile.hopSecretKey(hop))

        XCTAssertNoThrow(try SSHService().makeAuthMethod(
            profile: profile.hopProfile(hop),
            secret: SSHService.hopSecret(hop, of: profile, profileSecret: "x")))

        // The same string under a private-KEY hop is refused, which is what
        // makes the line above a statement about the kind and not about the
        // string being unexpectedly parseable.
        var asKey = profile
        asKey.route[1].auth = .privateKey
        let keyHop = asKey.routeHops[1]
        Keychain.set("not a key at all", for: asKey.hopSecretKey(keyHop))
        XCTAssertThrowsError(try SSHService().makeAuthMethod(
            profile: asKey.hopProfile(keyHop),
            secret: SSHService.hopSecret(keyHop, of: asKey, profileSecret: "x"))) { error in
            XCTAssertEqual((error as? SSHService.ConnectionError)?.kind, .badPrivateKey)
        }
    }

    // MARK: - Which secret opens which hop

    /// The default hop asks the Keychain NOTHING. It answers the profile's own
    /// secret, exactly as every route did before per-hop credentials existed —
    /// and the store recording zero calls is the strongest form of "this changed
    /// nothing for anybody who never asked for it".
    func testADefaultHopUsesTheProfilesSecretAndNeverTouchesTheKeychain() {
        let profile = routedProfile()
        let hop = profile.routeHops[0]
        XCTAssertEqual(hop.auth, .profile, "the default must be the profile's own credential")

        let secret = SSHService.hopSecret(hop, of: profile, profileSecret: "THE-PROFILE-KEY")
        XCTAssertEqual(secret, "THE-PROFILE-KEY")
        XCTAssertTrue(fake.calls.isEmpty,
                      "an ordinary hop must not even look for a per-hop credential — it has "
                      + "none, and a lookup is a way for one to start mattering: \(fake.calls)")
    }

    /// A hop with its own credential reads it from the Keychain under the
    /// profile+hop account, and gets "" (not the profile's secret) when there is
    /// nothing there. Falling back would be the worst possible failure: the
    /// route would connect through a hop with a credential the user did not
    /// choose, and nothing on screen would say so.
    func testAnOwnCredentialHopReadsTheKeychainAndNeverFallsBack() {
        var profile = routedProfile()
        profile.route[1].auth = .privateKey
        let hop = profile.routeHops[1]

        XCTAssertEqual(SSHService.hopSecret(hop, of: profile, profileSecret: "THE-PROFILE-KEY"), "",
                       "with nothing stored, a hop's credential is MISSING — never the "
                       + "profile's, which this hop was explicitly told not to use")

        Keychain.set("THE-HOP-KEY", for: profile.hopSecretKey(hop))
        XCTAssertEqual(SSHService.hopSecret(hop, of: profile, profileSecret: "THE-PROFILE-KEY"),
                       "THE-HOP-KEY")
    }

    /// What the editor is holding but has not saved wins over what is stored —
    /// the same rule the main credential field has always had. Without it, the
    /// editor's own "fetch this hop's key" could never reach a hop whose
    /// credential the user is in the middle of typing.
    func testATypedButUnsavedCredentialWinsOverTheStoredOne() {
        var profile = routedProfile()
        profile.route[1].auth = .privateKey
        let hop = profile.routeHops[1]
        Keychain.set("STORED", for: profile.hopSecretKey(hop))

        XCTAssertEqual(SSHService.hopSecret(hop, of: profile, profileSecret: "P",
                                            unsaved: [hop.id: "JUST-TYPED"]), "JUST-TYPED")
        XCTAssertEqual(SSHService.hopSecret(hop, of: profile, profileSecret: "P",
                                            unsaved: [hop.id: ""]), "STORED",
                       "a blank field means 'keep what is saved', never 'erase it'")
        XCTAssertEqual(SSHService.hopSecret(profile.routeHops[0], of: profile, profileSecret: "P",
                                            unsaved: [hop.id: "JUST-TYPED"]), "P",
                       "…and it applies to the hop it was typed for, not to its neighbours")
    }

    // MARK: - The Keychain account: unique per profile AND per hop

    /// Two hops, two profiles, four different accounts — and none of them can be
    /// confused with a profile's own secret. Position is deliberately not part
    /// of the key: dragging a hop up the list must carry its credential with it.
    func testHopAccountsAreUniquePerProfileAndPerHopAndNeverCollideWithAProfiles() {
        let p1 = routedProfile()
        var p2 = routedProfile()
        p2.id = UUID()

        let accounts = [p1.hopSecretKey(p1.route[0]), p1.hopSecretKey(p1.route[1]),
                        p2.hopSecretKey(p2.route[0]), p2.hopSecretKey(p2.route[1])]
        XCTAssertEqual(Set(accounts).count, 4, "every hop of every profile needs its own account")
        for account in accounts {
            XCTAssertFalse(account == p1.id.uuidString || account == p2.id.uuidString,
                           "a hop account must never be a profile's own account (\(account))")
            XCTAssertTrue(account.contains("/hop/"),
                          "the separator is what makes a collision impossible — a UUID string "
                          + "cannot contain it: \(account)")
        }

        var dragged = p1
        dragged.route.reverse()
        XCTAssertEqual(dragged.hopSecretKey(dragged.route[1]), p1.hopSecretKey(p1.route[0]),
                       "reordering the route must not orphan a hop's credential — the account "
                       + "is built from identity, not from position")
    }

    // MARK: - Lifetime: a credential dies with the thing that named it

    /// Deleting the server takes every hop credential with it. They are
    /// unreachable afterwards — the account is built from the profile's id and
    /// the hop's, and both are gone — so anything left behind would be a private
    /// key nobody can see and nobody will ever remove.
    func testDeletingAProfileRemovesEveryHopCredential() {
        let store = AppStore()
        var profile = routedProfile()
        profile.route[0].auth = .privateKey
        profile.route[1].auth = .password
        let accounts = profile.route.map { profile.hopSecretKey($0) }

        store.upsert(profile, secret: "profile-key",
                     hopSecrets: [profile.route[0].id: "hop-a-key",
                                  profile.route[1].id: "hop-b-password"])
        XCTAssertEqual(Keychain.get(accounts[0]), "hop-a-key", "precondition: stored")
        XCTAssertEqual(Keychain.get(accounts[1]), "hop-b-password", "precondition: stored")

        store.delete(profile)
        XCTAssertNil(Keychain.get(profile.id.uuidString))
        XCTAssertNil(Keychain.get(accounts[0]), "hop 1's credential outlived the server")
        XCTAssertNil(Keychain.get(accounts[1]), "hop 2's credential outlived the server")

    }

    /// Deleting a HOP takes its credential with it, and switching a hop back to
    /// the server's own credential drops the one it no longer uses. Both are
    /// done at save time — the only moment that can see the route being replaced
    /// as well as the one arriving.
    func testSavingDropsTheCredentialsOfDeletedAndRevertedHops() {
        let store = AppStore()
        var profile = routedProfile()
        profile.route[0].auth = .privateKey
        profile.route[1].auth = .password
        let hopA = profile.route[0], hopB = profile.route[1]

        store.upsert(profile, secret: "profile-key",
                     hopSecrets: [hopA.id: "hop-a-key", hopB.id: "hop-b-password"])
        XCTAssertNotNil(Keychain.get(profile.hopSecretKey(hopA)))
        XCTAssertNotNil(Keychain.get(profile.hopSecretKey(hopB)))

        // Hop A deleted, hop B put back on the server's own credential.
        var edited = profile
        edited.route.removeFirst()
        edited.route[0].auth = .profile
        store.upsert(edited, secret: nil)

        XCTAssertNil(Keychain.get(profile.hopSecretKey(hopA)),
                     "a deleted hop's credential must go with the row")
        XCTAssertNil(Keychain.get(profile.hopSecretKey(hopB)),
                     "a hop that no longer uses its own credential must not keep one — an "
                     + "unreferenced key is one nobody will ever notice is still here")
        XCTAssertEqual(Keychain.get(profile.id.uuidString), "profile-key",
                       "…and the server's own secret is untouched by any of it")

    }

    /// A save with a blank field keeps what is stored (the same blank-means-keep
    /// rule as the main credential), and a save that carries a new one replaces it.
    func testABlankHopFieldKeepsTheStoredCredentialAndANewOneReplacesIt() {
        let store = AppStore()
        var profile = routedProfile()
        profile.route[1].auth = .privateKey
        let hop = profile.route[1]

        store.upsert(profile, secret: "profile-key", hopSecrets: [hop.id: "first-key"])
        store.upsert(profile, secret: nil, hopSecrets: [hop.id: ""])
        XCTAssertEqual(Keychain.get(profile.hopSecretKey(hop)), "first-key",
                       "a blank field is 'keep it' — nothing is ever preloaded into the field, "
                       + "so a blank one cannot mean 'erase'")

        store.upsert(profile, secret: nil, hopSecrets: [hop.id: "rotated-key"])
        XCTAssertEqual(Keychain.get(profile.hopSecretKey(hop)), "rotated-key")

    }

    /// "Blank keeps it" is for the SAME sign-in method. A private key kept
    /// across a switch to password was sent, whole, as the password — to a
    /// machine that until then had only checked a signature (the 2026-11-22
    /// review). A switch with nothing typed leaves nothing stored, on a hop
    /// and on the server itself.
    func testASecretSavedForOneSignInMethodIsNotKeptForAnother() {
        let store = AppStore()
        var profile = routedProfile()
        profile.authKind = .privateKey
        profile.route[1].auth = .privateKey
        let hop = profile.route[1]
        store.upsert(profile, secret: "PROFILE-PRIVATE-KEY", hopSecrets: [hop.id: "HOP-PRIVATE-KEY"])

        var switched = profile
        switched.route[1].auth = .password
        store.upsert(switched, secret: nil, hopSecrets: [hop.id: ""])
        XCTAssertNil(Keychain.get(profile.hopSecretKey(hop)), "the hop's private key must not wait there to be sent as its password")
        XCTAssertEqual(SSHService.hopSecret(switched.route[1], of: switched, profileSecret: "PROFILE-PRIVATE-KEY"), "",
                       "…and what the hop is offered is nothing")
        XCTAssertEqual(Keychain.get(profile.id.uuidString), "PROFILE-PRIVATE-KEY", "the server's own method did not change: kept")

        switched.authKind = .password
        store.upsert(switched, secret: nil, hopSecrets: [:])
        XCTAssertNil(Keychain.get(profile.id.uuidString), "the same for the server itself")
        store.upsert(switched, secret: "the-password", hopSecrets: [hop.id: "hop-password"])
        store.upsert(switched, secret: nil, hopSecrets: [hop.id: ""])
        XCTAssertEqual(Keychain.get(profile.id.uuidString), "the-password", "typed for the new method, then blank keeps it as before")
        XCTAssertEqual(Keychain.get(profile.hopSecretKey(hop)), "hop-password")
        store.delete(switched)
    }

    // MARK: - A missing hop credential says "missing", not "unparsable"

    /// An own-credential hop whose secret was never stored on THIS phone (new
    /// device, reinstall — the Keychain doesn't travel) used to fall through to
    /// the key parser, so the user read「私钥无法解析」and went hunting for key
    /// corruption that didn't exist. `hopSecretIsMissing` is the pre-socket
    /// refusal's decision; only own-credential kinds count — a `.profile` hop
    /// riding the profile's secret is never "missing" here (an empty PROFILE
    /// secret is the target's problem and diagnosed as such).
    // MARK: A jump host is never handed the target's password (security review #4)

    /// "Same as the server" under a password login would put the target's
    /// password into the hop's own login. Under a key login nothing is handed
    /// over, and a hop with a credential of its own never rides the server's.
    func testOnlyAHopOnTheServersPasswordWouldReceiveIt() {
        var byPassword = TestFactory.profile(); byPassword.authKind = .password
        var byKey = TestFactory.profile(); byKey.authKind = .privateKey
        var shared = JumpHop(); shared.host = "jump.example"; shared.auth = .profile
        var ownPassword = shared; ownPassword.auth = .password
        var ownKey = shared; ownKey.auth = .privateKey
        XCTAssertTrue(SSHService.hopWouldReceiveTargetPassword(shared, of: byPassword))
        XCTAssertFalse(SSHService.hopWouldReceiveTargetPassword(shared, of: byKey),
                       "a key proves itself without being handed over")
        XCTAssertFalse(SSHService.hopWouldReceiveTargetPassword(ownPassword, of: byPassword))
        XCTAssertFalse(SSHService.hopWouldReceiveTargetPassword(ownKey, of: byPassword))
    }

    /// Such a route is refused BEFORE anything is dialed, and the refusal says
    /// what would have happened and where to change it. The hop's address does
    /// not resolve: a refusal that came from the network would read otherwise.
    func testARouteThatWouldHandOverThePasswordIsRefusedBeforeDialing() async {
        var profile = TestFactory.profile()
        profile.authKind = .password
        var hop = JumpHop()
        hop.host = "jump.invalid"; hop.pinnedHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ"
        hop.auth = .profile
        profile.route = [hop]
        let ssh = SSHService()
        do {
            try await ssh.connect(profile: profile, secret: "THE-TARGET-PASSWORD")
            XCTFail("connected through a hop that would have received the target's password")
        } catch {
            let said = (error as? SSHService.ConnectionError)?.message ?? "\(error)"
            XCTAssertTrue(said.contains(L.connErrHopWouldGetTargetPassword()), said)
            XCTAssertEqual((error as? SSHService.ConnectionError)?.kind, .missingSecret,
                           "the same door as a hop with no credential: the server editor")
        }
        for lang in [PromptLanguage.chinese, .english] {
            XCTAssertFalse(L.connErrHopWouldGetTargetPassword(lang).isEmpty)
            XCTAssertFalse(L.routeHopSharedPassword(lang).isEmpty)
        }
    }

    func testMissingHopCredential_isNamedNotMisdiagnosed() {
        var profile = routedProfile()
        profile.route[1].auth = .privateKey
        let keyHop = profile.routeHops[1]
        XCTAssertTrue(SSHService.hopSecretIsMissing(keyHop, resolved: ""),
                      "own key wanted, nothing on this device — that IS the missing case")
        XCTAssertFalse(SSHService.hopSecretIsMissing(keyHop, resolved: "THE-HOP-KEY"))

        profile.route[1].auth = .password
        XCTAssertTrue(SSHService.hopSecretIsMissing(profile.routeHops[1], resolved: ""))

        profile.route[1].auth = .profile
        XCTAssertFalse(SSHService.hopSecretIsMissing(profile.routeHops[1], resolved: ""),
                       "a profile-secret hop never reports missing — it uses whatever "
                       + "the profile has, and an empty one fails at the target with "
                       + "the target's own diagnosis")

        // The words the refusal carries: they must say what is missing, that a
        // new device is the normal cause, and where to fix it — in BOTH languages.
        for (lang, fix) in [(PromptLanguage.chinese, "重新填一次"),
                            (PromptLanguage.english, "enter it once more")] {
            let msg = L.connErrHopSecretMissing(lang)
            XCTAssertTrue(msg.contains(fix), "must point at the one remedy: \(msg)")
        }
        XCTAssertTrue(L.connErrHopSecretMissing(.chinese).contains("没有存"),
                      "must say the credential is ABSENT, not broken")
    }
}
