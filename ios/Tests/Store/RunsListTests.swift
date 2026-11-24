import XCTest
@testable import Pervio

/// R2: `pervio-run list` is how the chat learns whether THIS conversation still
/// has a turn executing. An answer we can't read is "I don't know" — reading it
/// as "nothing is running" releases the session and fires the queued follow-up
/// straight into a turn that is still burning tools on the server.
@MainActor
final class RunsListTests: XCTestCase {

    /// Real server output (the fixture), cut off mid-record the way a dropped
    /// connection / a maxResponseSize clamp cuts it.
    private func truncatedRunsList() throws -> String {
        let whole = try Fixture.text("runs-list")
        return String(whole.prefix(90))
    }

    /// Drive a store into "a detached run of mine is still going, and the user
    /// has typed a follow-up behind it", then let it re-check the server.
    private func storeHoldingARunWithAQueuedFollowUp(_ fake: FakeSSH) async -> ChatStore {
        var profile = TestFactory.profile()
        profile.runMode = true                     // Run mode: the turn is detached
        let store = ChatStore(profile: profile, secret: "secret",
                              resumeSessionId: "sess-A", ssh: fake)
        fake.script("pervio-sessions usage", "{}")
        fake.startRunId = "run-42"
        fake.runEvents = []                        // tail drops without a result…
        fake.runStateValue = ""                    // …and the server can't say why
        await store.connect()
        await store.send("start the long job")
        XCTAssertEqual(store.activeRunId, "run-42", "precondition: the run is still ours")
        store.submit("and then deploy it")         // queued behind the running turn
        XCTAssertEqual(store.queuedCount, 1, "precondition: the follow-up is queued")
        await store.disconnect()
        return store
    }

    /// Turns actually put on the wire (Run mode launches with `startRun`, Chat
    /// mode streams) — the thing that must not double up.
    private func turnsSent(_ fake: FakeSSH) -> Int {
        fake.callCount("startRun") + fake.callCount("chatStream")
    }

    func testR2_unreadableRunsListIsNotReadAsNoRunningTask() async throws {
        let fake = FakeSSH()
        let store = await storeHoldingARunWithAQueuedFollowUp(fake)
        XCTAssertEqual(turnsSent(fake), 1, "precondition: one turn is out there")
        fake.runsJSON = try truncatedRunsList()

        await store.resume()                       // reconnect → re-check the runs
        await TestFactory.settle()

        XCTAssertEqual(turnsSent(fake), 1,
                       "a runs list we couldn't parse was read as 'nothing is running', "
                       + "so the queued follow-up was sent on top of a run that is still going")
        XCTAssertEqual(store.queuedCount, 1,
                       "an unreadable answer must leave the queue where it was")
    }

    func testR2_honestlyEmptyRunsListStillReleasesTheSession() async throws {
        let fake = FakeSSH()
        let store = await storeHoldingARunWithAQueuedFollowUp(fake)
        fake.runsJSON = "[]"                       // the server really has nothing

        await store.resume()
        await TestFactory.settle()

        XCTAssertEqual(turnsSent(fake), 2,
                       "an honest empty list DOES mean the run ended — the queued "
                       + "follow-up should fire")
        XCTAssertEqual(store.queuedCount, 0)
    }

    /// A detached run that died without a result surfaces the SERVER'S reason
    /// (the backend's last stderr line, forwarded by `pervio-run status`), not
    /// just the bare "ended without a result" that left the user guessing —
    /// e.g. codex refusing "thread … already has an active writer".
    func testR2_failedRunShowsTheServersReason() async throws {
        let fake = FakeSSH()
        var profile = TestFactory.profile()
        profile.runMode = true
        let store = ChatStore(profile: profile, secret: "secret",
                              resumeSessionId: "sess-A", ssh: fake)
        fake.script("pervio-sessions usage", "{}")
        fake.startRunId = "run-42"
        fake.runEvents = []                    // tail drops with no result…
        fake.runStateValue = "failed"          // …and the server says: it died
        fake.runStateError = "Error: thread/resume failed: thread X already has an active writer"
        await store.connect()
        await store.send("resume the codex thread")
        await TestFactory.settle()

        let shown = store.messages.map(\.text).joined(separator: " | ")
        XCTAssertTrue(shown.contains("active writer"),
                      "the failed run's reason must reach the user; got: \(shown)")
        XCTAssertNil(store.activeRunId, "a confirmed-failed run releases the session")
        await store.disconnect()
    }

    /// codex's one-writer refusal parks the turn as a takeover offer; taking
    /// over frees the thread on the Mac and resends the same text — no retyping.
    func testR2_lockedCodexThreadOffersTakeoverAndResends() async throws {
        let fake = FakeSSH()
        var profile = TestFactory.profile()
        profile.runMode = true
        let store = ChatStore(profile: profile, secret: "secret",
                              resumeSessionId: "sess-A", ssh: fake)
        fake.script("pervio-sessions usage", "{}")
        fake.startRunId = "run-42"
        fake.runEvents = []
        fake.runStateValue = "failed"
        fake.runStateError = "Error: thread/resume failed: thread sess-A already has an active writer"
        await store.connect()
        await store.send("continue the experiment")
        await TestFactory.settle()
        XCTAssertEqual(store.takeoverOffer?.text, "continue the experiment", "the refused turn is parked")

        fake.takeoverResult = (true, "killed", "")
        fake.runStateValue = ""                        // the resend stays detached-alive
        await store.takeover()
        await TestFactory.settle()
        XCTAssertEqual(fake.callCount("codexTakeover"), 1)
        XCTAssertEqual(fake.callCount("startRun"), 2, "the parked text is resent after takeover")
        XCTAssertNil(store.takeoverOffer)
        await store.disconnect()
    }

    /// A refused takeover (the holder isn't codex, or it's our own run) keeps
    /// the offer and sends nothing.
    func testR2_refusedTakeoverKeepsTheOffer() async throws {
        let fake = FakeSSH()
        var profile = TestFactory.profile()
        profile.runMode = true
        let store = ChatStore(profile: profile, secret: "secret",
                              resumeSessionId: "sess-A", ssh: fake)
        fake.script("pervio-sessions usage", "{}")
        fake.startRunId = "run-42"
        fake.runEvents = []
        fake.runStateValue = "failed"
        fake.runStateError = "thread sess-A already has an active writer"
        await store.connect()
        await store.send("go")
        await TestFactory.settle()
        fake.takeoverResult = (false, "own-run", "codex (pid 7)")
        await store.takeover()
        XCTAssertNotNil(store.takeoverOffer, "a refusal leaves the offer in place")
        XCTAssertEqual(fake.callCount("startRun"), 1, "nothing is resent")
        XCTAssertTrue(store.messages.map(\.text).joined().contains("own-run"))
        await store.disconnect()
    }

    func testR2_decodeRunsKeepsWellFormedOutputExact() throws {
        let runs = try SSHService.decodeRuns(Fixture.text("runs-list"))
        XCTAssertEqual(runs.map(\.runId), ["a10000000002", "a10000000001", "a10000000003"])
        XCTAssertEqual(runs.filter(\.isRunning).map(\.runId), ["a10000000002"])
        XCTAssertEqual(try SSHService.decodeRuns("[]").count, 0)
    }
}
