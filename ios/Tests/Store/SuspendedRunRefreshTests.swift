import XCTest
import Combine
@testable import Pervio

/// Open a conversation whose reply finished while the phone was suspended, and see
/// the reply — without backing out and re-entering.
///
/// What the user hit: a turn was still running when iOS suspended the app (locked
/// screen). It finished server-side; its final assistant text was written to the
/// transcript file. The user tapped the completion notification (or just reopened
/// the app) straight into that conversation — and saw the PRE-suspend state, the
/// old transcript, no new reply. Only leaving the chat and coming back showed it.
///
/// The cause: `resume()` (foreground) reconnected and reconciled any live run, but
/// deliberately did NOT reload history (a full reload flashes the "Loading
/// history…" banner). So a turn that FINISHED while away — whose reply is only in
/// the file, not in memory — never surfaced. The fix reloads SILENTLY (no banner;
/// row-reconciliation keeps the untouched bubbles from flashing) whenever we come
/// back and are idle, so the finished reply appears in place.
///
/// These pin: the reply appears on resume / re-appear; a still-live turn is NOT
/// interrupted; and the reload is silent (no `isLoadingHistory` flash).
@MainActor
final class SuspendedRunRefreshTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PromptLanguage.defaultsKey)
        super.tearDown()
    }

    /// The transcript BEFORE the run finished — one question, no answer yet.
    private let before: [(String, String)] = [
        ("user", "summarize today's papers"),
    ]
    /// The transcript AFTER the run finished — the reply is now on disk.
    private let after: [(String, String)] = [
        ("user", "summarize today's papers"),
        ("assistant", "Here are the three that matter…"),
    ]

    private func store(_ fake: FakeSSH) -> ChatStore {
        var p = TestFactory.profile()
        p.runMode = true
        return ChatStore(profile: p, secret: "s", resumeSessionId: "sess-1", ssh: fake)
    }

    /// Bring the store up on the pre-finish transcript, connected and idle, then
    /// simulate iOS suspending us (the socket drops).
    private func openedThenSuspended(_ fake: FakeSSH) async -> ChatStore {
        fake.script("--session 'sess-1'", TestFactory.transcriptJSON(before))
        fake.script("context --dir", #"{"used": 10, "model": "claude-fable-5"}"#)
        fake.script("pervio-sessions usage", "{}")
        fake.runs = []                      // no run is executing anymore (it finished while away)
        let s = store(fake)
        await s.start()
        XCTAssertEqual(s.messages.map(\.role), [.user],
                       "precondition: only the question is loaded, no reply yet")
        s.handleBackground()                // iOS suspends → socket dropped
        await TestFactory.settle()
        return s
    }

    // MARK: - The reply appears on the way back

    func testResume_pullsInTheReplyThatFinishedWhileSuspended() async {
        let fake = FakeSSH()
        let s = await openedThenSuspended(fake)

        // While we were away the run finished — the transcript now HAS the reply.
        fake.script("--session 'sess-1'", TestFactory.transcriptJSON(after))

        await s.resume()                    // foreground: reconnect + refresh
        await TestFactory.settle()

        XCTAssertEqual(s.messages.map(\.role), [.user, .assistant],
                       "the reply written while suspended must be pulled in on resume, "
                       + "not left showing the pre-suspend transcript")
        XCTAssertEqual(s.messages.last?.text, "Here are the three that matter…")
    }

    func testResume_afterHoldingAFinishedRunId_reloadsAndReleasesIt() async {
        // The store held an activeRunId (Run mode, sent then left). The server now
        // reports the run finished; resume must both release it AND show its reply.
        let fake = FakeSSH()
        fake.script("--session 'sess-1'", TestFactory.transcriptJSON(before))
        fake.script("context --dir", #"{"used": 10, "model": "claude-fable-5"}"#)
        fake.script("pervio-sessions usage", "{}")
        fake.startRunId = "run-7"
        fake.runEvents = []                 // tail drops with no result (we got suspended)
        let s = store(fake)
        await s.connect()
        await s.send("summarize today's papers")
        XCTAssertEqual(s.activeRunId, "run-7", "precondition: we hold the run")
        s.handleBackground()
        await TestFactory.settle()

        // Server: that run is no longer running, and the reply is on disk.
        fake.runs = []
        fake.script("--session 'sess-1'", TestFactory.transcriptJSON(after))

        await s.resume()
        await TestFactory.settle()

        XCTAssertNil(s.activeRunId, "a finished run must be released on resume")
        XCTAssertFalse(s.isBusy)
        XCTAssertEqual(s.messages.last?.role, .assistant)
        XCTAssertEqual(s.messages.last?.text, "Here are the three that matter…",
                       "releasing the run is not enough — its reply has to show too")
    }

    func testReappear_refreshesWhenAlreadyConnectedAndIdle() async {
        // Navigated to a sub-view and back (no scenePhase change, socket still live):
        // refreshHistoryIfIdle is what onAppear calls, and it must pick up a reply
        // that landed off-screen.
        let fake = FakeSSH()
        fake.script("--session 'sess-1'", TestFactory.transcriptJSON(before))
        fake.script("context --dir", #"{"used": 10, "model": "claude-fable-5"}"#)
        fake.script("pervio-sessions usage", "{}")
        fake.runs = []
        let s = store(fake)
        await s.start()
        XCTAssertTrue(s.isConnected, "precondition: still connected")

        fake.script("--session 'sess-1'", TestFactory.transcriptJSON(after))
        await s.refreshHistoryIfIdle()
        await TestFactory.settle()

        XCTAssertEqual(s.messages.last?.text, "Here are the three that matter…")
    }

    // MARK: - What the refresh must NOT do

    func testRefresh_neverInterruptsALiveStreamingTurn() async {
        // A turn is streaming right now (isBusy). A refresh landing mid-turn would
        // reload the transcript over the live bubble — the refresh must stand down.
        let fake = FakeSSH()
        fake.script("--session 'sess-1'", TestFactory.transcriptJSON(before))
        fake.script("context --dir", #"{"used": 10, "model": "claude-fable-5"}"#)
        fake.script("pervio-sessions usage", "{}")
        let s = store(fake)
        await s.start()

        // Model a live turn in flight: pause the stream before its first event.
        fake.chatEvents([.textDelta("streaming…"), .result(text: "done", sessionId: "sess-1",
                                                            costUSD: nil, isError: false, contextWindow: nil)])
        fake.pauseChat(before: 1)
        s.profile.runMode = false
        s.submit("a follow-up")
        await fake.awaitChatPaused()
        XCTAssertTrue(s.isBusy, "precondition: a turn is streaming")

        let transcriptReadsBefore = fake.callCount("--session 'sess-1'")
        await s.refreshHistoryIfIdle()      // must be a no-op while busy
        XCTAssertEqual(fake.callCount("--session 'sess-1'"), transcriptReadsBefore,
                       "a refresh must not read the transcript while a turn is live — "
                       + "it would reload over the streaming bubble")

        fake.releaseChat()
        await TestFactory.settle()
    }

    func testSilentRefresh_neverFlashesTheLoadingBanner() async {
        // The whole reason resume didn't reload before: a reload flips
        // isLoadingHistory, which shows "Loading history…" at the top. The silent
        // refresh must leave that flag alone throughout.
        let fake = FakeSSH()
        let s = await openedThenSuspended(fake)
        fake.script("--session 'sess-1'", TestFactory.transcriptJSON(after))

        var sawLoading = false
        let cancellable = s.$isLoadingHistory.sink { if $0 { sawLoading = true } }
        defer { cancellable.cancel() }

        await s.resume()
        await TestFactory.settle()

        XCTAssertFalse(sawLoading,
                       "the resume refresh must be silent — no 'Loading history…' banner")
        XCTAssertEqual(s.messages.last?.text, "Here are the three that matter…",
                       "…and it still pulled the reply in")
    }
}
