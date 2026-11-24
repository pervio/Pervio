import XCTest
import SwiftUI
@testable import Pervio

/// The home page's "N 个在跑" line counts BOTH running workflows and running
/// detached runs (pervio-run's background sessions). The bug this suite pins: the
/// row used to route every tap to `WorkflowsView`, which lists workflows ONLY —
/// so when the thing running was a detached run and NOT a workflow, tapping the
/// row opened an empty Workflows list and the run was a dead end. User words:
/// "从运行中点进去 好像永远只是 wf 页面？这里很奇怪 不只是 wf 结果会在".
///
/// The fix reuses the pill's own list (`RunListView`, driven by a `RunMonitor`),
/// which lists running workflows AND detached conversations side by side, so the
/// tap target now contains whatever the count counted. These tests assert the
/// data contract that makes the fix correct: the same `RunMonitor` the row shows
/// its count from is the one the sheet lists, so a counted run is always a run
/// you can reach.
@MainActor
final class HomeRunningRowTests: XCTestCase {

    /// A running detached run (no workflow), decoded the way `pervio-run list`
    /// delivers it — one running record plus a finished one for the same session.
    private func detachedRunOnly() throws -> [RunInfo] {
        let json = """
        [{"runId":"r-live","sessionId":"sess-A","dir":"~/proj","preview":"跑一遍回归测试",
          "started":1785567600,"state":"running","bytes":182,"backend":"codex"}]
        """
        return try SSHService.decodeRuns(json)
    }

    // MARK: - RED-first: the detached-run-only case

    /// The scenario the old wiring got wrong: the ONLY thing running is a detached
    /// run, and there are ZERO workflows. The row is visible (count ≥ 1), and the
    /// list the row opens surfaces that run — where a WorkflowsView-based route
    /// (workflows only, and there are none) would have shown nothing.
    func testDetachedRunOnly_isReachableFromRunningRow() throws {
        let monitor = RunMonitor(previewProfile: TestFactory.profile(),
                                 runs: try detachedRunOnly(),
                                 workflows: [])          // no workflows at all

        // 1) The row shows itself: count = runs + workflows the pill/row reports.
        let count = monitor.running.count + monitor.runningWorkflows.count
        XCTAssertEqual(count, 1, "one detached run is live, so the row must appear")

        // 2) THE BUG, encoded as a contract: what the tap opens must contain that
        //    run. RunListView lists `conversations` (+ running workflows); the old
        //    WorkflowsView route would list only workflows — empty here — so the
        //    run had no home. Prove the run is in the list's own data source.
        //    (RED-verified: asserting the run is reachable through the WORKFLOW-only
        //    set — `monitor.runningWorkflows`, all WorkflowsView could show — fails
        //    with "[] is not equal to [r-live]", which is the dead end the user hit.)
        XCTAssertEqual(monitor.conversations.map(\.runId), ["r-live"],
                       "the running detached run must be listed by what the row now opens; "
                       + "routing to WorkflowsView (workflows only) hid it entirely")
        XCTAssertTrue(monitor.runningWorkflows.isEmpty,
                      "no workflows exist — a WorkflowsView route would have been empty, "
                      + "which is exactly the dead end the user hit")

        // The reattach handle survives: RunListView resumes the chat on this
        // session id, so the tap genuinely walks back into the live run.
        XCTAssertEqual(monitor.conversations.first?.sessionId, "sess-A")
        XCTAssertTrue(monitor.conversations.first?.isRunning == true)
    }

    /// A group's member runs fold behind ONE group row (like a workflow) when the
    /// group's record is known — the user saw one round as three rows titled
    /// with the raw hidden header. A run whose group record is gone still lists,
    /// so nothing the count promised is unreachable.
    func testGroupRunsFoldBehindOneGroupRow() throws {
        let json = """
        [{"runId":"r-p","sessionId":"sess-P","dir":"~/proj","preview":"<pervio-group id=\\"g1\\" from=\\"human\\" role=\\"主对话\\" round=\\"1\\" to=\\"p\\">\\n规则\\n</pervio-group>\\n这题怎么解","started":1785567600,"state":"running","bytes":1,"backend":"claude","group":"g1"},
         {"runId":"r-m","sessionId":"sess-M","dir":"~/proj","preview":"这题怎么解","started":1785567601,"state":"running","bytes":1,"backend":"codex","group":"g1"},
         {"runId":"r-x","sessionId":"sess-X","dir":"~/proj","preview":"孤儿","started":1785567602,"state":"running","bytes":1,"backend":"codex","group":"gone"}]
        """
        let runs = try SSHService.decodeRuns(json)
        let gjson = """
        {"id":"g1","dir":"~/proj","mode":"parallel","autoSynth":true,"maxRounds":5,"primary":{"session":"sess-P","backend":"claude"},
         "members":[{"session":"sess-M","backend":"codex"}],"createdAt":1,"round":{"n":1,"state":"answering","text":"这题怎么解","runs":{"p":"r-p","m0":"r-m"},"answers":{},"synthRun":"","synth":"","relayRuns":{}}}
        """
        let g = try JSONDecoder().decode(ChatGroup.self, from: Data(gjson.utf8))
        let monitor = RunMonitor(previewProfile: TestFactory.profile(), runs: runs, workflows: [], groups: [g])
        XCTAssertEqual(monitor.runningUnits, 2, "g1 counts once, the orphan once")
        XCTAssertEqual(monitor.runningGroups.map(\.id), ["g1"])
        XCTAssertEqual(monitor.conversationsOutsideGroups.map(\.runId), ["r-x"],
                       "member runs hide behind the group row; the orphan stays reachable")
        XCTAssertEqual(runs.first { $0.runId == "r-p" }?.title, "这题怎么解", "an old run's title drops the hidden header")
    }

    /// The mixed case still holds: one running workflow AND one running run → the
    /// count is 2 and BOTH appear in the list the row opens (workflows section +
    /// the conversation row), so nothing the count promised is missing.
    func testWorkflowAndRunTogether_bothReachable() throws {
        let wf = FakeSSH.workflowRow(wfId: "wf-live", name: "晨报", status: "running")
        let monitor = RunMonitor(previewProfile: TestFactory.profile(),
                                 runs: try detachedRunOnly(),
                                 workflows: [wf])

        XCTAssertEqual(monitor.running.count + monitor.runningWorkflows.count, 2)
        XCTAssertEqual(monitor.runningWorkflows.map(\.wfId), ["wf-live"])
        XCTAssertEqual(monitor.running.map(\.runId), ["r-live"])
    }

    /// Nothing running → the row hides (count 0), same resting state as before.
    func testNothingRunning_rowHides() {
        let monitor = RunMonitor(previewProfile: TestFactory.profile(),
                                 runs: [], workflows: [])
        XCTAssertEqual(monitor.running.count + monitor.runningWorkflows.count, 0)
    }
}
