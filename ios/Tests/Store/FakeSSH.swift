import Foundation
import XCTest
@testable import Pervio

/// A scriptable stand-in for the SSH connection (B2).
///
/// It answers by COMMAND — the same string the store builds and would have put
/// on the wire — so a test never has to know how a call is spelled internally,
/// and a store that changes what it asks for stops matching and fails loudly.
///
/// Three things make the race tests possible:
///  * `gate(...)` holds an answer until the test releases it, so a second flow
///    can be run to completion *inside* the first one's round trip;
///  * `script(...)` / `chatEvents(...)` set what comes back — including malformed
///    JSON and thrown errors;
///  * `calls` records every call in order, so a test can assert what the store
///    did (and didn't) put on the wire.
///
/// Deliberately faithful where fidelity matters: `runCommand` does NOT check
/// `Task.isCancelled` (Citadel's `executeCommand` doesn't either — a cancelled
/// task still gets its answer and runs on), and `chatStream` yields into an
/// unbounded `AsyncThrowingStream` exactly like `SSHService.chatStream`.
@MainActor
final class FakeSSH: SSHServiceProtocol, MarketSSHProtocol, WorkflowListSSHProtocol {

    // MARK: Recording

    /// Every call, in order: `"connect"`, `"run: <command>"`, `"chatStream(...)"`, …
    private(set) var calls: [String] = []
    /// The `pervioContext` flag of each `chatStream` / `startRun` call, in order —
    /// what the composer chip actually put on the wire.
    private(set) var chatPervioFlags: [Bool] = []
    /// The `resume` session id of each `chatStream` call, in order.
    private(set) var chatResumes: [String?] = []
    /// The per-turn approval nonce of each `chatStream` call, in order — the key
    /// an Allow/Deny has to come back on to reach THAT turn's blocked tool.
    private(set) var chatApproveSids: [String?] = []
    /// Prompts handed to `chatStream`, in order (the WIRE text, not the display).
    private(set) var chatPrompts: [String] = []

    func commandCalls(containing needle: String) -> [String] {
        calls.filter { $0.hasPrefix("run: ") && $0.contains(needle) }
    }
    func callCount(_ needle: String) -> Int { calls.filter { $0.contains(needle) }.count }

    // MARK: Scripting

    /// Substring of the command → stdout to answer with. First match wins, so a
    /// later `script` for the same substring overrides the earlier one.
    private var responses: [(needle: String, body: String)] = []
    /// Substring of the command → error to throw instead of answering.
    private var failures: [(needle: String, error: Error)] = []
    /// Substring → the continuation that a `release(...)` resumes.
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var gatedNeedles: Set<String> = []
    /// Substring → continuation waiting for the store to REACH that command.
    private var arrivals: [String: CheckedContinuation<Void, Never>] = [:]
    private var arrived: Set<String> = []

    var connectError: Error?
    private(set) var isConnected = false

    struct Boom: LocalizedError { let message: String
        var errorDescription: String? { message } }

    /// Answer any command containing `needle` with `body`.
    func script(_ needle: String, _ body: String) { responses.insert((needle, body), at: 0) }
    /// Throw for any command containing `needle`.
    func fail(_ needle: String, _ error: Error = Boom(message: "server unreachable")) {
        failures.insert((needle, error), at: 0)
    }
    /// Hold any command containing `needle` until `release(needle)` is called.
    func gate(_ needle: String) { gatedNeedles.insert(needle) }

    /// Let a gated command finish.
    func release(_ needle: String) {
        gatedNeedles.remove(needle)
        gates.removeValue(forKey: needle)?.resume()
    }

    /// Suspend until the store issues a command containing `needle` (so a test can
    /// interleave a second flow exactly inside the first one's round trip).
    func awaitCall(_ needle: String) async {
        if arrived.contains(needle) { return }
        await withCheckedContinuation { arrivals[needle] = $0 }
    }

    private func noteArrival(_ command: String) {
        for needle in Set(arrivals.keys) where command.contains(needle) {
            arrived.insert(needle)
            arrivals.removeValue(forKey: needle)?.resume()
        }
    }

    // MARK: SSHCommanding

    /// Who each `connect` was for, in order — a store that holds two
    /// connections (the chat's, and one to another computer) must dial each
    /// with its own profile and its own secret.
    private(set) var connectedTo: [(profile: ServerProfile, secret: String)] = []

    func connect(profile: ServerProfile, secret: String) async throws {
        calls.append("connect")
        connectedTo.append((profile, secret))
        if let connectError { throw connectError }
        isConnected = true
    }

    func disconnect() async {
        calls.append("disconnect")
        isConnected = false
    }

    func runCommand(_ command: String, maxBytes: Int) async throws -> String {
        calls.append("run: " + command)
        noteArrival(command)
        if let needle = gatedNeedles.first(where: { command.contains($0) }) {
            await withCheckedContinuation { gates[needle] = $0 }
        }
        if let f = failures.first(where: { command.contains($0.needle) }) { throw f.error }
        guard let r = responses.first(where: { command.contains($0.needle) }) else {
            throw Boom(message: "FakeSSH has no script for: \(command)")
        }
        return r.body
    }

    // MARK: Chat / runs

    /// Events the next `chatStream` yields. Each entry is one turn's script; the
    /// nth `chatStream` call plays the nth entry (the last one repeats).
    private var chatScripts: [[AgentEvent]] = []
    /// Event indices the stream stops BEFORE, until `releaseChat()` — models a
    /// turn still streaming while the user does something else.
    private var chatPausePoints: Set<Int> = []
    private var chatGate: CheckedContinuation<Void, Never>?
    private var chatPaused = false
    private var chatPauseWaiters: [CheckedContinuation<Void, Never>] = []

    func chatEvents(_ events: [AgentEvent]) { chatScripts.append(events) }
    /// Hold the stream just BEFORE it yields event `n` (0 = before anything
    /// streams back at all). Can be set several times for one turn.
    func pauseChat(before n: Int) { chatPausePoints.insert(n) }
    func releaseChat() { chatGate?.resume(); chatGate = nil }
    /// Suspend until the stream has reached its pause point.
    func awaitChatPaused() async {
        if chatPaused { return }
        await withCheckedContinuation { chatPauseWaiters.append($0) }
    }

    /// The attached folders of each chatStream / startRun call, in order.
    private(set) var extraDirsSeen: [[String]] = []
    func chatStream(profile: ServerProfile, prompt: String, resume: String?,
                    approveSid: String?, pervioContext: Bool, stopTag: String? = nil, extraDirs: [String] = [])
        -> AsyncThrowingStream<AgentEvent, Error> {
        calls.append("chatStream")
        extraDirsSeen.append(extraDirs)
        chatPervioFlags.append(pervioContext)
        chatResumes.append(resume)
        chatApproveSids.append(approveSid)
        chatPrompts.append(prompt)
        let events = chatScripts.isEmpty ? []
            : chatScripts[min(chatPervioFlags.count - 1, chatScripts.count - 1)]
        let pausePoints = chatPausePoints
        return AsyncThrowingStream { continuation in
            // Same shape as SSHService.chatStream: a Task feeding an unbounded
            // buffer, cancelled through onTermination.
            let task = Task { @MainActor in
                for (i, e) in events.enumerated() {
                    if pausePoints.contains(i) {
                        self.chatPaused = true
                        for w in self.chatPauseWaiters { w.resume() }
                        self.chatPauseWaiters = []
                        await withCheckedContinuation { self.chatGate = $0 }
                        self.chatPaused = false
                    }
                    continuation.yield(e)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var runEvents: [AgentEvent] = []
    var startRunId = "run-1"
    var startRunError: Error?
    var startRunApproveSids: [String?] = []
    func startRun(profile: ServerProfile, prompt: String, resume: String?, approveSid: String?,
                  pervioContext: Bool, extraDirs: [String] = []) async throws -> String {
        calls.append("startRun")
        startRunApproveSids.append(approveSid)
        extraDirsSeen.append(extraDirs)
        chatPervioFlags.append(pervioContext)
        if let startRunError { throw startRunError }
        return startRunId
    }

    /// A run whose process lingers after its result (Claude Code waiting on a
    /// background task of its own): the tail stays open until it is cancelled.
    var runTailStaysOpen = false
    /// What the lingering process says after `runEvents` (a continuation after
    /// its result), delivered after `runEventsAfterResultDelayMs`.
    var runEventsAfterResult: [AgentEvent] = []
    var runEventsAfterResultDelayMs: UInt64 = 0
    /// The byte offsets each tail asked for (a reopen of a living run must ask
    /// for the current turn's start, not 0).
    var tailFroms: [Int] = []
    func tailRun(profile: ServerProfile, runId: String, from: Int)
        -> AsyncThrowingStream<AgentEvent, Error> {
        calls.append("tailRun \(runId)")
        tailFroms.append(from)
        let events = runEvents, later = runEventsAfterResult, delay = runEventsAfterResultDelayMs
        let staysOpen = runTailStaysOpen
        return AsyncThrowingStream { continuation in
            sayContinuation = continuation
            let task = Task { @MainActor in
                for e in events { continuation.yield(e) }
                if !later.isEmpty {
                    if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
                    if !Task.isCancelled { for e in later { continuation.yield(e) } }
                }
                if staysOpen {
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var runs: [RunInfo] = []
    var listRunsError: Error?
    /// Raw `pervio-run list` stdout. When set the fake stands in for the SOCKET
    /// only — the PRODUCTION decode runs on these bytes, so what the store
    /// concludes from a truncated answer is the real thing, not the fake's idea.
    var runsJSON: String?
    func listRuns(profile: ServerProfile, dir: String?) async throws -> [RunInfo] {
        calls.append("listRuns")
        if let listRunsError { throw listRunsError }
        if let runsJSON { return try SSHService.decodeRuns(runsJSON) }
        return runs
    }

    var runStateValue = ""
    var runStateError = ""
    func runState(profile: ServerProfile, runId: String) async -> (state: String, error: String) {
        calls.append("runState"); return (runStateValue, runStateError)
    }

    // Groups ride the scripted runCommand so a test can answer by needle
    // ("pervio-group say", "pervio-group tick"); decoding mirrors SSHService.
    private func group(_ cmd: String) async throws -> ChatGroup {
        let out = try await runCommand(cmd, maxBytes: 8_000_000)
        return try JSONDecoder().decode(ChatGroup.self, from: Data(out.utf8))
    }
    func groupCreate(profile: ServerProfile, dir: String, payload: Data) async throws -> ChatGroup {
        try await group("pervio-group create --dir \(dir) --b64 \(payload.base64EncodedString())")
    }
    func groupList(profile: ServerProfile, dir: String) async throws -> [ChatGroup] {
        let out = try await runCommand("pervio-group list --dir \(dir)", maxBytes: 8_000_000)
        return try JSONDecoder().decode([ChatGroup].self, from: Data(out.utf8))
    }
    func groupGet(profile: ServerProfile, id: String) async throws -> ChatGroup {
        try await group("pervio-group get --id \(id)")
    }
    func groupSay(profile: ServerProfile, id: String, text: String, to: String, pervioContext: Bool) async throws -> ChatGroup {
        try await group("pervio-group say --id \(id) --to \(to)\(pervioContext ? " --pervio-context" : "") --text \(text)")
    }
    func groupCritique(profile: ServerProfile, id: String, by: String, of: String, extra: String) async throws -> ChatGroup {
        try await group("pervio-group say --id \(id) --to \(by) --critique \(of) --text \(extra)")
    }
    func groupSet(profile: ServerProfile, id: String, to: String, payload: Data) async throws -> ChatGroup {
        try await group("pervio-group set --id \(id) --to \(to) --b64 \(payload.base64EncodedString())")
    }
    func groupStop(profile: ServerProfile, id: String) async throws -> ChatGroup {
        try await group("pervio-group stop --id \(id)")
    }
    func groupTick(profile: ServerProfile, id: String) async throws -> ChatGroup {
        try await group("pervio-group tick --id \(id)")
    }
    func groupDelete(profile: ServerProfile, id: String) async throws {
        _ = try await runCommand("pervio-group delete --id \(id)", maxBytes: 8_000_000)
    }

    var takeoverResult: (released: Bool, reason: String, holder: String) = (false, "unheld", "")
    func codexTakeover(profile: ServerProfile, session: String) async throws
        -> (released: Bool, reason: String, holder: String) {
        calls.append("codexTakeover"); return takeoverResult
    }

    func stopRun(profile: ServerProfile, runId: String) async throws { calls.append("stopRun") }
    var stopTaskError: Error?
    func stopTask(profile: ServerProfile, runId: String, taskId: String) async throws {
        calls.append("stopTask \(runId) \(taskId)")
        if let stopTaskError { throw stopTaskError }
    }

    /// A living run: `say` either lands (and the open tail delivers `sayEvents`
    /// as the engine's answer) or throws (the run ended) so the store falls back.
    var sayRunError: Error?
    var sayEvents: [AgentEvent] = []
    private(set) var saidPrompts: [String] = []
    /// How long the Mac's answer to a `say` takes to travel back.
    var sayDelayMs: UInt64 = 0
    /// What the run's stream brings later, down the tail that is open now.
    func pushTail(_ events: [AgentEvent]) { for e in events { sayContinuation?.yield(e) } }
    func sayRun(profile: ServerProfile, runId: String, prompt: String) async throws {
        calls.append("sayRun \(runId)")
        if sayDelayMs > 0 { try? await Task.sleep(nanoseconds: sayDelayMs * 1_000_000) }
        if let sayRunError { throw sayRunError }
        saidPrompts.append(prompt)
        for e in sayEvents { sayContinuation?.yield(e) }
    }
    /// The open tail's continuation, so a `say` can push the engine's answer into it.
    private var sayContinuation: AsyncThrowingStream<AgentEvent, Error>.Continuation?

    var forkedSessionId = "forked-session"
    func forkSession(profile: ServerProfile, dir: String, session: String,
                     beforeUuid: String) async throws -> String {
        calls.append("forkSession \(beforeUuid)"); return forkedSessionId
    }
    func forkSession(profile: ServerProfile, dir: String, session: String,
                     afterUuid: String) async throws -> String {
        calls.append("forkSession after \(afterUuid)"); return forkedSessionId
    }

    var userUuids: [SSHService.UserMessageRef] = []
    func codexUserTurns(profile: ServerProfile, session: String) async throws -> [SSHService.UserMessageRef] {
        calls.append("codexUserTurns \(session)"); return userUuids
    }
    func userMessageUuids(profile: ServerProfile, session: String) async throws
        -> [SSHService.UserMessageRef] {
        calls.append("userMessageUuids \(session)"); return userUuids
    }

    /// Every Allow/Deny that reached the wire, in order — the whole decision, not
    /// just its verb: a decision routed to the wrong turn (`sid`) or the wrong
    /// tool (`requestId`) unblocks something the user never looked at.
    struct PermissionAnswer: Equatable {
        let sid: String, requestId: String, behavior: String, message: String?
    }
    private(set) var permissionAnswers: [PermissionAnswer] = []
    /// Set to make the decision fail to send (mobile SSH drops mid-tap).
    var respondPermissionError: Error?

    func respondPermission(profile: ServerProfile, sid: String, requestId: String,
                           behavior: String, message: String?) async throws {
        calls.append("respondPermission \(behavior)")
        if let respondPermissionError { throw respondPermissionError }
        permissionAnswers.append(PermissionAnswer(sid: sid, requestId: requestId,
                                                  behavior: behavior, message: message))
    }

    // MARK: Uploads

    var uploadedPath = "/home/u/.pervio/uploads/upload.bin"
    /// When set, where each upload "lands", by its file name (two uploads of
    /// one pick must come back as two paths).
    var uploadPathFor: ((String) -> String)?
    var uploadError: Error?
    private(set) var uploadedNames: [String] = []
    /// What went up, in order.
    private(set) var uploadedData: [Data] = []
    func uploadFile(profile: ServerProfile, data: Data, filename: String,
                    onProgress: ((Double) -> Void)?) async throws -> String {
        calls.append("uploadFile \(filename)")
        uploadedNames.append(filename)
        uploadedData.append(data)
        noteArrival("uploadFile \(filename)")
        if let needle = gatedNeedles.first(where: { "uploadFile \(filename)".contains($0) }) {
            await withCheckedContinuation { gates[needle] = $0 }
        }
        if let uploadError { throw uploadError }
        onProgress?(1)
        return uploadPathFor?(filename) ?? uploadedPath
    }

    // MARK: Market / schedules

    var templates: [ServerTemplate] = []
    var schedules: [WorkflowSchedule] = []
    var listTemplatesError: Error?
    /// A server that reflects its own writes: what `saveTemplate` / `scheduleAdd`
    /// wrote on THIS connection also comes back from the listings, so a test
    /// never has to know how the app spells a template filename or a schedule
    /// name — the production code's own choice is what gets listed.
    var echoesItsOwnWrites = false

    func listTemplates(profile: ServerProfile) async throws -> [ServerTemplate] {
        calls.append("listTemplates")
        noteArrival("listTemplates")
        if let needle = gatedNeedles.first(where: { "listTemplates".contains($0) }) {
            await withCheckedContinuation { gates[needle] = $0 }
        }
        if let listTemplatesError { throw listTemplatesError }
        guard echoesItsOwnWrites else { return templates }
        return templates + savedTemplates.map { Self.templateRow(file: $0) }
    }

    func listSchedules(profile: ServerProfile) async throws -> [WorkflowSchedule] {
        calls.append("listSchedules")
        noteArrival("listSchedules")
        if let needle = gatedNeedles.first(where: { "listSchedules".contains($0) }) {
            await withCheckedContinuation { gates[needle] = $0 }
        }
        guard echoesItsOwnWrites else { return schedules }
        return schedules + addedSchedules.map { Self.scheduleRow(id: $0.id, name: $0.name,
                                                                time: $0.time) }
    }

    /// Listing rows are decoded from JSON, the way the real ones arrive.
    private static func templateRow(file: String) -> ServerTemplate {
        let json = #"{"file":"\#(file)","name":"\#(file)","ok":true,"steps":1}"#
        return try! JSONDecoder().decode(ServerTemplate.self, from: Data(json.utf8))
    }
    static func scheduleRow(id: String, name: String, time: String,
                            tz: String = "+0800") -> WorkflowSchedule {
        let json = #"{"id":"\#(id)","name":"\#(name)","time":"\#(time)","enabled":true,"#
            + #""keepRuns":7,"nextDue":0,"lastFiredAt":0,"lastWfId":"","lastStatus":"","#
            + #""lastError":"","tz":"\#(tz)"}"#
        return try! JSONDecoder().decode(WorkflowSchedule.self, from: Data(json.utf8))
    }

    private(set) var savedTemplates: [String] = []
    func saveTemplate(profile: ServerProfile, filename: String, json: String) async throws {
        calls.append("saveTemplate \(filename)")
        savedTemplates.append(filename)
    }

    var deleteTemplateError: Error?
    private(set) var deletedTemplates: [String] = []
    func deleteTemplate(profile: ServerProfile, file: String) async throws {
        calls.append("deleteTemplate \(file)")
        if let deleteTemplateError { throw deleteTemplateError }
        deletedTemplates.append(file)
        templates.removeAll { $0.file == file }
        savedTemplates.removeAll { $0 == file }
    }

    var newScheduleId = "sched-1"
    /// Schedules created on this connection, in order (name/time as the app
    /// chose them).
    private(set) var addedSchedules: [(id: String, name: String, time: String)] = []
    func scheduleAdd(profile: ServerProfile, spec: WorkflowSpec, name: String,
                     time: String, keepRuns: Int) async throws -> String {
        calls.append("scheduleAdd \(name)@\(time)")
        addedSchedules.append((newScheduleId, name, time))
        return newScheduleId
    }

    private(set) var firedSchedules: [String] = []
    func fireSchedule(profile: ServerProfile, id: String) async throws -> String {
        calls.append("fireSchedule \(id)")
        firedSchedules.append(id)
        return "wf-1"
    }

    // MARK: Workflows list (delete / schedules)

    /// What `pervio-orchestrate list` answers. A test sets this to the rows the
    /// SERVER still has — including the case that matters: a delete that failed
    /// yet left nothing in the listing.
    var workflows: [WorkflowSummary] = []
    var listWorkflowsError: Error?
    var deleteWorkflowError: Error?
    var removeScheduleError: Error?
    var setScheduleEnabledError: Error?
    private(set) var deletedWorkflows: [String] = []
    private(set) var removedSchedules: [String] = []
    private(set) var scheduleEnables: [(id: String, enabled: Bool)] = []

    /// A listing row, decoded from JSON the way the real ones arrive.
    static func workflowRow(wfId: String, name: String = "daily report",
                            status: String = "done") -> WorkflowSummary {
        let json = #"{"wfId":"\#(wfId)","name":"\#(name)","status":"\#(status)","#
            + #""startedAt":1000,"scheduleId":""}"#
        return try! JSONDecoder().decode(WorkflowSummary.self, from: Data(json.utf8))
    }

    func listWorkflows(profile: ServerProfile) async throws -> [WorkflowSummary] {
        calls.append("listWorkflows")
        noteArrival("listWorkflows")
        if let listWorkflowsError { throw listWorkflowsError }
        return workflows
    }

    func deleteWorkflow(profile: ServerProfile, wfId: String) async throws {
        calls.append("deleteWorkflow \(wfId)")
        if let deleteWorkflowError { throw deleteWorkflowError }
        deletedWorkflows.append(wfId)
        workflows.removeAll { $0.wfId == wfId }
    }

    func setScheduleEnabled(profile: ServerProfile, id: String, enabled: Bool) async throws {
        calls.append("setScheduleEnabled \(id)=\(enabled)")
        if let setScheduleEnabledError { throw setScheduleEnabledError }
        scheduleEnables.append((id, enabled))
    }

    func removeSchedule(profile: ServerProfile, id: String) async throws {
        calls.append("removeSchedule \(id)")
        if let removeScheduleError { throw removeScheduleError }
        removedSchedules.append(id)
        schedules.removeAll { $0.id == id }
    }

    var updateScheduleTimeError: Error?
    private(set) var scheduleTimes: [(id: String, time: String)] = []
    func updateScheduleTime(profile: ServerProfile, id: String, time: String) async throws {
        calls.append("updateScheduleTime \(id)=\(time)")
        if let updateScheduleTimeError { throw updateScheduleTimeError }
        scheduleTimes.append((id, time))
        schedules = schedules.map { s in
            guard s.id == id, let d = try? JSONSerialization.data(withJSONObject: [
                "id": s.id, "name": s.name, "time": time, "enabled": s.enabled, "keepRuns": s.keepRuns, "nextDue": s.nextDue,
                "lastFiredAt": s.lastFiredAt, "lastWfId": s.lastWfId, "lastStatus": s.lastStatus, "lastError": s.lastError, "tz": s.tz]),
                  let row = try? JSONDecoder().decode(WorkflowSchedule.self, from: d) else { return s }
            return row
        }
    }

    var workflowSpecValue: WorkflowSpec?
    func workflowSpec(profile: ServerProfile, wfId: String) async throws -> WorkflowSpec? {
        calls.append("workflowSpec \(wfId)")
        return workflowSpecValue
    }
}

// MARK: - Shared test helpers

@MainActor
enum TestFactory {
    /// Where the factory profile's computer keeps a conversation's state (ConversationState).
    static func key(_ slot: ConversationState.Slot, _ sid: String) -> String {
        ConversationState.key(slot, scope: ConversationState.scope(of: profile()), sid: sid)
    }

    static func profile(dir: String = "/srv/proj") -> ServerProfile {
        var p = ServerProfile()
        p.name = "test"; p.host = "example.invalid"; p.username = "u"
        p.projectDir = dir
        p.pinnedHostKey = "ssh-ed25519 AAAA"
        // The FIXTURE pins chat mode: most store tests exercise the attached
        // chat path, and the app's factory default flipped to Run on
        // 2026-08-22 (asserted by its own test) — without this pin that flip
        // silently rerouted every fixture turn into the run path.
        p.runMode = false
        return p
    }

    /// A transcript answer shaped exactly like `pervio-sessions transcript`.
    /// `pervio-sessions turns`: the same turns wrapped with their bearings
    /// (total / from / to / files), as the context export reads them (2026-10-17).
    static func turnsWindowJSON(_ turns: [(String, String)], files: [String] = ["/old/proj/.claude/s.jsonl"]) -> String {
        let n = turns.count
        let fs = files.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"total\": \(n), \"from\": \(n == 0 ? 0 : 1), \"to\": \(n), \"files\": [\(fs)], \"turns\": " + transcriptJSON(turns) + "}"
    }

    static func transcriptJSON(_ texts: [(String, String)]) -> String {
        let rows = texts.map { ["role": $0.0, "text": $0.1, "tools": []] as [String: Any] }
        return String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
    }

    /// Let every already-runnable main-actor task make progress.
    static func settle(_ turns: Int = 12) async {
        for _ in 0..<turns { await Task.yield() }
    }
}
