import XCTest
import UIKit
import UserNotifications
@testable import Pervio

/// ONE finished task, ONE notification.
///
/// What the user hit: a background run ended and the phone buzzed twice — the
/// Mac's lock-screen push ("回答好了") and the app's own banner ("Task finished"),
/// side by side, about the same run. Both channels are needed (the Mac's is the
/// only one that survives iOS suspending the app; the app's is the only one a Mac
/// without an APNs key has), so the cure is ownership, not deletion: while the Mac
/// can push, it owns the banner for the events it pushes about, and the app stands
/// down. These pin that contract from both sides — the suppression AND the fallback
/// that must not be suppressed with it.
///
/// THE REGRESSION THAT REOPENED THE DOUBLE. The ownership flag was a boolean that
/// started "assume the Mac can't push" and flipped true only once a slow SSH probe
/// answered READY. But RunMonitor's poll notices a run that finished during suspend
/// on the FIRST poll after we wake — routinely BEFORE the probe answers (or after
/// iOS dropped the APNs token so the probe never ran at all). At that instant the
/// old boolean was still false, so RunMonitor posted its banner beside the Mac's
/// push: the exact double, back again. The flag is now three-state — READY /
/// explicit-OFF / UNKNOWN — and a detached run defers to the Mac unless it said
/// outright it can't (OFF). UNKNOWN, the in-flight window, defers too.
///
/// Why ownership rather than "the app records the push it received": the Mac's
/// payload is alert-only (`pervio-push.build_payload` sets no `content-available`),
/// so a suspended app is never handed the push at all — and suspended is exactly
/// when the Mac's push matters. There is nothing to record.
@MainActor
final class CompletionNotifierTests: XCTestCase {

    /// Every banner the notifier tried to post during one test.
    private var posted: [UNNotificationRequest] = []
    private var savedPush: CompletionNotifier.ServerPushState = .unknown
    private var savedLang: Any?

    override func setUp() {
        super.setUp()
        posted = []
        savedPush = CompletionNotifier.serverPush
        CompletionNotifier.deliver = { [weak self] req in self?.posted.append(req) }
        CompletionNotifier.appIsActive = { false }        // "phone away" unless a test says otherwise
        // zh pins predate the English default flip: pin the language, don't
        // clear it (absent now means English).
        savedLang = UserDefaults.standard.object(forKey: PromptLanguage.defaultsKey)
        UserDefaults.standard.set("zh", forKey: PromptLanguage.defaultsKey)
    }

    override func tearDown() {
        CompletionNotifier.serverPush = savedPush
        if let savedLang { UserDefaults.standard.set(savedLang, forKey: PromptLanguage.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: PromptLanguage.defaultsKey) }
        // Put the PRODUCTION closures back, not stand-ins — these are process-wide
        // and the rest of the suite runs after us.
        CompletionNotifier.deliver = { req in UNUserNotificationCenter.current().add(req) }
        CompletionNotifier.appIsActive = { UIApplication.shared.applicationState == .active }
        UserDefaults.standard.removeObject(forKey: "pervio.promptLanguage")
        super.tearDown()
    }

    /// A key nothing else in the suite can collide with (the 30s de-dupe window is
    /// process-wide and outlives a single test).
    private func freshKey() -> String { "run-" + UUID().uuidString }

    // MARK: - The double the user reported

    func testDetachedRun_staysSilentWhenTheMacIsAlreadyPushing() {
        CompletionNotifier.serverPush = .ready
        CompletionNotifier.taskFinished(ok: true, project: "Pervio", summary: "改完了",
                                        dedupeKey: freshKey(), serverPushes: true)
        XCTAssertTrue(posted.isEmpty,
                      "the Mac's push is already saying this — a second banner is the "
                      + "double the user reported: \(posted.map(\.content.title))")
    }

    func testWorkflow_staysSilentWhenTheMacIsAlreadyPushing() {
        CompletionNotifier.serverPush = .ready
        CompletionNotifier.taskFinished(ok: true, project: "论文晨报", summary: "3 步全部完成",
                                        dedupeKey: freshKey(), serverPushes: true)
        XCTAssertTrue(posted.isEmpty,
                      "pervio-orchestrate pushes both workflow outcomes now: \(posted.count)")
    }

    /// THE ACTUAL REGRESSION. The probe hasn't answered yet (a fast poll-after-wake,
    /// or a token iOS dropped so the probe never ran) — readiness is UNKNOWN, not a
    /// definite "can't push". The old boolean, still false here, let RunMonitor post
    /// its banner right beside the Mac's push. UNKNOWN must now defer just like READY:
    /// a detached run is always pushed by the Mac, and a woken app is where that push
    /// already landed.
    func testDetachedRun_staysSilentWhileReadinessStillUnknown() {
        CompletionNotifier.serverPush = .unknown           // probe in flight / token dropped
        CompletionNotifier.taskFinished(ok: true, project: "Pervio", summary: "改完了",
                                        dedupeKey: freshKey(), serverPushes: true)
        XCTAssertTrue(posted.isEmpty,
                      "an unfinished probe is not a licence to double the Mac's push — a "
                      + "detached run is pushed by the Mac regardless: \(posted.map(\.content.title))")
    }

    // MARK: - …and the fallback that must survive it

    func testDetachedRun_bannersWhenTheMacExplicitlySaysItCannotPush() {
        CompletionNotifier.serverPush = .notReady          // probe ran, answered OFF
        CompletionNotifier.taskFinished(ok: true, project: "Pervio", summary: "改完了",
                                        dedupeKey: freshKey(), serverPushes: true)
        XCTAssertEqual(posted.count, 1,
                       "an un-provisioned Mac (no APNs key / no token) pushes nothing — "
                       + "silencing this too would leave the user with NO notification at all")
    }

    func testPlainChatTurn_bannersEvenWhileTheMacIsArmed() {
        CompletionNotifier.serverPush = .ready
        // No runId: a live chat turn. pervio-chat has no wrapper and never pushes, so
        // this banner is the only notice there is — the suppression must not reach it.
        CompletionNotifier.taskFinished(ok: true, project: "Pervio", summary: "答完了",
                                        dedupeKey: nil, serverPushes: false)
        XCTAssertEqual(posted.count, 1, "a chat turn has no server push to defer to")
    }

    /// A plain chat turn must banner even while readiness is UNKNOWN — it is NOT a
    /// server-pushed completion, so the fail-closed suppression must never touch it.
    func testPlainChatTurn_bannersWhileReadinessUnknown() {
        CompletionNotifier.serverPush = .unknown
        CompletionNotifier.taskFinished(ok: true, project: "Pervio", summary: "答完了",
                                        dedupeKey: nil, serverPushes: false)
        XCTAssertEqual(posted.count, 1,
                       "the fail-closed defer is for server-pushed runs only, never a chat turn")
    }

    func testSuppressedInTheForeground_leavesAHapticNotSilence() {
        CompletionNotifier.serverPush = .ready
        CompletionNotifier.appIsActive = { true }
        // Foreground: iOS hands the Mac's push to AppDelegate.willPresent, which
        // swallows it. Suppressing our banner too would be total silence while the
        // user is looking at the app, so the notifier drops to a haptic instead.
        CompletionNotifier.taskFinished(ok: true, project: "Pervio", summary: "改完了",
                                        dedupeKey: freshKey(), serverPushes: true)
        XCTAssertTrue(posted.isEmpty, "still no banner — the push is the banner")
    }

    // MARK: - The in-process de-dupe still holds

    func testOneRunSeenTwice_bannersOnce() {
        CompletionNotifier.serverPush = .notReady
        let key = freshKey()
        // The live tail and RunMonitor's poll can both witness one finish.
        CompletionNotifier.taskFinished(ok: true, project: "Pervio", summary: "一",
                                        dedupeKey: key, serverPushes: true)
        CompletionNotifier.taskFinished(ok: true, project: "Pervio", summary: "二",
                                        dedupeKey: key, serverPushes: true)
        XCTAssertEqual(posted.count, 1, "the runId claim collapses the two observers")
    }

    // MARK: - The words

    func testBannerCopy_namesTheProjectAndTheTaskAndFollowsTheLanguageToggle() {
        CompletionNotifier.serverPush = .notReady
        CompletionNotifier.taskFinished(ok: true, project: "Pervio",
                                        summary: "修两件事:重复提醒 + 抓取骤降",
                                        dedupeKey: freshKey(), serverPushes: true)
        XCTAssertEqual(posted.count, 1)
        let c = posted[0].content
        // Chinese is the shipped default — the title used to be hard-coded English.
        XCTAssertEqual(c.title, "任务完成")
        XCTAssertEqual(c.subtitle, "Pervio", "which project this was")
        XCTAssertEqual(c.body, "修两件事:重复提醒 + 抓取骤降", "which task this was")

        posted = []
        UserDefaults.standard.set("en", forKey: "pervio.promptLanguage")
        CompletionNotifier.taskFinished(ok: false, project: "Pervio", summary: "",
                                        dedupeKey: freshKey(), serverPushes: true)
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted[0].content.title, "Task failed",
                       "the banner follows the same Settings toggle as the rest of the app")
        XCTAssertEqual(posted[0].content.body, "Ended with an error.",
                       "an empty summary still says something")
    }
}
