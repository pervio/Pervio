import XCTest
@testable import Pervio

/// The APNs device token has to reach the Mac over the SAME SSH channel the app
/// already owns — no third-party push service. `PushTokenStore` is that path, and
/// what it puts ON THE WIRE is the contract `pervio-push` reads on the other end:
/// a hex token written to `~/.pervio/push/tokens/<device>`. These tests pin that
/// command (so a change to where/how the token is stored fails loudly here), plus
/// the two cost/robustness rules around it — skip an unchanged token, re-upload a
/// rotated one, and stay silent when there's nothing to authenticate with.
@MainActor
final class PushTokenUploadTests: XCTestCase {

    /// A fresh UserDefaults per test so the "last uploaded" memo never leaks
    /// between cases (or from a previous run of the suite).
    private func freshDefaults() -> UserDefaults {
        let suite = "pervio.pushtest.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func store(_ fake: FakeSSH, defaults: UserDefaults,
                       device: String = "DEVICE-1") -> PushTokenStore {
        PushTokenStore(ssh: fake, defaults: defaults, deviceId: device)
    }

    /// 16 bytes 0x01…0x10 → a known hex string, so the wire assertion is exact.
    private func sampleToken() -> (Data, String) {
        let bytes: [UInt8] = Array(1...16)
        return (Data(bytes), bytes.map { String(format: "%02x", $0) }.joined())
    }

    func testUpload_writesHexTokenToTheDeviceFileOverSSH() async {
        let fake = FakeSSH()
        fake.script("push/tokens", "")          // the write command answers empty
        let (token, hex) = sampleToken()

        let did = await store(fake, defaults: freshDefaults())
            .uploadIfNeeded(deviceToken: token, profile: TestFactory.profile(),
                            secret: "pw", lang: "zh")

        XCTAssertTrue(did, "a first, non-empty token with a secret must be uploaded")
        // It connected, ran exactly one command, and disconnected.
        XCTAssertEqual(fake.calls.first, "connect")
        let writes = fake.commandCalls(containing: "push/tokens")
        XCTAssertEqual(writes.count, 1, "exactly one write, got: \(fake.calls)")
        let cmd = writes[0]
        // The token lands in ~/.pervio/push/tokens/<device>, created 0700, as hex.
        XCTAssertTrue(cmd.contains("mkdir -p ~/.pervio/push/tokens"), cmd)
        XCTAssertTrue(cmd.contains("~/.pervio/push/tokens/'DEVICE-1'"),
                      "must write to this device's file: \(cmd)")
        XCTAssertTrue(cmd.contains("printf '%s' '\(hex)'"),
                      "must printf the exact hex token, shell-quoted: \(cmd)")
        // The phone's language rides the SAME round trip: the Mac's own pushes
        // (task finished / workflow failed / approval waiting) branch on this file.
        XCTAssertTrue(cmd.contains("printf '%s' 'zh' > ~/.pervio/push/lang"),
                      "must record the phone's language beside the token: \(cmd)")
        XCTAssertTrue(fake.calls.contains("disconnect"), "must not leak the connection")
    }

    func testUpload_skipsWhenTokenUnchanged() async {
        let fake = FakeSSH()
        fake.script("push/tokens", "")
        let defaults = freshDefaults()
        let (token, _) = sampleToken()
        let profile = TestFactory.profile()

        let first = await store(fake, defaults: defaults)
            .uploadIfNeeded(deviceToken: token, profile: profile, secret: "pw", lang: "zh")
        XCTAssertTrue(first)

        // A brand-new store instance (as on the next launch) with the SAME defaults
        // and the SAME token AND language must NOT open a connection at all.
        let fake2 = FakeSSH()
        fake2.script("push/tokens", "")
        let second = await store(fake2, defaults: defaults)
            .uploadIfNeeded(deviceToken: token, profile: profile, secret: "pw", lang: "zh")
        XCTAssertFalse(second, "an unchanged token+language must be a no-op")
        XCTAssertTrue(fake2.calls.isEmpty, "no SSH at all when nothing changed: \(fake2.calls)")
    }

    func testUpload_reuploadsToASecondServer() async {
        // The memo is per server: a token already on the MacBook still has to
        // reach the new mini, else every push from the mini silently no-ops.
        let defaults = freshDefaults()
        let (token, _) = sampleToken()
        let fake = FakeSSH()
        fake.script("push/tokens", "")
        let macbook = TestFactory.profile()
        let first = await store(fake, defaults: defaults)
            .uploadIfNeeded(deviceToken: token, profile: macbook, secret: "pw", lang: "zh")
        XCTAssertTrue(first)
        var mini = TestFactory.profile()
        mini.host = "mini.invalid"
        XCTAssertNotEqual(mini.id, macbook.id, "two servers, two ids")
        let fake2 = FakeSSH()
        fake2.script("push/tokens", "")
        let second = await store(fake2, defaults: defaults)
            .uploadIfNeeded(deviceToken: token, profile: mini, secret: "pw", lang: "zh")
        XCTAssertTrue(second, "the same token must be uploaded again to a server that never got it")
        XCTAssertTrue(fake2.calls.contains { $0.contains("push/tokens") }, fake2.calls.joined(separator: " | "))
        let fake3 = FakeSSH()
        let third = await store(fake3, defaults: defaults)
            .uploadIfNeeded(deviceToken: token, profile: mini, secret: "pw", lang: "zh")
        XCTAssertFalse(third, "and then it is remembered for that server")
    }

    func testUpload_reuploadsWhenOnlyTheLanguageChanged() async {
        // The token is stable across launches, but the user can flip the app's
        // language in Settings. The Mac's push copy follows the synced file, so a
        // language change with an UNCHANGED token must still open a connection —
        // the old memo (hex only) would have skipped it and left the Mac speaking
        // the wrong language forever.
        let fake = FakeSSH()
        fake.script("push/tokens", "")
        let defaults = freshDefaults()
        let (token, hex) = sampleToken()
        let profile = TestFactory.profile()

        _ = await store(fake, defaults: defaults)
            .uploadIfNeeded(deviceToken: token, profile: profile, secret: "pw", lang: "zh")

        let fake2 = FakeSSH()
        fake2.script("push/tokens", "")
        let did = await store(fake2, defaults: defaults)
            .uploadIfNeeded(deviceToken: token, profile: profile, secret: "pw", lang: "en")
        XCTAssertTrue(did, "a language flip must re-sync even though the token is unchanged")
        let cmd = fake2.commandCalls(containing: "push/tokens").first ?? ""
        XCTAssertTrue(cmd.contains("printf '%s' 'en' > ~/.pervio/push/lang"),
                      "must record the NEW language: \(cmd)")
        XCTAssertTrue(cmd.contains(hex), "the token still rides along: \(cmd)")
    }

    // MARK: - Settings toggle → immediate re-sync (no relaunch, no fresh token)

    func testResyncLanguage_usesTheRememberedTokenAndSkipsWhenUnchanged() async {
        // Flipping the language in Settings happens with no APNs callback in
        // sight, so the re-sync must ride the REMEMBERED hex. And it must be as
        // cheap as the launch path: same language again → no SSH at all.
        let defaults = freshDefaults()
        let (token, hex) = sampleToken()
        let profile = TestFactory.profile()

        // Nothing ever uploaded → nothing to re-sync with; stay silent.
        let bare = FakeSSH()
        let nothing = await store(bare, defaults: defaults)
            .resyncLanguageIfNeeded(profile: profile, secret: "pw", lang: "en")
        XCTAssertFalse(nothing, "no remembered token — a resync has nothing to send")
        XCTAssertTrue(bare.calls.isEmpty, "\(bare.calls)")

        let fake = FakeSSH()
        fake.script("push/tokens", "")
        _ = await store(fake, defaults: defaults)
            .uploadIfNeeded(deviceToken: token, profile: profile, secret: "pw", lang: "zh")

        let fake2 = FakeSSH()
        fake2.script("push/tokens", "")
        let did = await store(fake2, defaults: defaults)
            .resyncLanguageIfNeeded(profile: profile, secret: "pw", lang: "en")
        XCTAssertTrue(did, "the toggle changed the language — must sync now, not next launch")
        let cmd = fake2.commandCalls(containing: "push/tokens").first ?? ""
        XCTAssertTrue(cmd.contains("printf '%s' 'en' > ~/.pervio/push/lang"), cmd)
        XCTAssertTrue(cmd.contains(hex), "the remembered token rides along: \(cmd)")

        let fake3 = FakeSSH()
        fake3.script("push/tokens", "")
        let again = await store(fake3, defaults: defaults)
            .resyncLanguageIfNeeded(profile: profile, secret: "pw", lang: "en")
        XCTAssertFalse(again, "same language again must be a no-op")
        XCTAssertTrue(fake3.calls.isEmpty, "\(fake3.calls)")
    }

    func testUpload_reuploadsWhenTokenRotates() async {
        let fake = FakeSSH()
        fake.script("push/tokens", "")
        let defaults = freshDefaults()
        let profile = TestFactory.profile()

        let (token1, hex1) = sampleToken()
        _ = await store(fake, defaults: defaults)
            .uploadIfNeeded(deviceToken: token1, profile: profile, secret: "pw")

        // Apple rotated the token: different bytes → must upload again.
        let token2 = Data(Array(repeating: UInt8(0xAB), count: 32))
        let hex2 = token2.map { String(format: "%02x", $0) }.joined()
        let fake2 = FakeSSH()
        fake2.script("push/tokens", "")
        let did = await store(fake2, defaults: defaults)
            .uploadIfNeeded(deviceToken: token2, profile: profile, secret: "pw")

        XCTAssertTrue(did, "a rotated token must be re-uploaded")
        let cmd = fake2.commandCalls(containing: "push/tokens").first ?? ""
        XCTAssertTrue(cmd.contains(hex2), "must send the NEW token: \(cmd)")
        XCTAssertFalse(cmd.contains(hex1), "must not resend the old token: \(cmd)")
    }

    func testUpload_noSecretIsASilentNoOp() async {
        let fake = FakeSSH()
        let (token, _) = sampleToken()
        let did = await store(fake, defaults: freshDefaults())
            .uploadIfNeeded(deviceToken: token, profile: TestFactory.profile(), secret: nil)
        XCTAssertFalse(did)
        XCTAssertTrue(fake.calls.isEmpty, "without a secret we can't connect — do nothing: \(fake.calls)")
    }

    func testUpload_connectFailureDoesNotThrowAndIsNotRemembered() async {
        let fake = FakeSSH()
        fake.connectError = FakeSSH.Boom(message: "server unreachable")
        let defaults = freshDefaults()
        let (token, _) = sampleToken()
        let profile = TestFactory.profile()

        // A failed upload must not throw (it's fire-and-forget from the app delegate)…
        let did = await store(fake, defaults: defaults)
            .uploadIfNeeded(deviceToken: token, profile: profile, secret: "pw")
        XCTAssertFalse(did)

        // …and must NOT record the token as uploaded, so the next launch retries.
        let fake2 = FakeSSH()
        fake2.script("push/tokens", "")
        let retry = await store(fake2, defaults: defaults)
            .uploadIfNeeded(deviceToken: token, profile: profile, secret: "pw")
        XCTAssertTrue(retry, "a token that failed to upload must be retried, not remembered")
    }

    // MARK: - "Can the Mac reach this phone?" — the answer that stops the double

    /// The app must not post its own "task finished" banner beside the Mac's push,
    /// but it must keep posting one when the Mac CAN'T push. That decision hangs on
    /// this probe, which now answers THREE ways — READY, an explicit OFF, or (a
    /// failure) an honest UNKNOWN — because the old boolean collapsed "the Mac said
    /// no" and "we couldn't ask" into one "keep notifying", and the latter re-armed
    /// the local banner during the very window (probe in flight) where the Mac's
    /// push was already arriving. Each outcome is pinned.
    func testReadinessProbe_asksPervioPushAndArmsTheNotifierOnREADY() async {
        let fake = FakeSSH()
        fake.script("pervio-push", "PERVIO-PUSH-READY\n")
        CompletionNotifier.serverPush = .notReady          // start opposite to prove the flip

        let state = await store(fake, defaults: freshDefaults())
            .probePushReadiness(profile: TestFactory.profile(), secret: "pw")

        XCTAssertEqual(state, .ready)
        XCTAssertEqual(CompletionNotifier.serverPush, .ready,
                       "a READY Mac owns the completion banner from here on")
        let cmd = fake.commandCalls(containing: "pervio-push").first ?? ""
        XCTAssertTrue(cmd.contains("pervio-push check"),
                      "must ask the Mac's own readiness subcommand: \(cmd)")
        XCTAssertTrue(fake.calls.contains("disconnect"), "must not leak the connection")
        CompletionNotifier.serverPush = .unknown
    }

    func testReadinessProbe_reArmsTheLocalBannerWhenTheMacExplicitlyCannotPush() async {
        // An explicit OFF (or an old server whose missing `check` subcommand makes
        // the shell print OFF) is the Mac SAYING it can't push — the one case where
        // the app's banner is the only notice there is, so it must come back on.
        let fake = FakeSSH()
        fake.script("pervio-push", "PERVIO-PUSH-OFF\n")
        CompletionNotifier.serverPush = .ready             // stale ready from a past probe

        let state = await store(fake, defaults: freshDefaults())
            .probePushReadiness(profile: TestFactory.profile(), secret: "pw")

        XCTAssertEqual(state, .notReady)
        XCTAssertEqual(CompletionNotifier.serverPush, .notReady,
                       "no key / no token on the Mac ⇒ the app's banner is the ONLY "
                       + "notification the user would get; it must stay on")
        CompletionNotifier.serverPush = .unknown
    }

    func testReadinessProbe_aFailedProbeLeavesReadinessUNKNOWN_notNotReady() async {
        // The crux of the fix: a probe we couldn't RUN (dead connection) must NOT be
        // read as "the Mac can't push". Reading it that way turned the local banner
        // back on and doubled the Mac's push the instant the push was in fact
        // working. UNKNOWN defers to the Mac; only an OFF answer re-arms the banner.
        let dead = FakeSSH()
        dead.connectError = FakeSSH.Boom(message: "server unreachable")
        CompletionNotifier.serverPush = .ready             // a prior launch found it ready
        let state = await store(dead, defaults: freshDefaults())
            .probePushReadiness(profile: TestFactory.profile(), secret: "pw")
        XCTAssertEqual(state, .ready,
                       "a failed probe must not clobber a known-good readiness — the "
                       + "failure was ours, not the Mac's push")
        XCTAssertEqual(CompletionNotifier.serverPush, .ready)

        // With no prior knowledge, a failed probe simply stays UNKNOWN (which the
        // notifier treats as 'defer to the Mac' for a detached run).
        CompletionNotifier.serverPush = .unknown
        let dead2 = FakeSSH()
        dead2.connectError = FakeSSH.Boom(message: "server unreachable")
        let state2 = await store(dead2, defaults: freshDefaults())
            .probePushReadiness(profile: TestFactory.profile(), secret: "pw")
        XCTAssertEqual(state2, .unknown)

        let noSecret = FakeSSH()
        let state3 = await store(noSecret, defaults: freshDefaults())
            .probePushReadiness(profile: TestFactory.profile(), secret: nil)
        XCTAssertEqual(state3, .unknown)
        XCTAssertTrue(noSecret.calls.isEmpty, "nothing to authenticate with: \(noSecret.calls)")
        CompletionNotifier.serverPush = .unknown
    }

    func testDeviceId_sanitizedForTheShellAndFilesystem() {
        // A hostile/odd device id can't smuggle a path or a shell metacharacter.
        XCTAssertEqual(PushTokenStore.sanitizeDeviceId("../../etc/pass wd; rm -rf"),
                       "....etcpasswdrm-rf")
        XCTAssertEqual(PushTokenStore.sanitizeDeviceId(""), "unknown-device")
        // A normal vendor UUID passes through untouched.
        let uuid = "E2E00000-0000-4000-8000-000000000001"
        XCTAssertEqual(PushTokenStore.sanitizeDeviceId(uuid), uuid)
    }
}
