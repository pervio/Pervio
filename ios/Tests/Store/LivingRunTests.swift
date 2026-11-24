import XCTest
@testable import Pervio

/// The living run (2026-10-20, "跟 app 一样"): after the reply the engine
/// process stays; a further message is FED into it (pervio-run say) instead of
/// starting a second process, the engine's own background tasks show as a
/// card, and a run that can't take more is replaced the old way.
@MainActor
final class LivingRunTests: XCTestCase {
    private func store(_ fake: FakeSSH) async -> ChatStore {
        var profile = TestFactory.profile()
        profile.runMode = true
        let store = ChatStore(profile: profile, secret: "secret", resumeSessionId: "sess-A", ssh: fake)
        await store.connect()
        return store
    }
    private func settle(ms: UInt64 = 25, _ done: () -> Bool) async throws {
        for _ in 0..<80 where !done() { try await Task.sleep(nanoseconds: ms * 1_000_000) }
    }
    private let result = AgentEvent.result(text: "", sessionId: "sess-A", costUSD: nil, isError: false, contextWindow: nil)

    override func tearDown() {      // what ended is kept on the phone: not a test's
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("pervio.bgdone.") { d.removeObject(forKey: k) }
        super.tearDown()
    }

    func testAFollowUpIsFedIntoTheLivingRunNotStartedAsANewOne() async throws {
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.textDelta("first reply"), result]
        fake.sayEvents = [.textDelta("second reply"), result]
        let s = await store(fake)
        let turn = Task { await s.send("first") }
        try await settle { s.lingeringRunId != nil }
        XCTAssertEqual(fake.calls.filter { $0 == "startRun" }.count, 1)
        await s.send("are you stuck?")
        try await settle { s.messages.last?.text == "second reply" && !s.isBusy }
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("sayRun") }, ["sayRun run-1"], "the message went into the living run")
        XCTAssertEqual(fake.calls.filter { $0 == "startRun" }.count, 1, "no second process")
        XCTAssertFalse(fake.calls.contains("stopRun"), "nothing was killed")
        XCTAssertEqual(fake.saidPrompts, ["are you stuck?"])
        XCTAssertEqual(s.messages.map(\.role).suffix(4), [.user, .assistant, .user, .assistant], "a user bubble, then the reply in a bubble of its own")
        XCTAssertEqual(s.messages.last?.text, "second reply")
        XCTAssertEqual(s.lingeringRunId, "run-1", "still living after the second reply")
        XCTAssertFalse(s.isBusy, "the fed turn answered: the composer is free again")
        XCTAssertNil(s.activeRunId, "…and nothing is in flight")
        s.stop(); turn.cancel()
    }

    /// The e2e shim answers in its result line alone (no text events first);
    /// so can an engine. After a landed reply that result is a reply of its own,
    /// not words for the finished bubble (which keeps its text and dropped them).
    func testAReplyAnsweredInItsResultLineAloneIsABubbleOfItsOwn() async throws {
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.textDelta("first reply"), result]
        fake.sayEvents = [.result(text: "second reply", sessionId: "sess-A", costUSD: nil, isError: false, contextWindow: nil)]
        let s = await store(fake)
        let turn = Task { await s.send("first") }
        try await settle { s.lingeringRunId != nil }
        await s.send("again?")
        try await settle { s.messages.last?.text == "second reply" && !s.isBusy }
        XCTAssertEqual(s.messages.map(\.role).suffix(4), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(s.messages.last?.text, "second reply")
        XCTAssertEqual(s.messages.dropLast(2).last?.text, "first reply", "the first bubble kept its own words")
        XCTAssertFalse(s.isBusy)
        s.stop(); turn.cancel()
    }

    func testWhenTheRunCanTakeNoMoreTheOldPathRuns() async throws {
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.textDelta("first reply"), result]
        fake.sayRunError = FakeSSH.Boom(message: "not running")
        let s = await store(fake)
        let turn = Task { await s.send("first") }
        try await settle { s.lingeringRunId != nil }
        let follow = Task { await s.send("again") }
        try await settle { fake.calls.filter { $0 == "startRun" }.count == 2 }
        XCTAssertTrue(fake.calls.contains("stopRun"), "the ended/lingering run is stopped first, as before")
        XCTAssertEqual(fake.calls.filter { $0 == "startRun" }.count, 2, "…and a fresh run started")
        s.stop(); turn.cancel(); follow.cancel()
    }

    func testTheEnginesBackgroundTaskShowsCountsAndFinishes() async throws {
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.backgroundTasks([BackgroundTask(id: "t1", description: "run the tests", startedAt: Date())]),
                          .textDelta("started"), result]
        fake.runEventsAfterResult = [.backgroundTaskDone(taskId: "t1", status: "completed"),
                                     .backgroundTasks([]),
                                     .textDelta("tests passed"), result]
        fake.runEventsAfterResultDelayMs = 400
        let s = await store(fake)
        let turn = Task { await s.send("do it") }
        try await settle { s.lingeringRunId != nil }
        XCTAssertEqual(s.backgroundTasks.map(\.description), ["run the tests"], "the card has the task while it runs")
        XCTAssertTrue(s.backgroundDone.isEmpty)
        try await settle { !s.backgroundDone.isEmpty }
        XCTAssertEqual(s.backgroundDone.first?.description, "run the tests")
        XCTAssertEqual(s.backgroundDone.first?.status, "completed")
        XCTAssertGreaterThanOrEqual(s.backgroundDone.first?.duration ?? -1, 0, "how long it took")
        XCTAssertTrue(s.backgroundTasks.isEmpty, "…and it left the pending list")
        try await settle { s.messages.last?.text == "tests passed" }
        XCTAssertEqual(s.messages.last?.text, "tests passed", "the engine's own continuation is a reply of its own")
        s.stop(); turn.cancel()
        try await settle { s.lingeringRunId == nil }
        XCTAssertTrue(s.backgroundTasks.isEmpty, "the process gone, nothing runs in it")
        XCTAssertEqual(s.backgroundDone.map(\.description), ["run the tests"],
                       "…and what ended stays listed: a run leaves a second after its last reply, a row that went with it was never read")
        fake.runEvents = [.textDelta("next"), result]; fake.runEventsAfterResult = []
        let next = Task { await s.send("and now?") }
        try await settle { s.messages.last?.text == "next" }
        XCTAssertTrue(s.backgroundDone.isEmpty, "the next turn starts a process of its own: the row is about the turn before")
        s.stop(); next.cancel()
    }

    func testReopeningALivingRunRestoresItAndFeedsTheNextMessage() async throws {
        let fake = FakeSSH()
        // Between turns: replied, taking more, its current turn starting at the END of its output (turnFrom).
        fake.runsJSON = #"[{"runId":"run-9","sessionId":"sess-A","dir":"/w","preview":"p","started":1,"state":"running","bytes":4321,"replied":true,"accepting":true,"turnFrom":4321,"background":[{"taskId":"t7","description":"deploy","startedAt":1792500000}]}]"#
        fake.runTailStaysOpen = true
        fake.runEvents = []                       // the Mac replays nothing from there: the replies are history already
        fake.sayEvents = [.textDelta("still deploying"), result]
        let s = await store(fake)
        let opening = Task { await s.start() }
        try await settle { s.lingeringRunId == "run-9" }
        XCTAssertEqual(s.lingeringRunId, "run-9", "an answered-but-living run is reattached, not ignored")
        XCTAssertEqual(fake.tailFroms, [4321], "the tail starts where the current turn starts, not at byte 0 (earlier turns would land on the last bubble again)")
        XCTAssertEqual(s.backgroundTasks.map(\.description), ["deploy"], "the Mac's ledger seeds the card")
        XCTAssertEqual(s.backgroundTasks.map(\.kind), [.other], "a row from a Mac whose scripts do not say what kind it is: a task, not guessed into a command")
        XCTAssertFalse(s.isBusy, "nothing in flight: the composer is free")
        XCTAssertNil(s.activeRunId)
        XCTAssertTrue(s.messages.allSatisfy { !$0.isStreaming }, "no bubble spins for a run that is between turns")
        let shown = s.messages.count
        await s.send("stuck?")
        try await settle { s.messages.last?.text == "still deploying" && !s.isBusy }
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("sayRun") }, ["sayRun run-9"])
        XCTAssertEqual(fake.calls.filter { $0 == "startRun" }.count, 0, "no new process for a living conversation")
        XCTAssertEqual(s.messages.count, shown + 2, "the question and its reply, nothing doubled")
        XCTAssertEqual(s.messages.last?.text, "still deploying")
        XCTAssertFalse(s.isBusy, "the fed turn answered: free again")
        s.stop(); opening.cancel()
    }

    /// Reopened MID-turn (a fed message still being answered): the replay starts
    /// at that turn's beginning and rebuilds just that reply.
    func testReopeningMidTurnReplaysOnlyTheTurnInFlight() async throws {
        let fake = FakeSSH()
        fake.runsJSON = #"[{"runId":"run-9","sessionId":"sess-A","dir":"/w","preview":"p","started":1,"state":"running","bytes":9000,"replied":false,"accepting":true,"turnFrom":7777}]"#
        fake.runTailStaysOpen = true
        fake.runEvents = [.textDelta("half way"), result]
        let s = await store(fake)
        let opening = Task { await s.start() }
        try await settle { s.lingeringRunId == "run-9" }
        XCTAssertEqual(fake.tailFroms, [7777], "replay from the turn's own start")
        XCTAssertEqual(s.messages.last?.text, "half way", "the turn in flight is rebuilt into the trailing bubble")
        XCTAssertEqual(s.lingeringRunId, "run-9", "…and once it lands, the run keeps living")
        XCTAssertFalse(s.isBusy)
        s.stop(); opening.cancel()
    }

    // MARK: Speaking into a running turn (插话, 2026-10-21)

    /// A message while the reply is still being worked out goes INTO the turn
    /// (say → the engine takes it at its next step), not into the queue: the
    /// words show at once, tagged, and the rest of the reply lands below them.
    func testAMessageDuringTheTurnGoesIntoItNotTheQueue() async throws {
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.textDelta("working on it")]          // no result yet: the turn is in flight
        fake.sayEvents = [.textDelta("…and SECOND"), result]
        let s = await store(fake)
        let turn = Task { await s.send("first") }
        try await settle { s.activeRunId != nil && s.messages.last?.text == "working on it" }
        s.submit("also do SECOND")
        try await settle { s.messages.last?.text == "…and SECOND" && !s.isBusy }
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("sayRun") }, ["sayRun run-1"], "fed into the running turn")
        XCTAssertEqual(fake.saidPrompts, ["also do SECOND"])
        XCTAssertEqual(s.queuedCount, 0, "not queued for after")
        XCTAssertEqual(fake.calls.filter { $0 == "startRun" }.count, 1)
        XCTAssertEqual(s.messages.map(\.role).suffix(4), [.user, .assistant, .user, .assistant],
                       "the words sit between the two halves of the reply")
        let n = s.messages.count
        XCTAssertEqual(s.messages[n - 3].text, "working on it")
        XCTAssertFalse(s.messages[n - 3].isStreaming, "the first half is closed off")
        XCTAssertTrue(s.messages[n - 2].interjected, "tagged as sent into the turn")
        XCTAssertEqual(s.messages[n - 2].text, "also do SECOND")
        XCTAssertEqual(s.messages[n - 1].text, "…and SECOND")
        XCTAssertFalse(s.isBusy); XCTAssertNil(s.activeRunId)
        XCTAssertEqual(s.lingeringRunId, "run-1", "one turn, one result, the run lives on")
        s.stop(); turn.cancel()
    }

    /// A run that can't take a message mid-turn (a one-shot run, one already
    /// gone): the message queues for after the reply, as it always did.
    func testAMessageDuringATurnTheRunCannotTakeQueuesAsBefore() async throws {
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.textDelta("working")]
        fake.runEventsAfterResult = [result]                     // the turn ends on its own a moment later
        fake.runEventsAfterResultDelayMs = 700
        fake.sayRunError = FakeSSH.Boom(message: "not running")
        let s = await store(fake)
        let turn = Task { await s.send("first") }
        try await settle { s.activeRunId != nil && s.messages.last?.text == "working" }
        s.submit("later")
        try await settle { s.queuedCount == 1 }
        XCTAssertEqual(s.queuedCount, 1, "refused mid-turn → queued")
        XCTAssertFalse(s.messages.contains { $0.interjected }, "nothing was tagged as sent into the turn")
        try await settle(ms: 50) { fake.calls.filter { $0 == "startRun" }.count == 2 }
        XCTAssertEqual(fake.calls.filter { $0 == "startRun" }.count, 2, "…and fired after the reply, as a turn of its own")
        s.stop(); turn.cancel()
    }

    /// Reopened mid-turn and spoken into: the rest of the turn lands below the words.
    func testSpeakingIntoAReattachedTurn() async throws {
        let fake = FakeSSH()
        fake.runsJSON = #"[{"runId":"run-9","sessionId":"sess-A","dir":"/w","preview":"p","started":1,"state":"running","bytes":9000,"replied":false,"accepting":true,"turnFrom":7777}]"#
        fake.runTailStaysOpen = true
        fake.runEvents = [.textDelta("half way")]
        fake.sayEvents = [.textDelta("the rest"), result]
        let s = await store(fake)
        let opening = Task { await s.start() }
        try await settle { s.activeRunId == "run-9" && s.messages.last?.text == "half way" }
        s.submit("hurry")
        try await settle { s.messages.last?.text == "the rest" && !s.isBusy }
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("sayRun") }, ["sayRun run-9"])
        let n = s.messages.count
        XCTAssertEqual(s.messages[n - 3].text, "half way"); XCTAssertFalse(s.messages[n - 3].isStreaming)
        XCTAssertTrue(s.messages[n - 2].interjected)
        XCTAssertEqual(s.messages[n - 1].text, "the rest")
        XCTAssertEqual(s.lingeringRunId, "run-9")
        s.stop(); opening.cancel()
    }

    func testTheComposersOneKey() {
        XCTAssertEqual(ComposerKey.resolve(busy: true, hasText: false), .stop, "a turn runs, nothing typed: Stop")
        XCTAssertEqual(ComposerKey.resolve(busy: true, hasText: true), .send, "typed something: Send — into the turn")
        XCTAssertEqual(ComposerKey.resolve(busy: false, hasText: true), .send)
        XCTAssertEqual(ComposerKey.resolve(busy: false, hasText: false), .send, "idle: the (disabled) send key, never a stop")
    }

    /// The Mac deletes a conversation by its own agent's files: a Codex thread
    /// lives under ~/.codex, so the wire names the agent (before this the row
    /// vanished on the phone and came back on the next load, 2026-10-21).
    /// Codex refusing a conversation another process holds (a terminal, VS
    /// Code, another phone) reads as the takeover hint, not a raw thread id.
    func testCodexHeldElsewhereReadsAsTheTakeoverHint() {
        let raw = "codex could not resume the thread: thread 01a1c591-84b6-7430-85f7-af09dfa94ce8 already has an active writer"
        XCTAssertEqual(ChatStore.failureHint(raw), L.takeoverHint())
        XCTAssertNil(ChatStore.failureHint("codex refused the turn: something else"))
    }

    func testDeleteNamesTheConversationsAgentOnTheWire() {
        let claude = SessionService.deleteCommand(launcher: "pervio-sessions", dir: "/w", session: "abc", backend: .claude)
        XCTAssertFalse(claude.contains("--backend"), "Claude is the Mac's default")
        let codex = SessionService.deleteCommand(launcher: "pervio-sessions", dir: "/w", session: "0199-thread", backend: .codex)
        XCTAssertTrue(codex.hasSuffix(" --backend codex"), codex)
        XCTAssertTrue(codex.contains("delete --dir '/w' --session '0199-thread'"), codex)
    }

    func testAHistoryRowSentMidTurnDecodesItsFlag() throws {
        let rows = try JSONDecoder().decode([TranscriptTurn].self, from: Data(#"[{"role":"user","text":"also lint","tools":[],"mid":true},{"role":"user","text":"typed","tools":[]}]"#.utf8))
        XCTAssertEqual(rows.map(\.mid), [true, nil])
    }

    func testTheEnginesTaskEventsParse() throws {
        let changed = #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b2q","run_id":"r","task_type":"local_bash","description":"Sleep 20 seconds then print bgdone"}],"session_id":"s"}"#
        guard case .backgroundTasks(let tasks)? = AgentEvent.parse(line: changed, backend: .claude).first else { return XCTFail() }
        XCTAssertEqual(tasks.map(\.id), ["b2q"]); XCTAssertEqual(tasks.first?.description, "Sleep 20 seconds then print bgdone")
        let empty = #"{"type":"system","subtype":"background_tasks_changed","tasks":[],"session_id":"s"}"#
        guard case .backgroundTasks(let none)? = AgentEvent.parse(line: empty, backend: .claude).first else { return XCTFail() }
        XCTAssertTrue(none.isEmpty)
        let done = #"{"type":"system","subtype":"task_notification","task_id":"b2q","status":"completed","session_id":"s"}"#
        guard case .backgroundTaskDone(let id, let status, _, _)? = AgentEvent.parse(line: done, backend: .claude).first else { return XCTFail() }
        XCTAssertEqual(id, "b2q"); XCTAssertEqual(status, "completed")
        // task_started for a background task is bookkeeping: the changed set
        // already said it, and the board adds nothing for it (BackgroundBoardTests
        // has the other kind — a sub-agent its tool call waits for).
        let started = #"{"type":"system","subtype":"task_started","task_id":"b9z","is_backgrounded":true,"task_type":"local_bash","description":"x","session_id":"s"}"#
        var board = BackgroundBoard()
        for e in AgentEvent.parse(line: started, backend: .claude) { board.apply(e) }
        XCTAssertEqual(board, BackgroundBoard(), "task_started is bookkeeping (the changed set already said it)")
    }

    func testRunRowsCarryAcceptingAndBackground() throws {
        let rows = try SSHService.decodeRuns(#"[{"runId":"a","sessionId":"s","dir":"/w","preview":"p","started":1,"state":"running","bytes":0,"replied":true,"accepting":true,"background":[{"taskId":"t1","description":"tests","startedAt":5}]},{"runId":"b","sessionId":"s","dir":"/w","preview":"p","started":1,"state":"done","bytes":0,"replied":true}]"#)
        XCTAssertEqual(rows.map(\.accepting), [true, false])
        XCTAssertEqual(rows.map(\.turnFrom), [0, 0], "an older server's rows read as turn start 0 (replay from the top, as before)")
        let with = try SSHService.decodeRuns(#"[{"runId":"c","sessionId":"s","dir":"/w","preview":"p","started":1,"state":"running","bytes":90,"replied":true,"accepting":true,"turnFrom":90}]"#)
        XCTAssertEqual(with.first?.turnFrom, 90)
        XCTAssertEqual(rows[0].background.first?.description, "tests")
        XCTAssertFalse(rows[0].isRunning, "answered: not 'working' for the pill…")
        XCTAssertTrue(rows[1].background.isEmpty, "…an older server's row has no background field")
    }

    func testTheClock() {
        XCTAssertEqual(BackgroundClock.format(7), "0:07")
        XCTAssertEqual(BackgroundClock.format(192), "3:12")
        XCTAssertEqual(BackgroundClock.format(3940), "1:05:40")
        XCTAssertEqual(BackgroundClock.elapsed(since: Date(timeIntervalSince1970: 100), now: Date(timeIntervalSince1970: 1300)), "20:00")
    }
}
