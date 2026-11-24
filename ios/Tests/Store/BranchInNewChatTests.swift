import XCTest
@testable import Pervio

/// 「分支到新对话」(2026-10-16): a reply's anchor is the typed message that
/// started its turn, the fork is asked THROUGH that turn (`--after`), the view
/// switches to the branch, Codex rows get their anchors from `user-turns`,
/// and Cursor (no forkable store yet) offers nothing.
@MainActor
final class BranchInNewChatTests: XCTestCase {
    private func store(_ backend: AgentBackend, fake: FakeSSH) -> ChatStore {
        var p = TestFactory.profile(); p.backend = backend
        let s = ChatStore(profile: p, secret: "s", resumeSessionId: "sid-orig", ssh: fake)
        var u1 = ChatMessage.user("第一句"); u1.serverUuid = "u1"
        let a1 = ChatMessage(role: .assistant, text: "答一")
        var u2 = ChatMessage.user("第二句"); u2.serverUuid = "u2"
        let a2 = ChatMessage(role: .assistant, text: "答二")
        s.messages = [u1, a1, u2, a2]
        return s
    }

    func testTheAnchorIsTheTypedMessageThatStartedTheTurn() {
        let s = store(.claude, fake: FakeSSH())
        XCTAssertEqual(s.branchAnchorUuid(for: s.messages[1]), "u1", "a reply branches through its own turn")
        XCTAssertEqual(s.branchAnchorUuid(for: s.messages[3]), "u2")
        XCTAssertEqual(s.branchAnchorUuid(for: s.messages[2]), "u2", "a typed message is its own anchor")
        var streaming = s.messages[3]; streaming.isStreaming = true; s.messages[3] = streaming
        XCTAssertNil(s.branchAnchorUuid(for: s.messages[3]), "not while the reply is still being written")
        let cursor = store(.cursor, fake: FakeSSH())
        XCTAssertNil(cursor.branchAnchorUuid(for: cursor.messages[1]), "Cursor threads cannot be forked yet")
        let codex = store(.codex, fake: FakeSSH())
        XCTAssertEqual(codex.branchAnchorUuid(for: codex.messages[1]), "u1", "Codex threads fork too")
    }

    /// One button per finished turn: a Codex turn's progress bubbles are
    /// mid-turn, the running turn's last bubble is not yet an end.
    func testOnlyTheLastReplyOfAFinishedTurnIsATurnEnd() {
        let s = store(.codex, fake: FakeSSH())
        let p1 = ChatMessage(role: .assistant, text: "进展一"), p2 = ChatMessage(role: .assistant, text: "进展二")
        s.messages = [s.messages[0], p1, p2, s.messages[2], s.messages[3]]
        XCTAssertTrue(s.isTurnEnd(s.messages[0]), "a typed message starts its own turn")
        XCTAssertFalse(s.isTurnEnd(s.messages[1]), "a progress bubble followed by another reply is mid-turn")
        XCTAssertTrue(s.isTurnEnd(s.messages[2]), "the last reply before the next typed message")
        XCTAssertTrue(s.isTurnEnd(s.messages[4]), "the final reply of a finished conversation")
        s.isBusy = true
        XCTAssertFalse(s.isTurnEnd(s.messages[4]), "not while the turn is still running")
        s.isBusy = false
        var streaming = s.messages[4]; streaming.isStreaming = true; s.messages[4] = streaming
        XCTAssertFalse(s.isTurnEnd(s.messages[4]))
    }

    func testBranchForksAfterTheAnchorAndSwitchesToTheNewConversation() async {
        let fake = FakeSSH()
        fake.script("pervio-sessions usage", "{}")
        fake.script("pervio-sessions context", "{}")
        fake.script("transcript", TestFactory.transcriptJSON([("user", "第一句"), ("assistant", "答一")]))
        fake.forkedSessionId = "sid-branch"
        let s = store(.claude, fake: fake)
        await s.connect()
        let ok = await s.branchFork(afterUuid: "u1")
        XCTAssertTrue(ok)
        XCTAssertTrue(fake.calls.contains("forkSession after u1"), "\(fake.calls)")
        XCTAssertEqual(s.sessionId, "sid-branch", "the screen now shows the branch")
        XCTAssertTrue(s.messages.contains { $0.role == .system && $0.text == L.branchedHere() })
    }

    func testCodexRowsGetTheirAnchorsFromUserTurns() async {
        let fake = FakeSSH()
        fake.userUuids = [.init(uuid: "msg_u1", text: "第一句"), .init(uuid: "msg_u2", text: "第二句")]
        let s = store(.codex, fake: fake)
        s.messages[0].serverUuid = nil; s.messages[2].serverUuid = nil
        await s.refreshUserUuidsForTesting()
        XCTAssertTrue(fake.calls.contains("codexUserTurns sid-orig"), "\(fake.calls)")
        XCTAssertEqual(s.messages[0].serverUuid, "msg_u1")
        XCTAssertEqual(s.messages[2].serverUuid, "msg_u2")
    }
}
