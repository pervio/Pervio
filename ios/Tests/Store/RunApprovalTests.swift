import XCTest
@testable import Pervio

/// Run mode can ask (2026-10-19): a detached run in an asking tier blocks on
/// this phone's Allow/Deny the way a chat does. The run is started with the
/// turn's approval sid, a reopened run takes the sid from its record, and a
/// replayed, already-answered request never flashes a sheet.
@MainActor
final class RunApprovalTests: XCTestCase {
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
    private func bash(_ cmd: String) -> ToolCall {
        ToolCall(name: "Bash", label: "Bash  " + cmd, filePath: nil, oldString: nil, newString: nil,
                 content: nil, command: cmd, toolUseId: "t1")
    }

    func testARunIsStartedWithTheTurnsApprovalSidAndAWaitingRequestRaisesTheSheet() async throws {
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.permissionRequest(requestId: "r1", call: bash("rm -rf build"))]
        let s = await store(fake)
        let turn = Task { await s.send("do the thing") }
        try await settle { s.pendingPermission != nil }
        let sid = fake.startRunApproveSids.first ?? nil
        XCTAssertNotNil(sid, "the run must carry an approval sid, or the Mac stays headless")
        XCTAssertEqual(s.pendingPermission?.requestId, "r1", "the request raises the Allow/Deny sheet in Run mode")
        XCTAssertEqual(s.pendingPermission?.sid, sid, "the answer goes down the sid the run was started with")
        s.stop(); turn.cancel()
    }

    func testAnAnsweredRequestInTheReplayNeverShowsASheet() async throws {
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.permissionRequest(requestId: "old", call: bash("ls")),
                          .permissionResolved(requestId: "old"),
                          .textDelta("carrying on")]
        let s = await store(fake)
        let turn = Task { await s.send("do the thing") }
        try await Task.sleep(nanoseconds: 700_000_000)                 // past the 300 ms hold
        XCTAssertNil(s.pendingPermission, "answered before the hold fired: no sheet")
        s.stop(); turn.cancel()
    }

    func testAResolutionDismissesTheSheetAlreadyShowing() async throws {
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.permissionRequest(requestId: "r2", call: bash("make"))]
        fake.runEventsAfterResult = [.permissionResolved(requestId: "r2")]   // the Mac's line, 700 ms later
        fake.runEventsAfterResultDelayMs = 700
        let s = await store(fake)
        let turn = Task { await s.send("do the thing") }
        try await settle { s.pendingPermission != nil }
        XCTAssertEqual(s.pendingPermission?.requestId, "r2", "shown once the hold passes")
        try await settle { s.pendingPermission == nil }
        XCTAssertNil(s.pendingPermission, "answered elsewhere (the Mac wrote the resolution): the sheet goes")
        s.stop(); turn.cancel()
    }

    func testReattachTakesTheSidFromTheRunRecord() async throws {
        let fake = FakeSSH()
        fake.runsJSON = #"[{"runId":"run-9","sessionId":"sess-A","dir":"/w","preview":"p","started":1,"state":"running","bytes":1,"replied":false,"waiting":true,"approveSid":"sid-from-mac"}]"#
        fake.runTailStaysOpen = true
        fake.runEvents = [.permissionRequest(requestId: "r3", call: bash("curl x"))]
        let s = await store(fake)
        // The app's open path reattaches and then follows the live tail, which
        // stays open here — so it runs as a task, like a turn does.
        let opening = Task { await s.start() }
        try await settle { s.pendingPermission != nil }
        XCTAssertEqual(s.activeRunId, "run-9", "opening found the running run for this session and reattached")
        XCTAssertEqual(s.pendingPermission?.sid, "sid-from-mac", "the reopened run answers down the sid its record carries")
        s.stop(); opening.cancel()
    }

    func testRunRecordDecodesWaitingAndTheChannel() throws {
        let rows = try SSHService.decodeRuns(#"[{"runId":"a","sessionId":"s","dir":"/w","preview":"p","started":1,"state":"running","bytes":0,"replied":false,"waiting":true,"approveSid":"sid-a"},{"runId":"b","sessionId":"s","dir":"/w","preview":"p","started":1,"state":"running","bytes":0,"replied":false}]"#)
        XCTAssertEqual(rows.map(\.waiting), [true, false])
        XCTAssertEqual(rows.map(\.approveSid), ["sid-a", nil], "an older server's row (no field) still decodes")
        XCTAssertTrue(rows[0].isRunning, "waiting is still running — the pill counts it and names it")
    }

    func testWireCarriesTheSidOnRunsAndTheDeviceOnChats() {
        let svc = SSHService()
        let p = TestFactory.profile()
        let run = svc.buildStartRunCommand(profile: p, prompt: "hi", resume: nil, approveSid: "sid-1", pervioContext: false)
        XCTAssertTrue(run.contains("--approve-sid 'sid-1'"), run)
        let bare = svc.buildStartRunCommand(profile: p, prompt: "hi", resume: nil, pervioContext: false)
        XCTAssertFalse(bare.contains("--approve-sid"), bare)
        let chat = svc.buildChatCommand(profile: p, prompt: "hi", resume: nil, approveSid: "sid-1", pervioContext: false)
        XCTAssertTrue(chat.contains("--device '\(PushTokenStore.currentDeviceId)'"), "the approval ping must find this phone: \(chat)")
    }
}
