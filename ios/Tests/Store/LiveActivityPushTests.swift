import XCTest
@testable import Pervio

/// The Dynamic Island used to keep counting forever after a detached Run finished.
///
/// WHY. Every `Activity.end(...)` call in this app runs INSIDE the app process. Send
/// a Run, leave the app, and iOS suspends us within seconds; when the run finishes
/// on the Mac minutes later there is no Swift code left to end the card. The lock-
/// screen banner still arrived because the Mac sends that one straight to APNs — and
/// that is exactly the channel the island needs too.
///
/// The fix has two halves, and these tests pin both of the ones that can be checked
/// without a physical device:
///
///  1. THE TOKEN GETS TO THE MAC. Each Live Activity has its OWN APNs token. The
///     phone uploads it over the SSH channel it already owns, to
///     `~/.pervio/push/liveactivity/<runId>` — the exact path `pervio-push
///     liveactivity --run <runId>` reads. If either side renames that path the pair
///     silently stops working, so the command is asserted literally here.
///  2. THE SERVER'S PAYLOAD DECODES. ActivityKit decodes `content-state` with a
///     DEFAULT `JSONDecoder` into `RunActivityAttributes.ContentState`, and drops the
///     whole push on any mismatch — silently, with the island left running. The
///     cross-process contract is therefore pinned against the literal JSON
///     `pervio-push` emits.
///
/// Not covered here (it needs a real device + a real Activity): ActivityKit actually
/// minting a token, `pushTokenUpdates` delivering it, and APNs dismissing the card.
@MainActor
final class LiveActivityPushTests: XCTestCase {

    // MARK: - 1. What goes on the wire

    /// 16 bytes 0x01…0x10 → a known hex string, so the assertion is exact.
    private func sampleToken() -> (Data, String) {
        let bytes: [UInt8] = Array(1...16)
        return (Data(bytes), bytes.map { String(format: "%02x", $0) }.joined())
    }

    func testUploadCommand_writesTheTokenWherePervioPushLooksForIt() {
        let cmd = LiveActivityTokenStore.uploadCommand(hexToken: "beef", runId: "run7")
        XCTAssertTrue(cmd.contains("mkdir -p ~/.pervio/push/liveactivity"),
                      "must create the dir pervio-push reads: \(cmd)")
        XCTAssertTrue(cmd.contains("~/.pervio/push/liveactivity/'run7'"),
                      "one file per runId, shell-quoted: \(cmd)")
        XCTAssertTrue(cmd.contains("printf '%s' 'beef'"),
                      "the token is written as bare hex, no newline: \(cmd)")
        XCTAssertTrue(cmd.contains("chmod 700"), "a push token is a credential: \(cmd)")
    }

    func testClearCommand_removesOnlyThatRunsToken() {
        let cmd = LiveActivityTokenStore.clearCommand(runId: "run7")
        XCTAssertTrue(cmd.contains("rm -f ~/.pervio/push/liveactivity/'run7'"),
                      "must delete exactly this run's file: \(cmd)")
        XCTAssertFalse(cmd.contains("-r"), "never recursive — this is one file: \(cmd)")
    }

    func testRunId_sanitizedForTheShellAndFilesystem() {
        // A run id is a server-supplied string used as a FILENAME on the Mac. It can
        // never be allowed to traverse out of the liveactivity dir or reach the shell.
        // Every "/" is gone, so what is left cannot address anything outside the dir.
        XCTAssertEqual(LiveActivityTokenStore.sanitizeRunId("../../.ssh/authorized_keys"),
                       ".....sshauthorized_keys")
        XCTAssertEqual(LiveActivityTokenStore.sanitizeRunId("a b; rm -rf ~"), "abrm-rf")
        XCTAssertEqual(LiveActivityTokenStore.sanitizeRunId(""), "")
        // The real thing — pervio-run's 12 hex chars — passes through untouched.
        XCTAssertEqual(LiveActivityTokenStore.sanitizeRunId("9f2c1ab30de4"), "9f2c1ab30de4")
    }

    // MARK: - 2. How it behaves on the SSH channel

    func testUpload_connectsRunsOneCommandAndDisconnects() async {
        let fake = FakeSSH()
        fake.script("push/liveactivity", "")
        let (token, hex) = sampleToken()

        let did = await LiveActivityTokenStore(ssh: fake)
            .upload(token: token, runId: "9f2c1ab30de4",
                    profile: TestFactory.profile(), secret: "pw")

        XCTAssertTrue(did)
        XCTAssertEqual(fake.calls.first, "connect")
        let writes = fake.commandCalls(containing: "push/liveactivity")
        XCTAssertEqual(writes.count, 1, "exactly one write, got: \(fake.calls)")
        XCTAssertTrue(writes[0].contains("~/.pervio/push/liveactivity/'9f2c1ab30de4'"), writes[0])
        XCTAssertTrue(writes[0].contains(hex), "must send the token's hex: \(writes[0])")
        XCTAssertTrue(fake.calls.contains("disconnect"), "must not leak the connection")
    }

    func testUpload_emptyRunIdIsASilentNoOp() async {
        // No runId means the Mac has no key to file it under — writing anyway would
        // leave an unreachable token behind.
        let fake = FakeSSH()
        let (token, _) = sampleToken()
        let did = await LiveActivityTokenStore(ssh: fake)
            .upload(token: token, runId: "", profile: TestFactory.profile(), secret: "pw")
        XCTAssertFalse(did)
        XCTAssertTrue(fake.calls.isEmpty, "no SSH at all: \(fake.calls)")
    }

    func testUpload_noSecretIsASilentNoOp() async {
        let fake = FakeSSH()
        let (token, _) = sampleToken()
        let did = await LiveActivityTokenStore(ssh: fake)
            .upload(token: token, runId: "run7", profile: TestFactory.profile(), secret: nil)
        XCTAssertFalse(did)
        XCTAssertTrue(fake.calls.isEmpty, "without a secret we can't connect: \(fake.calls)")
    }

    func testUpload_serverFailureIsSwallowedAndReleasesTheConnection() async {
        // Fire-and-forget from the activity's token loop: a dead server must not
        // throw into ActivityKit's async sequence, and must not leak a half-open
        // connection either.
        let fake = FakeSSH()
        fake.connectError = FakeSSH.Boom(message: "server unreachable")
        let (token, _) = sampleToken()
        let did = await LiveActivityTokenStore(ssh: fake)
            .upload(token: token, runId: "run7", profile: TestFactory.profile(), secret: "pw")
        XCTAssertFalse(did)
        XCTAssertTrue(fake.calls.contains("disconnect"), "must still clean up: \(fake.calls)")
    }

    func testClear_removesTheTokenWhenTheActivityEnds() async {
        // A finished activity's token is dead. Left behind, the next `pervio-push
        // liveactivity` for that runId would push at a stale token forever.
        let fake = FakeSSH()
        fake.script("push/liveactivity", "")
        let did = await LiveActivityTokenStore(ssh: fake)
            .clear(runId: "9f2c1ab30de4", profile: TestFactory.profile(), secret: "pw")
        XCTAssertTrue(did)
        let cmds = fake.commandCalls(containing: "push/liveactivity")
        XCTAssertEqual(cmds.count, 1, "\(fake.calls)")
        XCTAssertTrue(cmds[0].contains("rm -f ~/.pervio/push/liveactivity/'9f2c1ab30de4'"), cmds[0])
        XCTAssertTrue(fake.calls.contains("disconnect"))
    }

    func testClear_emptyRunIdNeverTouchesTheServer() async {
        let fake = FakeSSH()
        let did = await LiveActivityTokenStore(ssh: fake)
            .clear(runId: "", profile: TestFactory.profile(), secret: "pw")
        XCTAssertFalse(did)
        XCTAssertTrue(fake.calls.isEmpty, "an empty id must never become `rm -f <dir>/`: \(fake.calls)")
    }

    // MARK: - 3. The server's payload must decode into ContentState

    /// The EXACT `content-state` object `pervio-push liveactivity` puts on the wire
    /// (see server/bin/pervio-push build_activity_payload). Hard-coded rather than
    /// generated: this is a cross-process contract, and a test that derives the JSON
    /// from the Swift type could never catch the two sides drifting apart.
    private let serverEndPayload = """
    {"status":"Done","detail":"","finished":true,"step":0,"stepsDone":0,"stepsTotal":0,"failed":false,"toolIcon":"","toolLine":"","stepETA":0,"stepStartedAt":1786895826}
    """

    func testServerEndPayload_decodesWithADefaultJSONDecoder() throws {
        // ActivityKit uses a plain JSONDecoder and DISCARDS the push on any error —
        // silently, leaving the island exactly as stuck as before the fix.
        let state = try JSONDecoder().decode(RunActivityAttributes.ContentState.self,
                                             from: Data(serverEndPayload.utf8))
        XCTAssertEqual(state.status, "Done")
        XCTAssertEqual(state.detail, "")
        XCTAssertTrue(state.finished, "the island must stop its live timer")
        XCTAssertEqual(state.step, 0)
        XCTAssertFalse(state.failed, "a plain end is a clean finish (green flag, not rust)")
        XCTAssertEqual(state.stepsTotal, 0, "an open-ended end has no known trail length")
        XCTAssertEqual(state.toolLine, "", "a finished card has no 'currently doing'")
        XCTAssertNil(state.currentStepWindow,
                     "and nothing left to fill — a cell still creeping under a done "
                     + "run is the stuck island in another costume")
    }

    func testContentStateKeys_matchTheServerPayloadExactly() throws {
        // Swift's synthesized Codable does NOT apply property defaults on decode, so
        // every stored property has to appear in the server's JSON. Encoding the
        // Swift type and diffing the key sets catches BOTH directions of drift: a new
        // Swift field the server doesn't send, and a renamed one.
        let encoded = try JSONEncoder().encode(
            RunActivityAttributes.ContentState(status: "Done", detail: "", finished: true))
        let swiftKeys = Set((try JSONSerialization.jsonObject(with: encoded)
                             as? [String: Any] ?? [:]).keys)
        let serverKeys = Set((try JSONSerialization.jsonObject(
            with: Data(serverEndPayload.utf8)) as? [String: Any] ?? [:]).keys)
        XCTAssertEqual(swiftKeys, serverKeys,
                       "ContentState and pervio-push's content-state have drifted apart")
    }

    func testContentStateMissingAnOriginalField_failsToDecode() throws {
        // The reason the server MUST send the ORIGINAL keys, pinned as a behavior
        // rather than left as a comment: drop even one (here `step`) and ActivityKit
        // gets nothing. Only the fields added AFTER the contract shipped are optional
        // (next test) — a payload missing `step` is malformed, not merely old.
        let partial = Data(#"{"status":"Done","detail":"","finished":true,"stepsDone":0,"stepsTotal":0,"failed":false}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(RunActivityAttributes.ContentState.self, from: partial),
            "a defaulted property is still REQUIRED unless init(from:) says otherwise")
    }

    func testPreComboServerPayload_stillDecodes_andSimplyShowsLess() throws {
        // THE COMPATIBILITY CASE. The phone updates through TestFlight and the Mac
        // updates through install.sh, so "new app, old pervio-push" is a normal
        // Tuesday. That old Mac sends the seven keys it knows and nothing else — and
        // with a SYNTHESIZED Codable that push would be dropped on the floor without
        // a word, re-creating the very stuck island this whole leg exists to fix.
        // ContentState decodes the four newer keys with decodeIfPresent, so the card
        // still lands; it just shows less.
        let old = Data(#"{"status":"Ended","detail":"Bash  npm test","finished":false,"step":4,"stepsDone":2,"stepsTotal":6,"failed":false}"#.utf8)
        let state = try JSONDecoder().decode(RunActivityAttributes.ContentState.self, from: old)
        XCTAssertEqual(state.step, 4)
        XCTAssertEqual(state.stepsDone, 2, "the trail still draws")
        XCTAssertEqual(state.toolIcon, "", "no glyph was sent…")
        XCTAssertEqual(state.toolLine, "", "…and no tool row; the island falls back to `detail`")
        XCTAssertEqual(state.stepETA, 0, "no estimate was sent")
        XCTAssertNil(state.currentStepWindow,
                     "and with no step-start there is nothing to fill: an honest blank "
                     + "beats a bar that restarts every time the Lock Screen wakes")
    }

    func testFailedEndPayload_marksTheTerminalStateAsFailure() throws {
        // A stopped/errored run ends with failed:true → the island's rust terminal
        // look (slumped otter, cairn) instead of a green flag.
        let json = #"{"status":"Ended","detail":"","finished":true,"step":4,"stepsDone":2,"stepsTotal":0,"failed":true,"toolIcon":"","toolLine":"","stepETA":0,"stepStartedAt":1786895826}"#
        let state = try JSONDecoder().decode(RunActivityAttributes.ContentState.self,
                                             from: Data(json.utf8))
        XCTAssertTrue(state.finished)
        XCTAssertTrue(state.failed)
    }

    func testUpdatePayload_keepsTheCardRunning() throws {
        // The `update` variant the same server command can send, now carrying the
        // trail counts a workflow update fills in, plus the tool row.
        let json = #"{"status":"3/6 steps done","detail":"Edit ChatView.swift","finished":false,"step":3,"stepsDone":3,"stepsTotal":6,"failed":false,"toolIcon":"terminal","toolLine":"Bash · npm test","stepETA":45,"stepStartedAt":1786895826}"#
        let state = try JSONDecoder().decode(RunActivityAttributes.ContentState.self,
                                             from: Data(json.utf8))
        XCTAssertFalse(state.finished)
        XCTAssertEqual(state.step, 3)
        XCTAssertEqual(state.detail, "Edit ChatView.swift")
        XCTAssertEqual(state.stepsDone, 3)
        XCTAssertEqual(state.stepsTotal, 6, "the trail draws 3 of 6 segments filled")
        XCTAssertEqual(state.toolIcon, "terminal")
        XCTAssertEqual(state.toolLine, "Bash · npm test")
        let window = try XCTUnwrap(state.currentStepWindow)
        XCTAssertEqual(window.lowerBound, Date(timeIntervalSince1970: 1_786_895_826))
        XCTAssertEqual(window.upperBound.timeIntervalSince(window.lowerBound), 45,
                       accuracy: 0.5, "the cell fills over the step's own estimate")
    }

    // MARK: - 3b. The self-filling cell's window

    func testStepETA_fallsBackToAConservativeDefaultWhenNobodyKnows() throws {
        // 0 means "no estimate", not "instant". A zero-length window would be an
        // invalid ProgressView range; a tiny one would slam the cell full in a blink
        // and read as broken. 90s is the dull middle documented on the property.
        let json = #"{"status":"Working…","detail":"","finished":false,"step":1,"stepsDone":0,"stepsTotal":0,"failed":false,"toolIcon":"","toolLine":"","stepETA":0,"stepStartedAt":1786895826}"#
        let state = try JSONDecoder().decode(RunActivityAttributes.ContentState.self,
                                             from: Data(json.utf8))
        XCTAssertEqual(state.etaSeconds, RunActivityAttributes.ContentState.defaultStepETA)
        let window = try XCTUnwrap(state.currentStepWindow)
        XCTAssertGreaterThan(window.upperBound, window.lowerBound,
                             "ClosedRange traps on an inverted bound — this must never be one")
        XCTAssertEqual(RunActivityAttributes.ContentState.defaultStepETA, 90, accuracy: 0.5)
    }

    // MARK: - 3c. What the app puts IN the tool row

    func testToolRow_readsAsOneLine_glyphAndAClippedArgument() {
        // The island has one monospaced line and about forty characters, so the chip
        // label is reshaped: a middot separator, a path clipped from the FRONT (the
        // file name is the informative end) and a command clipped from the BACK.
        let bash = ToolCall(name: "Bash", label: "Bash  npm test", command: "npm test")
        XCTAssertEqual(bash.islandLine, "Bash · npm test")
        XCTAssertEqual(bash.islandIcon, "terminal")

        let read = ToolCall(name: "Read", label: "Read  .../papers/paper_07.pdf")
        XCTAssertEqual(read.islandLine, "Read · .../papers/paper_07.pdf")
        XCTAssertEqual(read.islandIcon, "doc.text")

        let long = ToolCall(name: "Read",
                            label: "Read  .../a-very-long-directory-name/and-another/paper_07.pdf")
        XCTAssertLessThanOrEqual(long.islandLine.count, "Read · ".count + 30)
        XCTAssertTrue(long.islandLine.hasSuffix("paper_07.pdf"),
                      "a path keeps its tail — the file name is the part worth reading: \(long.islandLine)")

        // A multi-line Bash command must not smuggle a newline into a one-line row.
        let multi = ToolCall(name: "Bash", label: "Bash  cd /tmp\nnpm test", command: "x")
        XCTAssertFalse(multi.islandLine.contains("\n"), multi.islandLine)

        // An MCP tool's wire name eats the whole row and names nothing a user knows.
        let mcp = ToolCall(name: "mcp__perviotools__pervio_start", label: "pervio_start")
        XCTAssertEqual(mcp.islandLine, "pervio_start")

        // Anything unmapped still gets the brand's own mark rather than a blank box.
        XCTAssertEqual(ToolCall(name: "Whatever", label: "Whatever").islandIcon,
                       IslandGlyph.step)
    }

    // MARK: - 4. Belt-and-braces: the card expires on its own

    func testStaleDate_capsHowLongTheIslandCanKeepCounting() {
        // The push is the fix; this is the backstop for when it can't land (no APNs
        // key yet, phone offline, token expired). Past the stale date ActivityKit
        // flips the activity to `.stale`, and the widget freezes its timer instead of
        // counting into next week.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let stale = RunLiveActivityController.staleDate(from: start)
        XCTAssertEqual(stale.timeIntervalSince(start),
                       RunLiveActivityController.staleAfter, accuracy: 0.5)
        XCTAssertLessThanOrEqual(RunLiveActivityController.staleAfter, 3600 * 2,
                                 "a stuck island must not outlive a couple of hours")
        XCTAssertGreaterThanOrEqual(RunLiveActivityController.staleAfter, 600,
                                    "but a genuinely long run must not go stale mid-work")
    }
}

/// The compact ring is a CLOCK on a fixed, escalating dial (a 1-minute lap,
/// then 5, then 15, then 15 forever — `ContentState.ringLapSpans`), not an ETA
/// guess: within a lap the system sweeps between two absolute clock times, so
/// the arc's position is exact. It is anchored at the RUN's start — the one
/// timestamp that never moves — because the first shipped version anchored at
/// `stepStartedAt`, which resets on every content update; the moment iOS
/// suspended the app (no more updates) the short first lap swept full and the
/// ring sat parked, observed on-device as "the circle is always full".
/// `ringLap(started:finished:at:)` is the arithmetic; these pin the
/// boundaries, the escalation, the deep-lap plateau, and the guards.
final class RingLapDialTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_786_000_000)   // any fixed instant
    private func lap(_ offset: TimeInterval, finished: Bool = false)
        -> (index: Int, window: ClosedRange<Date>)? {
        RunActivityAttributes.ContentState.ringLap(started: t0, finished: finished,
                                                   at: t0.addingTimeInterval(offset))
    }

    func testFirstLap_isTheFirstMinute() {
        let first = lap(0)
        XCTAssertEqual(first?.index, 0)
        XCTAssertEqual(first?.window.lowerBound, t0)
        XCTAssertEqual(first?.window.upperBound, t0.addingTimeInterval(60))
        XCTAssertEqual(lap(59)?.index, 0, "59s in is still the first lap")
    }

    func testLapBoundaries_escalate_1_5_15() {
        let second = lap(60)
        XCTAssertEqual(second?.index, 1, "the minute boundary starts lap 2")
        XCTAssertEqual(second?.window.lowerBound, t0.addingTimeInterval(60))
        XCTAssertEqual(second?.window.upperBound, t0.addingTimeInterval(360),
                       "the second lap spans five minutes")
        let third = lap(360)
        XCTAssertEqual(third?.index, 2)
        XCTAssertEqual(third?.window.upperBound, t0.addingTimeInterval(1260),
                       "the third lap spans fifteen")
    }

    func testDeepLaps_keepTheFifteenMinuteSpan() {
        let fourth = lap(1260)                 // 60 + 300 + 900 spent → lap 4 begins
        XCTAssertEqual(fourth?.index, 3)
        XCTAssertEqual(fourth.map { $0.window.upperBound.timeIntervalSince($0.window.lowerBound) },
                       900, "past the dial's last span, laps repeat it")
        let deep = lap(1260 + 900 * 5)
        XCTAssertEqual(deep?.index, 8, "five more full laps of 900s")
        XCTAssertEqual(deep.map { $0.window.upperBound.timeIntervalSince($0.window.lowerBound) },
                       900)
    }

    func testSuspendedApp_currentLapStillSweepsLive() {
        // The bug this anchoring fixes, pinned as behavior: the phone locks at
        // minute 3 (last content update long past), someone looks at the island
        // at minute 7 — the lap under their eyes must be MID-SWEEP with real
        // time left, not a 60-second window that expired at the lock screen.
        let looked = lap(7 * 60)
        XCTAssertEqual(looked?.index, 2)
        XCTAssertTrue(looked!.window.contains(t0.addingTimeInterval(7 * 60)),
                      "now falls INSIDE the lap window — the system is still sweeping")
        XCTAssertEqual(looked?.window.upperBound, t0.addingTimeInterval(1260),
                       "…and keeps sweeping unaided until minute 21")
    }

    func testGuards_finishedBlanksAndSkewClamps() {
        XCTAssertNil(lap(30, finished: true),
                     "a finished run has nothing left to sweep")
        XCTAssertEqual(lap(-30)?.index, 0,
                       "clock skew before the start clamps into the first lap")
    }
}
