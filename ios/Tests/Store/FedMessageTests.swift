import XCTest
@testable import Pervio

/// A message sent while the previous one is still being answered is on screen
/// from the tap to the end (2026-11-21, the person's two screenshots: "我明明
/// 对话看网页部署了 但加载显示是在上一段").
///
/// What happened there: the Mac had taken the message, but codex 0.160 writes a
/// fed message into its record only when the model gets to it — after the
/// running command (22 s measured) or the answer being written (45 s). The page
/// is built from that record, so a conversation opened meanwhile showed the
/// previous turn spinning and no message. The same gap, shorter, sat between
/// the tap and the Mac's answer: the input box was empty, the bubble not yet
/// added.
///
/// Now the run's own stream says both things — the Mac took it (`turn_sent`,
/// with the words), the engine took it (`turn_taken`) — and the page places the
/// message by them.
@MainActor
final class FedMessageTests: XCTestCase {
    private func store(_ fake: FakeSSH, codex: Bool) async -> ChatStore {
        var profile = TestFactory.profile()
        profile.runMode = true
        if codex { profile.backend = .codex }
        let store = ChatStore(profile: profile, secret: "secret", resumeSessionId: "sess-A", ssh: fake)
        await store.connect()
        return store
    }
    private func settle(ms: UInt64 = 25, _ done: () -> Bool) async throws {
        for _ in 0..<120 where !done() { try await Task.sleep(nanoseconds: ms * 1_000_000) }
    }
    private let result = AgentEvent.result(text: "", sessionId: "sess-A", costUSD: nil, isError: false, contextWindow: nil)
    private func running(_ extra: String = "") -> String {
        #"[{"runId":"run-9","sessionId":"sess-A","dir":"/w","preview":"p","started":1,"state":"running","bytes":9000,"replied":false,"accepting":true,"turnFrom":7777"# + extra + "}]"
    }

    // MARK: From the tap

    func testTheWordsAreOnScreenBeforeTheMacHasAnswered() async throws {
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.textDelta("working on it")]
        fake.sayDelayMs = 600
        fake.sayEvents = [.textDelta("the rest"), result]
        let s = await store(fake, codex: false)
        let turn = Task { await s.send("first") }
        try await settle { s.activeRunId != nil && s.messages.last?.text == "working on it" }
        s.submit("also SECOND")
        try await settle { s.messages.last?.text == "also SECOND" }
        XCTAssertEqual(s.messages.last?.role, .user, "the bubble is there at once")
        XCTAssertEqual(s.messages.last?.delivery, .sending, "…marked as on its way")
        XCTAssertTrue(fake.saidPrompts.isEmpty, "…while the Mac has not answered yet")
        try await settle { s.messages.last?.text == "the rest" && !s.isBusy }
        let n = s.messages.count
        XCTAssertEqual(s.messages[n - 2].text, "also SECOND")
        XCTAssertNil(s.messages[n - 2].delivery)
        XCTAssertTrue(s.messages[n - 2].interjected, "Claude Code gives no word of taking: part of the turn once the Mac has it")
        XCTAssertEqual(s.messages.filter { $0.text == "also SECOND" }.count, 1)
        s.stop(); turn.cancel()
    }

    func testAMessageTheRunRefusesLeavesTheScreenAndWaitsInTheQueue() async throws {
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.textDelta("working")]
        fake.sayDelayMs = 300
        fake.sayRunError = FakeSSH.Boom(message: "not running")
        let s = await store(fake, codex: false)
        let turn = Task { await s.send("first") }
        try await settle { s.activeRunId != nil && s.messages.last?.text == "working" }
        s.submit("later")
        try await settle { s.messages.last?.text == "later" }
        XCTAssertEqual(s.messages.last?.delivery, .sending)
        try await settle { s.queuedCount == 1 }
        XCTAssertEqual(s.queuedCount, 1, "queued for after the reply, as before")
        XCTAssertFalse(s.messages.contains { $0.text == "later" }, "and not left on screen as if it had gone")
        s.stop(); turn.cancel()
    }

    // MARK: Codex — the wait until the engine takes it

    func testOnCodexTheMessageWaitsBelowTheReplyUntilTheEngineTakesIt() async throws {
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.textDelta("working")]
        let s = await store(fake, codex: true)
        let turn = Task { await s.send("first") }
        try await settle { s.activeRunId != nil && s.messages.last?.text == "working" }
        s.submit("second")
        try await settle { s.messages.last?.delivery == .awaiting }
        XCTAssertEqual(s.messages.last?.text, "second")
        XCTAssertEqual(s.messages.last?.delivery, .awaiting, "the Mac has it; codex has not taken it")

        // The Mac's own mark arrives on the stream: no second bubble.
        fake.pushTail([.turnSent("second"), .textDelta(" — still on the first")])
        try await settle { s.messages.contains { $0.text == "working — still on the first" } }
        var n = s.messages.count
        XCTAssertEqual(s.messages.filter { $0.text == "second" }.count, 1)
        XCTAssertEqual(s.messages[n - 2].text, "working — still on the first",
                       "what codex says before it takes the message belongs to the reply above it")
        XCTAssertEqual(s.messages[n - 1].delivery, .awaiting)

        // Codex takes it: from here on the reply continues below the words.
        fake.pushTail([.turnTaken("second"), .textDelta("now the second"), result])
        try await settle { s.messages.last?.text == "now the second" && !s.isBusy }
        n = s.messages.count
        XCTAssertEqual(s.messages.suffix(3).map(\.role), [.assistant, .user, .assistant])
        XCTAssertEqual(s.messages[n - 3].text, "working — still on the first")
        XCTAssertFalse(s.messages[n - 3].isStreaming, "the reply above is closed off")
        XCTAssertNil(s.messages[n - 2].delivery)
        XCTAssertTrue(s.messages[n - 2].interjected)
        XCTAssertEqual(s.messages[n - 1].text, "now the second")
        s.stop(); turn.cancel()
    }

    /// The person's case: the conversation is opened while the message waits.
    /// The record (what `transcript` returns) does not hold it; the run's stream
    /// does.
    func testOpeningTheConversationShowsAMessageThatStillWaits() async throws {
        let fake = FakeSSH()
        fake.script("transcript", TestFactory.transcriptJSON([("user", "first"), ("assistant", "working")]))
        fake.runsJSON = running()
        fake.runTailStaysOpen = true
        fake.runEvents = [.textDelta("working, further along"), .turnSent("the web deployment?")]
        let s = await store(fake, codex: true)
        let opening = Task { await s.start() }
        // (the replayed reply is published on the reveal tick, a moment after the mark)
        try await settle { s.messages.last?.text == "the web deployment?"
            && s.messages.dropLast().last?.text == "working, further along" }
        var n = s.messages.count
        XCTAssertEqual(s.messages.last?.role, .user, "the message is on the page although no record holds it")
        XCTAssertEqual(s.messages.last?.delivery, .awaiting)
        XCTAssertEqual(s.messages[n - 2].text, "working, further along", "the reply in flight is the row above it")
        XCTAssertTrue(s.isBusy)

        fake.pushTail([.textDelta(" …done with the first"), .turnTaken("the web deployment?"),
                       .textDelta("checking the deployment"), result])
        try await settle { s.messages.last?.text == "checking the deployment" && !s.isBusy }
        n = s.messages.count
        XCTAssertEqual(s.messages.suffix(4).map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(s.messages[n - 3].text, "working, further along …done with the first")
        XCTAssertEqual(s.messages[n - 2].text, "the web deployment?")
        XCTAssertNil(s.messages[n - 2].delivery)
        XCTAssertEqual(s.messages[n - 1].text, "checking the deployment")
        s.stop(); opening.cancel()
    }

    /// A message already in the record is not shown twice when the stream's
    /// mark for it comes by in the replay.
    func testAMessageTheRecordHoldsIsNotAddedAgain() async throws {
        let fake = FakeSSH()
        fake.script("transcript", TestFactory.transcriptJSON([("user", "first"), ("assistant", "working"),
                                                          ("user", "second"), ("assistant", "on the second")]))
        fake.runsJSON = running()
        fake.runTailStaysOpen = true
        fake.runEvents = [.turnSent("second"), .textDelta("on the second, more")]
        let s = await store(fake, codex: true)
        let opening = Task { await s.start() }
        try await settle { s.messages.last?.text == "on the second, more" }
        XCTAssertEqual(s.messages.filter { $0.text == "second" }.count, 1)
        XCTAssertEqual(s.messages.map(\.role), [.user, .assistant, .user, .assistant])
        s.stop(); opening.cancel()
    }

    /// The replay starts after the last message the engine took. A copy of the
    /// conversation read a moment before the taking does not hold that message
    /// and the replay will not bring it: the chat reads again.
    func testACopyReadBeforeTheTakingIsReadAgain() async throws {
        let fake = FakeSSH()
        fake.script("transcript", TestFactory.transcriptJSON([("user", "first"), ("assistant", "working")]))
        fake.runsJSON = running(#","lastTaken":"second""#)
        fake.runTailStaysOpen = true
        fake.runEvents = [.textDelta("x")]
        let s = await store(fake, codex: true)
        let opening = Task { await s.start() }
        try await settle { s.activeRunId == "run-9" }
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("run: ") && $0.contains(" transcript ") }.count, 2,
                       "the copy lacked the message the replay starts after")
        s.stop(); opening.cancel()

        let held = FakeSSH()
        held.script("transcript", TestFactory.transcriptJSON([("user", "first"), ("assistant", "working"),
                                                          ("user", "second"), ("assistant", "y")]))
        held.runsJSON = running(#","lastTaken":"second""#)
        held.runTailStaysOpen = true
        held.runEvents = [.textDelta("y")]
        let s2 = await store(held, codex: true)
        let opening2 = Task { await s2.start() }
        try await settle { s2.activeRunId == "run-9" }
        XCTAssertEqual(held.calls.filter { $0.hasPrefix("run: ") && $0.contains(" transcript ") }.count, 1,
                       "a copy that holds it is not read twice")
        s2.stop(); opening2.cancel()
    }

    // MARK: The two marks on the wire

    func testTheMarksParseForEveryEngine() {
        for backend in [AgentBackend.claude, .codex, .cursor] {
            let sent = AgentEvent.parse(line: #"{"type":"pervio","subtype":"turn_sent","ts":1,"preview":"hi","text":"hi there"}"#, backend: backend)
            guard case .turnSent("hi there")? = sent.first else { return XCTFail("turn_sent on \(backend): \(sent)") }
            let taken = AgentEvent.parse(line: #"{"type":"pervio","subtype":"turn_taken","text":"hi there"}"#, backend: backend)
            guard case .turnTaken("hi there")? = taken.first else { return XCTFail("turn_taken on \(backend): \(taken)") }
            // A Mac whose scripts predate the words on the mark: nothing to place.
            let old = AgentEvent.parse(line: #"{"type":"pervio","subtype":"turn_sent","ts":1,"preview":"hi"}"#, backend: backend)
            guard case .ignored? = old.first else { return XCTFail("old mark on \(backend): \(old)") }
        }
    }

    func testARunRowCarriesTheMessageItsReplayStartsAfter() throws {
        let rows = try SSHService.decodeRuns(running(#","lastTaken":"second""#))
        XCTAssertEqual(rows.first?.lastTaken, "second")
        XCTAssertEqual(try SSHService.decodeRuns(running()).first?.lastTaken, "", "absent on an older Mac: empty, not a failure")
    }
}
