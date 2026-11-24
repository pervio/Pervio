import XCTest
@testable import Pervio

/// B1: this is the path where one tap on the phone runs a command on the user's
/// machine. Claude blocks mid-turn, the sheet comes up, and Allow puts a
/// decision on the wire that unblocks a `Bash`/`Edit` the user may never see
/// again. It had ZERO tests — not the routing, not the double tap, not the
/// queue, not what happens when the decision fails to send.
///
/// Everything here drives the real `ChatStore` through the existing `FakeSSH`
/// seam: the permission events arrive on the stream exactly as `pervio-approve`
/// tees them, and the assertions are on what left the phone (`sid`, `requestId`,
/// behavior, message) — not on internal state.
@MainActor
final class PermissionApprovalTests: XCTestCase {

    // MARK: helpers

    private func makeStore(_ fake: FakeSSH, resume: String? = nil) -> ChatStore {
        ChatStore(profile: TestFactory.profile(), secret: "secret",
                  resumeSessionId: resume, ssh: fake)
    }

    /// The incidental calls a finished turn makes (usage / context refresh).
    private func background(_ fake: FakeSSH) {
        fake.script("pervio-sessions usage", "{}")
        fake.script("pervio-sessions context", "{}")
    }

    private func bash(_ command: String, id: String) -> ToolCall {
        ToolCall(name: "Bash", label: "Bash  \(command)", filePath: nil,
                 oldString: nil, newString: nil, content: nil, command: command, toolUseId: id)
    }

    private func doneEvent() -> AgentEvent {
        .result(text: "done", sessionId: "sess-1", costUSD: nil, isError: false, contextWindow: nil)
    }

    /// Run one turn that blocks on `requests`, stopping just before the result so
    /// the turn is still live (Claude really is stalled on the user at this point).
    private func turnBlocked(on requests: [(String, ToolCall)],
                             fake: FakeSSH) async -> ChatStore {
        background(fake)
        fake.chatEvents(requests.map { .permissionRequest(requestId: $0.0, call: $0.1) }
                        + [doneEvent()])
        fake.pauseChat(before: requests.count)     // …just before the result lands
        let store = makeStore(fake)
        await store.connect()
        store.submit("clean up the build directory")
        await fake.awaitChatPaused()
        await TestFactory.settle()
        return store
    }

    /// Let the held turn finish so the fake's stream task never outlives the test.
    private func finish(_ fake: FakeSSH) async {
        fake.releaseChat()
        await TestFactory.settle()
    }

    // MARK: - Allow

    /// Allow must put exactly ONE decision on the wire, carrying this turn's
    /// approval nonce and the blocked tool's id. A decision that goes out under
    /// the wrong sid reaches a FIFO nobody is reading (the tool stays blocked
    /// until the turn times out); under the wrong requestId it unblocks a
    /// different tool than the one the user just read.
    func testB1_allowSendsOneDecisionRoutedToThisTurnsBlockedTool() async {
        let fake = FakeSSH()
        let store = await turnBlocked(on: [("toolu_01", bash("rm -rf ~/work/build", id: "toolu_01"))],
                                      fake: fake)

        XCTAssertEqual(store.pendingPermission?.requestId, "toolu_01",
                       "the blocked tool never reached the sheet: \(fake.calls)")
        XCTAssertEqual(store.pendingPermission?.call.command, "rm -rf ~/work/build",
                       "the sheet must show the command that is about to run")

        store.allowTool()
        await TestFactory.settle()

        let sid = fake.chatApproveSids.first ?? nil
        XCTAssertNotNil(sid, "the turn went out without an approval nonce")
        XCTAssertEqual(fake.permissionAnswers,
                       [FakeSSH.PermissionAnswer(sid: sid ?? "", requestId: "toolu_01",
                                                 behavior: "allow", message: nil)],
                       "the Allow decision did not reach the server as one 'allow' for "
                       + "THIS turn's blocked tool")
        XCTAssertNil(store.pendingPermission, "the sheet must close once answered")
        await finish(fake)
    }

    /// The sheet's button can fire twice (a double tap, or SwiftUI re-invoking
    /// the action before the sheet dismisses). The second one must not send a
    /// second decision: `respond` writes to a one-shot FIFO, and a stray extra
    /// answer lands on the NEXT tool the turn blocks on — approving something
    /// the user never saw.
    func testB1_tappingAllowTwiceStillSendsOnlyOneDecision() async {
        let fake = FakeSSH()
        let store = await turnBlocked(on: [("toolu_01", bash("git push --force", id: "toolu_01"))],
                                      fake: fake)

        store.allowTool()
        store.allowTool()
        await TestFactory.settle()

        XCTAssertEqual(fake.permissionAnswers.count, 1,
                       "a double tap sent \(fake.permissionAnswers.count) decisions — the extra "
                       + "one is waiting in the FIFO to auto-approve whatever blocks next")
        XCTAssertEqual(fake.permissionAnswers.first?.requestId, "toolu_01")
        await finish(fake)
    }

    // MARK: - Deny

    /// Deny carries the reason the user typed (trimmed) — Claude reads it and
    /// changes approach. A blank box is NOT a reason and must not be sent as an
    /// empty message.
    func testB1_denyCarriesTheTypedReasonAndABlankBoxIsNotOne() async {
        let fake = FakeSSH()
        let store = await turnBlocked(on: [("toolu_01", bash("psql prod -c 'drop table'", id: "toolu_01")),
                                           ("toolu_02", bash("rm -rf /", id: "toolu_02"))],
                                      fake: fake)

        store.denyTool(message: "  别动生产库  ")
        await TestFactory.settle()
        XCTAssertEqual(store.pendingPermission?.requestId, "toolu_02",
                       "the second blocked tool must take the sheet once the first is answered")

        store.denyTool(message: "   ")
        await TestFactory.settle()

        XCTAssertEqual(fake.permissionAnswers.map(\.behavior), ["deny", "deny"])
        XCTAssertEqual(fake.permissionAnswers.first?.message, "别动生产库",
                       "the reason the user typed was dropped (or sent with its whitespace)")
        XCTAssertNil(fake.permissionAnswers.last?.message,
                     "an empty reason box was sent as a message — Claude reads it as a "
                     + "blank instruction instead of a plain denial")
        await finish(fake)
    }

    // MARK: - The queue

    /// Claude can block on several tools in one turn. Each has its own waiter on
    /// the server; the single sheet slot used to be OVERWRITTEN by the newest, so
    /// the earlier ones could never be answered and their waiters blocked until
    /// the whole turn timed out. Every request must surface, in arrival order,
    /// and every one must get its own answer.
    func testB1_severalBlockedToolsEachSurfaceInOrderAndEachGetsAnswered() async {
        let fake = FakeSSH()
        let store = await turnBlocked(on: [("toolu_01", bash("npm install", id: "toolu_01")),
                                           ("toolu_02", bash("rm -rf node_modules", id: "toolu_02")),
                                           ("toolu_03", bash("git clean -fdx", id: "toolu_03"))],
                                      fake: fake)

        XCTAssertEqual(store.pendingPermission?.requestId, "toolu_01",
                       "the FIRST request must hold the sheet, not the newest")
        store.allowTool()
        await TestFactory.settle()
        XCTAssertEqual(store.pendingPermission?.requestId, "toolu_02")
        store.denyTool(message: "keep the deps")
        await TestFactory.settle()
        XCTAssertEqual(store.pendingPermission?.requestId, "toolu_03")
        store.allowTool()
        await TestFactory.settle()

        XCTAssertNil(store.pendingPermission, "nothing left to answer, so no sheet")
        XCTAssertEqual(fake.permissionAnswers.map { "\($0.requestId):\($0.behavior)" },
                       ["toolu_01:allow", "toolu_02:deny", "toolu_03:allow"],
                       "a blocked tool went unanswered (its server-side waiter then holds "
                       + "the turn until it times out) or was answered out of order")
        await finish(fake)
    }

    // MARK: - Lifecycle

    /// When the turn ends, Claude is no longer waiting for anything. A sheet
    /// left standing would send a decision into a FIFO nobody reads — and the
    /// user would believe they had just allowed something.
    func testB1_aTurnThatEndsClearsUnansweredRequestsAndALateTapSendsNothing() async {
        let fake = FakeSSH()
        background(fake)
        fake.chatEvents([.permissionRequest(requestId: "toolu_01",
                                            call: bash("terraform apply", id: "toolu_01")),
                         doneEvent()])
        let store = makeStore(fake)
        await store.connect()
        store.submit("ship it")
        await TestFactory.settle()

        XCTAssertNil(store.pendingPermission,
                     "the turn is over but the permission sheet is still up")
        XCTAssertEqual(fake.permissionAnswers, [], "nothing was answered, so nothing was sent")

        store.allowTool()          // the user taps the sheet as it disappears
        await TestFactory.settle()
        XCTAssertEqual(fake.permissionAnswers, [],
                       "a tap after the turn ended still sent a decision — it can only be "
                       + "read by the NEXT turn, approving something unseen")
    }

    /// Switching conversations must not carry a pending approval across. The
    /// decision belongs to a turn in the chat you left; answering it from the
    /// new one sends it under a nonce that has nothing to do with what's on
    /// screen.
    func testB1_openingAnotherConversationDropsThePendingApproval() async {
        let fake = FakeSSH()
        fake.script("transcript --dir '/srv/proj' --session 'sess-B'",
                    TestFactory.transcriptJSON([("user", "B: 另一段对话")]))
        let store = await turnBlocked(on: [("toolu_01", bash("rm -rf ~/Documents", id: "toolu_01"))],
                                      fake: fake)
        XCTAssertNotNil(store.pendingPermission, "precondition: the sheet is up")

        await store.open(sessionId: "sess-B")

        XCTAssertNil(store.pendingPermission,
                     "the approval from the conversation you LEFT is still on screen over "
                     + "the one you opened")
        store.allowTool()
        await TestFactory.settle()
        XCTAssertEqual(fake.permissionAnswers, [],
                       "a decision from the previous conversation was sent from this one")
        await finish(fake)
    }

    /// Same for starting a fresh chat.
    func testB1_startingANewChatDropsThePendingApproval() async {
        let fake = FakeSSH()
        let store = await turnBlocked(on: [("toolu_01", bash("shutdown -h now", id: "toolu_01"))],
                                      fake: fake)
        XCTAssertNotNil(store.pendingPermission, "precondition: the sheet is up")

        store.reset()

        XCTAssertNil(store.pendingPermission, "a new chat opened with the old chat's sheet up")
        store.allowTool()
        await TestFactory.settle()
        XCTAssertEqual(fake.permissionAnswers, [],
                       "the new chat sent the old chat's decision")
        await finish(fake)
    }

    /// The failure the user cannot see: the decision leaves the sheet but never
    /// reaches the server (mobile SSH drops). The tool is still blocked. If this
    /// is swallowed, the user watches a turn hang forever believing they
    /// answered it — so the request has to come BACK, with a line saying so.
    func testB1_aDecisionThatFailsToSendIsSurfacedAndTheRequestComesBack() async {
        let fake = FakeSSH()
        let store = await turnBlocked(on: [("toolu_01", bash("kubectl delete ns prod", id: "toolu_01"))],
                                      fake: fake)
        fake.respondPermissionError = FakeSSH.Boom(message: "connection reset")

        store.allowTool()
        await TestFactory.settle()

        XCTAssertEqual(fake.permissionAnswers, [], "precondition: the send really failed")
        XCTAssertEqual(store.pendingPermission?.requestId, "toolu_01",
                       "the decision never reached the server and the sheet is gone — the "
                       + "tool is still blocked and the user has no way to answer again")
        XCTAssertTrue(store.messages.contains { $0.role == .system && $0.text.contains("⚠️") },
                      "…and nothing told them: \(store.messages.map(\.text))")

        // Retrying after the blip must then work, once.
        fake.respondPermissionError = nil
        store.allowTool()
        await TestFactory.settle()
        XCTAssertEqual(fake.permissionAnswers.map(\.requestId), ["toolu_01"],
                       "the retry did not go through")
        await finish(fake)
    }
}
