import XCTest
@testable import Pervio

/// B1 (the other half): the plan sheet. "Proceed" does two things that cost the
/// user something real — it takes the agent OUT of plan mode into `acceptEdits`
/// (from then on Claude edits files without asking) and sends a go-ahead into
/// the same session. None of `approvePlan` / `refinePlan` / `dismissPlan` /
/// `reopenPlan` / the capture-then-surface rule had a test.
@MainActor
final class PlanApprovalTests: XCTestCase {

    private func makeStore(_ fake: FakeSSH, resume: String? = nil) -> ChatStore {
        ChatStore(profile: TestFactory.profile(), secret: "secret",
                  resumeSessionId: resume, ssh: fake)
    }

    private func background(_ fake: FakeSSH) {
        fake.script("pervio-sessions usage", "{}")
        fake.script("pervio-sessions context", "{}")
    }

    private func exitPlanMode(_ plan: String, id: String = "toolu_plan") -> ToolCall {
        ToolCall(name: "ExitPlanMode", label: "ExitPlanMode", filePath: nil,
                 oldString: nil, newString: nil, content: plan, command: nil, toolUseId: id)
    }

    private func doneEvent() -> AgentEvent {
        .result(text: "", sessionId: "sess-1", costUSD: nil, isError: false, contextWindow: nil)
    }

    private let plan = "1. 删掉旧分支\n2. force-push 到 main"

    /// The sheet must not pop the instant ExitPlanMode streams in — Claude is
    /// still talking, and a modal over a half-written plan is a decision made on
    /// partial information. It pops when the turn ends; approving it then flips
    /// the permission mode and sends the go-ahead.
    func testB1_aPlanSurfacesOnlyWhenTheTurnEndsAndApprovingItSendsTheGoAhead() async {
        let fake = FakeSSH()
        background(fake)
        fake.chatEvents([.toolUse(exitPlanMode(plan)), doneEvent()])
        fake.chatEvents([doneEvent()])          // the follow-up turn
        fake.pauseChat(before: 1)               // hold the turn open after the plan lands

        let store = makeStore(fake)
        await store.connect()
        store.submit("规划一下清理工作")
        await fake.awaitChatPaused()
        await TestFactory.settle()

        XCTAssertNil(store.pendingPlan,
                     "the plan sheet popped while the turn was still streaming")

        fake.releaseChat()
        await TestFactory.settle()
        XCTAssertEqual(store.pendingPlan?.plan, plan,
                       "the finished turn presented a plan and no sheet came up — the user "
                       + "has nothing to approve")
        XCTAssertEqual(store.profile.permissionMode, "auto",
                       "precondition: nothing has changed the permission mode yet")

        store.approvePlan()
        await TestFactory.settle()

        XCTAssertNil(store.pendingPlan, "the sheet must close on approval")
        XCTAssertEqual(store.profile.permissionMode, "acceptEdits",
                       "approving a plan must leave plan mode — otherwise the follow-up "
                       + "runs in plan mode again and nothing is ever implemented")
        XCTAssertEqual(fake.chatPrompts.count, 2,
                       "approving a plan must send the go-ahead turn: \(fake.chatPrompts)")
        XCTAssertEqual(fake.chatPrompts.last,
                       "The plan is approved — go ahead and implement it now.")
        XCTAssertEqual(fake.chatResumes.last ?? nil, "sess-1",
                       "the go-ahead must continue the SAME session — a fresh one has no "
                       + "plan in its context")
    }

    /// A stray tap when no plan is on screen must not switch the agent into
    /// acceptEdits, and must not send a turn saying a plan was approved.
    func testB1_approvingOrRefiningWithNoPlanOnScreenDoesNothing() async {
        let fake = FakeSSH()
        background(fake)
        let store = makeStore(fake)
        await store.connect()

        store.approvePlan()
        store.refinePlan("再想想")
        await TestFactory.settle()

        XCTAssertEqual(store.profile.permissionMode, "auto",
                       "a tap with no plan on screen took the agent out of its permission "
                       + "mode — every later edit then lands without asking")
        XCTAssertEqual(fake.chatPrompts, [],
                       "a turn was sent for a plan that does not exist: \(fake.chatPrompts)")
    }

    /// Keep-planning must put the agent BACK in plan mode (the whole point) and
    /// carry what the user typed; an empty box becomes the generic ask, not an
    /// empty message.
    ///
    /// It starts from `acceptEdits` on purpose — that is where an earlier
    /// "Proceed" left it, and reopening the chip to refine instead is exactly
    /// when this matters: a "revise the plan" turn sent in acceptEdits edits
    /// files instead of thinking.
    func testB1_refiningStaysInPlanModeAndCarriesTheFeedback() async {
        let fake = FakeSSH()
        background(fake)
        let store = makeStore(fake, resume: "sess-1")
        store.profile.permissionMode = "acceptEdits"
        await store.connect()

        store.reopenPlan(from: exitPlanMode(plan))
        await TestFactory.settle()
        XCTAssertEqual(store.pendingPlan?.plan, plan, "precondition: the sheet is up")

        store.refinePlan("  先加回滚步骤  ")
        await TestFactory.settle()

        XCTAssertNil(store.pendingPlan)
        XCTAssertEqual(store.profile.permissionMode, "plan",
                       "'keep refining' did not put the agent back in plan mode — the next "
                       + "turn starts editing files instead of revising the plan")
        XCTAssertEqual(fake.chatPrompts.last,
                       "Revise the plan with this feedback, then present it again:\n先加回滚步骤",
                       "the feedback the user typed did not reach the model verbatim")

        store.reopenPlan(from: exitPlanMode(plan))
        await TestFactory.settle()
        store.refinePlan("   ")
        await TestFactory.settle()
        XCTAssertEqual(fake.chatPrompts.last,
                       "Please keep refining the plan before implementing.",
                       "an empty feedback box was sent as an empty instruction")
    }

    /// "Later" closes the sheet and sends nothing at all.
    func testB1_dismissingAPlanSendsNothingAndLeavesTheModeAlone() async {
        let fake = FakeSSH()
        background(fake)
        let store = makeStore(fake, resume: "sess-1")
        await store.connect()
        store.reopenPlan(from: exitPlanMode(plan))
        await TestFactory.settle()
        XCTAssertNotNil(store.pendingPlan, "precondition: the sheet is up")

        store.dismissPlan()
        await TestFactory.settle()

        XCTAssertNil(store.pendingPlan)
        XCTAssertEqual(fake.chatPrompts, [], "'Later' sent a turn: \(fake.chatPrompts)")
        XCTAssertEqual(store.profile.permissionMode, "auto", "'Later' changed the permission mode")
    }

    /// A plan chip from HISTORY carries only its tool_use id (the transcript
    /// ships lightweight blocks), so reopening it has to fetch the text. If the
    /// fetch comes back empty the user must be told — not shown an empty sheet
    /// they might approve.
    func testB1_reopeningAHistoryPlanChipFetchesTheTextAndSaysSoWhenItCannot() async {
        let fake = FakeSSH()
        background(fake)
        fake.script("tool-detail --dir '/srv/proj' --session 'sess-1' --tool-id 'toolu_hist'",
                    #"{"content":"1. 迁移数据库\n2. 重启服务"}"#)
        fake.script("tool-detail --dir '/srv/proj' --session 'sess-1' --tool-id 'toolu_lost'",
                    #"{"content":""}"#)
        let store = makeStore(fake, resume: "sess-1")
        await store.connect()

        let historyChip = ToolCall(name: "ExitPlanMode", label: "ExitPlanMode", filePath: nil,
                                   oldString: nil, newString: nil, content: nil, command: nil,
                                   toolUseId: "toolu_hist")
        store.reopenPlan(from: historyChip)
        await TestFactory.settle()

        XCTAssertEqual(store.pendingPlan?.plan, "1. 迁移数据库\n2. 重启服务",
                       "tapping a plan chip from history did not reopen the plan")

        store.dismissPlan()
        let lostChip = ToolCall(name: "ExitPlanMode", label: "ExitPlanMode", filePath: nil,
                                oldString: nil, newString: nil, content: nil, command: nil,
                                toolUseId: "toolu_lost")
        store.reopenPlan(from: lostChip)
        await TestFactory.settle()

        XCTAssertNil(store.pendingPlan, "an EMPTY plan sheet came up — there is nothing to read "
                     + "and Proceed would still flip the permission mode")
        XCTAssertTrue(store.messages.contains { $0.role == .system && $0.text.contains("⚠️") },
                      "the plan could not be loaded and nothing said so: "
                      + "\(store.messages.map(\.text))")
    }
}
