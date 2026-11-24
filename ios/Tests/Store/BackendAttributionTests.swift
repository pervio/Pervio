import XCTest
@testable import Pervio

/// The reported bug: a codex conversation showing up as claude (or the other way
/// around). Two attribution surfaces are pinned here:
///  * the header usage line: the 5h/7d/scoped percentages come from CLAUDE's
///    OAuth quota endpoint (`pervio-sessions usage`) — they must never label a
///    codex conversation as if they were its own;
///  * the history-drawer switch: opening another conversation must adopt THAT
///    conversation's backend (header icon/title, `transcript --backend` route,
///    and the next send), exactly like SessionsView.resumeProfile already does
///    for the sessions-list route. Before the fix, ChatView.switchTo passed only
///    the id, so a codex conversation opened from the drawer kept the claude
///    profile: claude icon, claude quota line, an EMPTY transcript (wrong store),
///    and a send would have gone to `claude --resume <codex-thread-id>`.
@MainActor
final class BackendAttributionTests: XCTestCase {

    /// Same shape as ios/Tests/Fixtures/usage.json (what the endpoint answers).
    private static let usageJSON = #"{"five_hour": {"utilization": 37.5, "#
        + #""resets_at": "2026-08-01T12:00:00Z"}, "seven_day": {"utilization": 51.0, "#
        + #""resets_at": "2026-08-05T00:00:00Z"}}"#

    /// What `usage --backend codex` answers: codex's plan window, read out of its
    /// own rollout. A codex conversation now HAS a usage line — of its own pool.
    private static let codexUsageJSON =
        #"{"weekly": {"utilization": 23.0, "resets_at": "2026-08-14T09:10:48Z"}, "plan": "plus"}"#

    private func scriptCommon(_ fake: FakeSSH) {
        fake.script("pervio-sessions usage", Self.usageJSON)
        fake.script("usage --backend codex", Self.codexUsageJSON)   // more specific route wins
        fake.script("context --dir", #"{"used": 1234, "model": "claude-fable-5"}"#)
    }

    func testClaudeQuotaDoesNotLabelACodexConversation() async {
        let fake = FakeSSH()
        scriptCommon(fake)
        var p = TestFactory.profile()
        p.backend = .codex
        let store = ChatStore(profile: p, secret: "s", resumeSessionId: nil, ssh: fake)
        await store.start()
        XCTAssertNil(store.usage?.fiveHour,
                     "the 5h/7d usage line is Claude's OAuth quota — showing it on a codex "
                     + "conversation attributes claude usage to a codex session")
        XCTAssertNil(store.usage?.sevenDay, "same pool, same lie")
        XCTAssertEqual(store.usage?.weekly?.utilization, 23.0,
                       "…and the line the codex conversation DOES show is codex's own "
                       + "weekly window (see CodexUsagePoolTests)")
    }

    func testDrawerSwitchToACodexConversationAdoptsItsBackend() async {
        let fake = FakeSSH()
        scriptCommon(fake)
        fake.script("transcript --dir '/srv/proj' --session 'claude-A'",
                    TestFactory.transcriptJSON([("user", "hi"), ("assistant", "yo")]))
        fake.script("--session 'codex-1'",
                    TestFactory.transcriptJSON([("user", "codex q"), ("assistant", "codex a")]))
        let store = ChatStore(profile: TestFactory.profile(), secret: "s",
                              resumeSessionId: "claude-A", ssh: fake)
        await store.start()
        XCTAssertEqual(store.profile.backend, .claude, "precondition")
        XCTAssertNotNil(store.usage, "precondition: a claude conversation shows the quota line")

        // Mirrors ChatView.switchTo — the drawer row (SessionSummary) knows which
        // agent ran the conversation being opened, and passes it along.
        await store.open(sessionId: "codex-1", backend: .codex)

        XCTAssertEqual(store.profile.backend, .codex,
                       "the opened conversation is codex — keeping the old backend shows the "
                       + "claude icon/title on it, and the next send would resume it via claude")
        let codexLoads = fake.commandCalls(containing: "--session 'codex-1'")
            .filter { $0.contains(" transcript ") }
        XCTAssertFalse(codexLoads.isEmpty, "the switch must load the opened transcript")
        XCTAssertTrue(codexLoads.allSatisfy { $0.contains("--backend codex") },
                      "codex transcripts live in ~/.codex/sessions — without --backend codex "
                      + "the reload comes back empty: \(codexLoads)")
        XCTAssertNil(store.usage?.fiveHour,
                     "the claude quota line must drop with the backend switch")
        XCTAssertNil(store.usage?.sevenDay)
        XCTAssertTrue(store.modelName.isEmpty,
                      "the left backend's model name must not title the codex conversation, "
                      + "got: \(store.modelName)")
    }

    func testDrawerSwitchBackToAClaudeConversationRestoresClaudeAttribution() async {
        let fake = FakeSSH()
        scriptCommon(fake)
        fake.script("--session 'claude-B'",
                    TestFactory.transcriptJSON([("user", "b"), ("assistant", "bb")]))
        var p = TestFactory.profile()
        p.backend = .codex
        let store = ChatStore(profile: p, secret: "s", resumeSessionId: nil, ssh: fake)
        await store.start()

        await store.open(sessionId: "claude-B", backend: .claude)

        XCTAssertEqual(store.profile.backend, .claude,
                       "vice-versa: a claude conversation opened from a codex chat must not "
                       + "keep showing as codex")
        XCTAssertNotNil(store.usage?.fiveHour, "back on claude, its own quota line returns")
        XCTAssertNil(store.usage?.weekly, "…and codex's weekly window leaves with the switch")
    }
}
