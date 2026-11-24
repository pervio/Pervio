import XCTest
@testable import Pervio

/// Run mode, the reply has landed, the Mac-side process lingers (Claude Code
/// waits on a background task of its own) — the desktop's behaviour, asked for
/// on 2026-10-18: the turn is over for the person, the process may speak again
/// as a NEW reply, and a new message from the person drops the lingering process.
@MainActor
final class RunReplyLandedTests: XCTestCase {
    private func store(_ fake: FakeSSH) async -> ChatStore {
        var profile = TestFactory.profile()
        profile.runMode = true
        let store = ChatStore(profile: profile, secret: "secret", resumeSessionId: "sess-A", ssh: fake)
        fake.script("pervio-sessions usage", "{}")
        fake.startRunId = "run-42"
        await store.connect()
        return store
    }
    private let result = AgentEvent.result(text: "", sessionId: "sess-A", costUSD: nil, isError: false, contextWindow: nil)

    private func settle(_ ms: UInt64 = 50, until done: () -> Bool) async throws {
        for _ in 0..<80 where !done() { try await Task.sleep(nanoseconds: ms * 1_000_000) }
    }

    func testALandedReplyEndsTheTurnWhileTheProcessLingers() async throws {
        let fake = FakeSSH()
        let s = await store(fake)
        fake.runEvents = [.textDelta("here is the answer"), result]
        fake.runTailStaysOpen = true
        let turn = Task { await s.send("do the thing") }
        defer { turn.cancel() }
        try await settle { s.lingeringRunId != nil }
        let reply = try XCTUnwrap(s.messages.last(where: { $0.role == .assistant }))
        XCTAssertFalse(reply.isStreaming, "the reply is on screen — no spinner")
        XCTAssertEqual(reply.text, "here is the answer")
        XCTAssertNil(s.activeRunId, "no stop button: the turn is over for the person")
        XCTAssertFalse(s.isBusy, "the composer is free")
        XCTAssertEqual(s.statusLine, L.runReplyLanded())
        XCTAssertEqual(s.lingeringRunId, "run-42", "…but the process is remembered as still living")
        // Since 2026-10-20 nothing is written into the transcript about it: what
        // the process still does shows as the background card (its own events).
        try await Task.sleep(nanoseconds: 1_900_000_000)
        XCTAssertFalse(s.messages.contains { $0.text == L.runLingeringNote() }, "no note line under the reply")
        XCTAssertEqual(s.messages.last?.text, "here is the answer")
        XCTAssertTrue(s.backgroundTasks.isEmpty, "no task announced, no card")
    }

    func testAContinuationLandsAsANewReplyAndTheNoteGoes() async throws {
        let fake = FakeSSH()
        let s = await store(fake)
        fake.runEvents = [.textDelta("here is the answer"), result]
        fake.runEventsAfterResult = [.textDelta("…and the tests passed"), result]
        fake.runEventsAfterResultDelayMs = 1_800          // past the note's grace period
        await s.send("do the thing")                      // the tail closes after the continuation
        let replies = s.messages.filter { $0.role == .assistant }
        XCTAssertEqual(replies.map(\.text), ["here is the answer", "…and the tests passed"],
                       "what the process says after its result is a new reply, never glued onto the finished one")
        XCTAssertTrue(replies.allSatisfy { !$0.isStreaming })
        XCTAssertFalse(s.messages.contains { $0.text == L.runLingeringNote() }, "the note is gone once it spoke / exited")
        XCTAssertNil(s.lingeringRunId, "the process exited: nothing lingers")
    }

    func testANewMessageGoesIntoTheLivingProcessNotAroundIt() async throws {
        // 2026-10-20: the living run. The process that answered is still here, so
        // the next message is fed into it — no stop, no second process. (The
        // run that can't take more falls back to stop + start: LivingRunTests.)
        let fake = FakeSSH()
        let s = await store(fake)
        fake.runEvents = [.textDelta("here is the answer"), result]
        fake.runTailStaysOpen = true
        fake.sayEvents = [.textDelta("second answer"), result]
        let turn = Task { await s.send("do the thing") }
        defer { turn.cancel() }
        try await settle { s.lingeringRunId != nil }
        s.submit("and now this")
        try await settle { s.messages.last?.text == "second answer" && !s.isBusy }
        XCTAssertEqual(fake.callCount("stopRun"), 0, "nothing is killed")
        XCTAssertEqual(fake.callCount("startRun"), 1, "no second process")
        XCTAssertEqual(fake.callCount("sayRun run-42"), 1, "the message went into the living run")
        XCTAssertEqual(s.messages.filter { $0.role == .assistant }.map(\.text), ["here is the answer", "second answer"])
        XCTAssertEqual(s.lingeringRunId, "run-42", "still living after it answered again")
    }

    func testARunThatExitsRightAfterItsResultShowsNoNote() async throws {
        let fake = FakeSSH()
        let s = await store(fake)
        fake.runEvents = [.textDelta("quick one"), result]
        await s.send("hi")
        XCTAssertNil(s.lingeringRunId)
        try await Task.sleep(nanoseconds: 1_900_000_000)
        XCTAssertFalse(s.messages.contains { $0.text == L.runLingeringNote() }, "the normal case never shows the note")
    }
}
