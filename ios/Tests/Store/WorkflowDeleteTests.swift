import XCTest
@testable import Pervio

/// B2: deleting a workflow is optimistic — the row leaves the list the instant
/// you swipe, and the server is told afterwards. That is the right feel and the
/// wrong failure mode: when the server refuses (or the channel drops), the phone
/// has already shown the user that it is gone.
///
/// The server's real behaviour makes it worse than a stale row. `pervio-orchestrate
/// delete` can exit non-zero having ALREADY dropped the run from `list` (verified
/// server-side, 2026-08-07) — so the reconciling reload comes back WITHOUT the row
/// too. The phone then agrees with itself: gone from the screen, still on disk on
/// the server. The only thing standing between the user and that lie is the error
/// line, and these tests are about the error line surviving the reload.
@MainActor
final class WorkflowDeleteTests: XCTestCase {

    private func makeStore(_ fake: FakeSSH) -> WorkflowListStore {
        WorkflowListStore(profile: TestFactory.profile(), secret: "secret", ssh: fake)
    }

    private func loaded(_ fake: FakeSSH) async -> WorkflowListStore {
        fake.workflows = [FakeSSH.workflowRow(wfId: "wf-aaa", name: "daily report"),
                          FakeSSH.workflowRow(wfId: "wf-bbb", name: "arxiv digest")]
        let store = makeStore(fake)
        await store.load()
        XCTAssertEqual(store.items.map(\.wfId), ["wf-aaa", "wf-bbb"],
                       "precondition: the list loaded")
        return store
    }

    /// The happy path, so the failure paths below can't pass by never deleting
    /// anything.
    func testB2_aDeleteThatSucceedsRemovesTheRowAndReachesTheServer() async {
        let fake = FakeSSH()
        let store = await loaded(fake)

        await store.delete("wf-aaa")

        XCTAssertEqual(fake.deletedWorkflows, ["wf-aaa"],
                       "the delete never reached the server: \(fake.calls)")
        XCTAssertEqual(store.items.map(\.wfId), ["wf-bbb"])
        XCTAssertNil(store.errorText, "a successful delete must not leave an error on screen")
    }

    /// The plain failure: the server refused and still lists the workflow. The
    /// row has to come back AND the user has to be told why it came back.
    func testB2_aFailedDeleteRestoresTheRowAndSaysWhy() async {
        let fake = FakeSSH()
        let store = await loaded(fake)
        fake.deleteWorkflowError = SSHService.ConnectionError(message: "delete: permission denied")

        await store.delete("wf-aaa")

        XCTAssertEqual(store.items.map(\.wfId), ["wf-aaa", "wf-bbb"],
                       "the workflow is still on the server but the phone kept it hidden")
        XCTAssertEqual(store.errorText, "delete: permission denied",
                       "the delete failed and the reconciling reload wiped the reason — the "
                       + "row reappearing with no explanation reads as a UI glitch, and the "
                       + "user swipes again instead of looking at the server")
    }

    /// The one measured server-side: delete exits non-zero, and `list` has
    /// already stopped showing the run. Nothing on screen changes when the
    /// reload lands, so the error line is the ONLY evidence the user ever gets
    /// that the thing they deleted is still there.
    func testB2_aFailedDeleteWhoseListingAlreadyDroppedTheRowStillReportsIt() async {
        let fake = FakeSSH()
        let store = await loaded(fake)
        fake.deleteWorkflowError = SSHService.ConnectionError(message: "delete: rm failed (exit 1)")
        fake.workflows = [FakeSSH.workflowRow(wfId: "wf-bbb", name: "arxiv digest")]

        await store.delete("wf-aaa")

        XCTAssertEqual(store.items.map(\.wfId), ["wf-bbb"],
                       "precondition: the server's own listing no longer shows it either")
        XCTAssertEqual(store.errorText, "delete: rm failed (exit 1)",
                       "the delete FAILED and the phone showed the user a clean disappearance: "
                       + "no row, no error. The workflow is still on the server.")
    }

    /// Same swallow, same file, one row down: removing a schedule is the other
    /// destructive button on this screen (it stops a daily job the user is
    /// paying for — or fails to, silently).
    func testB2_aFailedScheduleRemovalSaysWhy() async {
        let fake = FakeSSH()
        fake.schedules = [FakeSSH.scheduleRow(id: "sched-1", name: "morning", time: "06:30")]
        let store = makeStore(fake)
        await store.load()
        XCTAssertEqual(store.schedules.map(\.id), ["sched-1"], "precondition: it's listed")
        fake.removeScheduleError = SSHService.ConnectionError(message: "schedule remove: not found")

        await store.removeSchedule("sched-1")

        XCTAssertEqual(store.schedules.map(\.id), ["sched-1"],
                       "the schedule is still armed on the server — it must come back on screen")
        XCTAssertEqual(store.errorText, "schedule remove: not found",
                       "the removal failed and the reload erased the reason: the user watches "
                       + "the row return with no explanation and assumes a redraw glitch")
    }

    /// And the switch: a disable that never reached the server must not end up
    /// looking like a successful disable. The daily run keeps firing (and keeps
    /// spending) until someone notices.
    func testB2_aFailedScheduleDisableSaysWhy() async {
        let fake = FakeSSH()
        fake.schedules = [FakeSSH.scheduleRow(id: "sched-1", name: "morning", time: "06:30")]
        let store = makeStore(fake)
        await store.load()
        fake.setScheduleEnabledError = SSHService.ConnectionError(message: "schedule disable: refused")

        await store.setScheduleEnabled("sched-1", false)

        XCTAssertTrue(store.schedules.first?.enabled == true,
                      "the server still has it enabled, so the switch must snap back")
        XCTAssertEqual(store.errorText, "schedule disable: refused",
                       "the switch snapped back with no reason — indistinguishable from a "
                       + "mis-tap, so the user shrugs and the schedule keeps running")
    }
}
