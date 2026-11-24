import XCTest
@testable import Pervio

/// Codex conversations had no context ring on reopen and no usage line at all:
/// `pervio-sessions context` only understood Claude's session files, and the
/// usage line is Claude's OAuth quota, which ChatStore deliberately blanked on
/// codex rather than mislabel claude spend as codex spend.
///
/// Both numbers exist — in codex's own rollout, on every `token_count` line:
/// `info.last_token_usage.input_tokens` (+ the real `model_context_window`) for
/// the ring, and `rate_limits` (the codex plan's weekly window) for the line.
/// This suite pins that they arrive AND that the two backends' pools stay apart.
///
/// The separation is the point. A 5h/7d percentage shown on a codex chat is a
/// lie about which account is being spent, and it reads as truth — so the App
/// filters by backend itself instead of trusting whatever the server answered
/// (an older server still answers `usage` with claude's pools no matter which
/// conversation asked).
@MainActor
final class CodexUsagePoolTests: XCTestCase {

    /// What `pervio-sessions usage --backend codex` answers (shape pinned by
    /// server/tests/test_sessions.py against a real rollout's rate_limits).
    private static let codexUsageJSON =
        #"{"weekly": {"utilization": 23.0, "resets_at": "2026-08-14T09:10:48Z"}, "plan": "plus"}"#
    /// What `pervio-sessions usage` answers for claude (ios/Tests/Fixtures/usage.json).
    private static let claudeUsageJSON = #"{"five_hour": {"utilization": 37.5, "#
        + #""resets_at": "2026-08-01T12:00:00Z"}, "seven_day": {"utilization": 51.0, "#
        + #""resets_at": "2026-08-05T00:00:00Z"}, "scoped": [{"name": "Fable", "#
        + #""percent": 91.0, "resets_at": "2026-08-04T00:00:00Z", "severity": "critical"}]}"#
    /// What `context --backend codex` answers: the rollout's own numbers, window
    /// included (claude's transcript stores no window, so claude omits the field).
    private static let codexContextJSON =
        #"{"used": 12080, "model": "gpt-5.4-mini", "window": 258400}"#

    private func codexStore(_ fake: FakeSSH, resume: String? = "codex-thread-1") -> ChatStore {
        var p = TestFactory.profile()
        p.backend = .codex
        return ChatStore(profile: p, secret: "s", resumeSessionId: resume, ssh: fake)
    }

    // MARK: the codex usage line

    func testCodexConversationShowsItsOwnWeeklyPool() async {
        let fake = FakeSSH()
        fake.script("usage --backend codex", Self.codexUsageJSON)
        fake.script("context --dir", Self.codexContextJSON)
        fake.script("transcript --dir", TestFactory.transcriptJSON([("user", "hi")]))
        let store = codexStore(fake)
        await store.start()

        XCTAssertEqual(store.usage?.weekly?.utilization, 23.0,
                       "a codex conversation's usage line comes from codex's own rate_limits")
        XCTAssertEqual(store.usage?.weekly?.resetsAt, "2026-08-14T09:10:48Z")
        XCTAssertEqual(store.usage?.plan, "plus")
    }

    func testCodexUsageIsAskedForOnTheCodexRoute() async {
        let fake = FakeSSH()
        fake.script("usage --backend codex", Self.codexUsageJSON)
        fake.script("context --dir", Self.codexContextJSON)
        fake.script("transcript --dir", TestFactory.transcriptJSON([("user", "hi")]))
        let store = codexStore(fake)
        await store.start()

        let usageCalls = fake.commandCalls(containing: "pervio-sessions usage")
        XCTAssertFalse(usageCalls.isEmpty, "a codex conversation must still ask for a usage line")
        XCTAssertTrue(usageCalls.allSatisfy { $0.contains("--backend codex") },
                      "without --backend codex the server answers with CLAUDE's OAuth quota — "
                      + "the exact mislabeling this line must never do: \(usageCalls)")
    }

    // MARK: the wall between the two pools

    func testClaudePoolsNeverReachACodexConversation() async {
        let fake = FakeSSH()
        // An OLD server (or any server that ignores --backend) answers `usage`
        // with claude's pools whoever asked. The App must not paint them onto a
        // codex chat just because they decoded.
        fake.script("pervio-sessions usage", Self.claudeUsageJSON)
        fake.script("context --dir", Self.codexContextJSON)
        fake.script("transcript --dir", TestFactory.transcriptJSON([("user", "hi")]))
        let store = codexStore(fake)
        await store.start()

        XCTAssertNil(store.usage?.fiveHour,
                     "5h is CLAUDE's rolling window; on a codex conversation it attributes "
                     + "claude spend to a codex session")
        XCTAssertNil(store.usage?.sevenDay, "7d is claude's too")
        XCTAssertNil(store.usage?.scoped, "the model-scoped pools (e.g. Fable) are claude's too")
    }

    func testCodexPoolNeverReachesAClaudeConversation() async {
        let fake = FakeSSH()
        // The mirror image: a server answering with codex's weekly window on a
        // claude conversation must not label claude's quota with codex's number.
        fake.script("pervio-sessions usage", Self.codexUsageJSON)
        fake.script("context --dir", #"{"used": 1234, "model": "claude-fable-5"}"#)
        fake.script("transcript --dir", TestFactory.transcriptJSON([("user", "hi")]))
        let store = ChatStore(profile: TestFactory.profile(), secret: "s",
                              resumeSessionId: "claude-A", ssh: fake)
        await store.start()

        XCTAssertEqual(store.profile.backend, .claude, "precondition")
        XCTAssertNil(store.usage?.weekly,
                     "weekly is CODEX's plan window — showing it on a claude conversation is "
                     + "the same cross-pool lie in the other direction")
        XCTAssertNil(store.usage?.plan, "…and so is codex's plan name")
    }

    func testClaudeConversationStillShowsItsOwnPoolsUnchanged() async {
        let fake = FakeSSH()
        fake.script("pervio-sessions usage", Self.claudeUsageJSON)
        fake.script("context --dir", #"{"used": 1234, "model": "claude-fable-5"}"#)
        fake.script("transcript --dir", TestFactory.transcriptJSON([("user", "hi")]))
        let store = ChatStore(profile: TestFactory.profile(), secret: "s",
                              resumeSessionId: "claude-A", ssh: fake)
        await store.start()

        XCTAssertEqual(store.usage?.fiveHour?.utilization, 37.5, "claude's line is unchanged")
        XCTAssertEqual(store.usage?.sevenDay?.utilization, 51.0)
        XCTAssertEqual(store.usage?.scoped?.first?.name, "Fable")
        let usageCalls = fake.commandCalls(containing: "pervio-sessions usage")
        XCTAssertTrue(usageCalls.allSatisfy { !$0.contains("--backend") },
                      "the claude route must stay byte-identical for old servers: \(usageCalls)")
    }

    // MARK: the codex context ring

    func testCodexContextRingLoadsFromTheRollout() async {
        let fake = FakeSSH()
        fake.script("usage --backend codex", Self.codexUsageJSON)
        fake.script("context --dir", Self.codexContextJSON)
        fake.script("transcript --dir", TestFactory.transcriptJSON([("user", "hi"), ("assistant", "yo")]))
        let store = codexStore(fake)
        await store.start()

        XCTAssertEqual(store.contextTokens, 12080,
                       "a resumed codex conversation showed an empty ring until its next turn")
        XCTAssertEqual(store.contextWindow, 258_400,
                       "the rollout reports the REAL window; guessing 272000 draws the ring "
                       + "against a denominator codex never used")
        XCTAssertEqual(store.modelName, "gpt-5.4-mini",
                       "the rollout's turn_context names the model the header shows")
    }

    func testCodexContextIsAskedForOnTheCodexRoute() async {
        let fake = FakeSSH()
        fake.script("usage --backend codex", Self.codexUsageJSON)
        fake.script("context --dir", Self.codexContextJSON)
        fake.script("transcript --dir", TestFactory.transcriptJSON([("user", "hi")]))
        let store = codexStore(fake)
        await store.start()

        let ctxCalls = fake.commandCalls(containing: " context --dir")
        XCTAssertFalse(ctxCalls.isEmpty, "a resumed conversation loads its context fill")
        XCTAssertTrue(ctxCalls.allSatisfy { $0.contains("--backend codex") },
                      "codex conversations live in ~/.codex/sessions — without --backend codex "
                      + "the server looks in ~/.claude and answers used:0: \(ctxCalls)")
    }

    func testClaudeContextRingUnchangedWhenTheServerSendsNoWindow() async {
        let fake = FakeSSH()
        fake.script("pervio-sessions usage", Self.claudeUsageJSON)
        fake.script("context --dir", #"{"used": 1234, "model": "claude-fable-5"}"#)
        fake.script("transcript --dir", TestFactory.transcriptJSON([("user", "hi")]))
        let store = ChatStore(profile: TestFactory.profile(), secret: "s",
                              resumeSessionId: "claude-A", ssh: fake)
        await store.start()

        XCTAssertEqual(store.contextTokens, 1234)
        XCTAssertEqual(store.contextWindow, 200_000,
                       "the optional window field is codex-only; claude keeps its inferred tier")
    }

    // MARK: live — the turn that just ended

    func testACodexTurnRefreshesBothTheRingAndTheUsageLine() async {
        let fake = FakeSSH()
        fake.script("usage --backend codex", Self.codexUsageJSON)
        fake.script("context --dir", Self.codexContextJSON)
        fake.script("transcript --dir", TestFactory.transcriptJSON([("user", "hi")]))
        // What `codex exec --json` really emits at turn end: usage on
        // turn.completed (parsed to .contextUsage) and nothing else — codex
        // never puts token_count on the exec stream, so the quota number can
        // only be re-read from the rollout after the turn.
        fake.chatEvents([.contextUsage(31_000),
                         .result(text: "done", sessionId: nil, costUSD: nil,
                                 isError: false, contextWindow: nil)])
        let store = codexStore(fake)
        await store.start()
        let usageCallsBefore = fake.callCount("usage --backend codex")

        store.submit("go")
        await TestFactory.settle(24)

        XCTAssertEqual(store.contextTokens, 31_000,
                       "the ring must follow the turn that just ran")
        XCTAssertGreaterThan(fake.callCount("usage --backend codex"), usageCallsBefore,
                             "the turn end re-reads codex's rate_limits, so the weekly "
                             + "percentage moves during a conversation instead of at open only")
        XCTAssertEqual(store.usage?.weekly?.utilization, 23.0,
                       "…and the refreshed line is still codex's own pool")
        XCTAssertNil(store.usage?.fiveHour, "…never claude's")
    }
}
