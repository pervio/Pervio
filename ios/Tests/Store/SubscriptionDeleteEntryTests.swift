import XCTest
@testable import Pervio

/// U3: unsubscribing was a hidden gesture. The only way to stop a daily job from
/// the Workflows screen was to swipe the row (or find the long-press menu) —
/// nothing on screen said the row could be deleted at all, so a subscription the
/// user no longer wanted kept firing (and kept spending) every morning.
///
/// Adding a VISIBLE delete on the row raises the stakes on the confirmation: a
/// button sitting in the row is far easier to hit by accident than a deliberate
/// swipe, and the thing behind it is irreversible from the phone. These tests
/// pin the second step — what the dialog says, and that it can't be confused
/// with the OTHER destructive verb on the same screen (deleting a past run).
@MainActor
final class SubscriptionDeleteEntryTests: XCTestCase {

    // These assertions read the ENGLISH wording of the confirmation ("daily",
    // "delete", "run", "home"); the dialog now follows the app-language setting,
    // whose default is Chinese, so pin English here. (The Chinese default is
    // pinned separately in UIStringsTests.testDefault_deleteConfirmationsAreChinese.)
    private let langKey = "pervio.promptLanguage"
    private var savedLang: Any?
    override func setUp() {
        super.setUp()
        savedLang = UserDefaults.standard.object(forKey: langKey)
        UserDefaults.standard.set("en", forKey: langKey)
    }
    override func tearDown() {
        if let savedLang { UserDefaults.standard.set(savedLang, forKey: langKey) }
        else { UserDefaults.standard.removeObject(forKey: langKey) }
        super.tearDown()
    }

    private func prompt(_ p: WorkflowsView.PendingDelete) -> (title: String, confirm: String) {
        p.prompt
    }

    func testU3_deletingASubscriptionAsksFirstAndSaysWhatStops() {
        let p = prompt(.schedule(id: "sched-1", publishes: false))

        XCTAssertFalse(p.title.isEmpty,
                       "an empty title renders a confirmation sheet with no question on it — "
                       + "one more tap and the daily job is gone")
        XCTAssertTrue(p.title.lowercased().contains("daily"),
                      "the dialog has to say WHAT stops (the daily run), not just 'are you "
                      + "sure': \(p.title)")
        XCTAssertTrue(p.confirm.lowercased().contains("delete"),
                      "the destructive button must read as destructive: \(p.confirm)")
    }

    /// A publishing subscription is the one the home screen depends on. Deleting
    /// it silently ends the morning card too — the sentence the user reads
    /// before tapping is the only place that can say so.
    func testU3_deletingAPublishingSubscriptionWarnsTheHomeCardStopsToo() {
        let plain = prompt(.schedule(id: "sched-1", publishes: false))
        let publishing = prompt(.schedule(id: "sched-1", publishes: true))

        XCTAssertNotEqual(publishing.title, plain.title,
                          "deleting a 刊物 costs the user their home card as well as the run; "
                          + "the same sentence for both hides that")
        XCTAssertTrue(publishing.title.lowercased().contains("home")
                        || publishing.title.contains("首页"),
                      "the warning never mentions the home card: \(publishing.title)")
    }

    /// Two destructive verbs live on this screen and they lose different things.
    /// One shared sentence is how a user deletes a subscription believing they
    /// were tidying up an old run.
    func testU3_theRunAndSubscriptionPromptsCantBeMistakenForEachOther() {
        let run = prompt(.run("wf-aaa"))
        let sub = prompt(.schedule(id: "sched-1", publishes: true))

        XCTAssertNotEqual(run.title, sub.title)
        XCTAssertNotEqual(run.confirm, sub.confirm)
        XCTAssertTrue(run.title.lowercased().contains("run"),
                      "the run prompt has to name a run: \(run.title)")
        XCTAssertFalse(run.title.lowercased().contains("daily"),
                       "deleting one past run must not read as stopping the daily job — the "
                       + "user would keep the run and lose the subscription: \(run.title)")
    }
}
