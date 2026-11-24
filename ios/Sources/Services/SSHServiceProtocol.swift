import Foundation

/// The seam the stores hold their SSH connection through.
///
/// `SSHService` is a real socket: it can't run in a unit test, and the races the
/// stores have to survive (a conversation switched mid-stream, an attachment
/// landing after a reset, a market refresh overtaken by an install) only show up
/// when the answers can be scheduled BY THE TEST. So the stores depend on these
/// protocols instead of the concrete class, and `SSHService` conforms to them
/// with the signatures it already had — no production behavior changes, and the
/// default initializer argument at every call site is still the real thing.
///
/// The surface is deliberately small: each method here is one a store actually
/// calls. Nothing was added for the fake's convenience.

/// The three calls every SSH-driven store shares.
@MainActor
protocol SSHCommanding: AnyObject {
    func connect(profile: ServerProfile, secret: String) async throws
    func disconnect() async
    func runCommand(_ command: String, maxBytes: Int) async throws -> String
}

extension SSHCommanding {
    /// The one-argument form every caller uses (SSHService's own default).
    func runCommand(_ command: String) async throws -> String {
        try await runCommand(command, maxBytes: 8_000_000)
    }
}

/// What `ChatStore` drives: one conversation's turns, history, attachments,
/// detached runs and approvals.
@MainActor
protocol SSHServiceProtocol: SSHCommanding {
    func uploadFile(profile: ServerProfile, data: Data, filename: String,
                    onProgress: ((Double) -> Void)?) async throws -> String
    /// `extraDirs`: folders attached from the phone, handed to the agent as
    /// additional WRITABLE working directories (2026-10-17).
    func chatStream(profile: ServerProfile, prompt: String, resume: String?,
                    approveSid: String?, pervioContext: Bool, stopTag: String?, extraDirs: [String])
        -> AsyncThrowingStream<AgentEvent, Error>
    func startRun(profile: ServerProfile, prompt: String, resume: String?, approveSid: String?,
                  pervioContext: Bool, extraDirs: [String]) async throws -> String
    func tailRun(profile: ServerProfile, runId: String, from: Int)
        -> AsyncThrowingStream<AgentEvent, Error>
    func listRuns(profile: ServerProfile, dir: String?) async throws -> [RunInfo]
    func runState(profile: ServerProfile, runId: String) async -> (state: String, error: String)
    func codexTakeover(profile: ServerProfile, session: String) async throws
        -> (released: Bool, reason: String, holder: String)
    func groupCreate(profile: ServerProfile, dir: String, payload: Data) async throws -> ChatGroup
    func groupList(profile: ServerProfile, dir: String) async throws -> [ChatGroup]
    func groupGet(profile: ServerProfile, id: String) async throws -> ChatGroup
    func groupSay(profile: ServerProfile, id: String, text: String, to: String, pervioContext: Bool) async throws -> ChatGroup
    /// Duo mode: hand window `by` the LAST reply of window `of` with a request
    /// to critique it; `extra` is the person's own note, may be empty.
    func groupCritique(profile: ServerProfile, id: String, by: String, of: String, extra: String) async throws -> ChatGroup
    /// Change one member's knobs (model / effort / perm / sandbox) from the next run on.
    func groupSet(profile: ServerProfile, id: String, to: String, payload: Data) async throws -> ChatGroup
    /// Watch mode: the person stops the loop (kills the run it waits on).
    func groupStop(profile: ServerProfile, id: String) async throws -> ChatGroup
    func groupTick(profile: ServerProfile, id: String) async throws -> ChatGroup
    func groupDelete(profile: ServerProfile, id: String) async throws
    func stopRun(profile: ServerProfile, runId: String) async throws
    /// Feed a further message into a living run (2026-10-20); throws when the
    /// run can take nothing (its process ended) — the caller starts a fresh run then.
    func sayRun(profile: ServerProfile, runId: String, prompt: String) async throws
    /// Stop ONE task of a living run (a sub-agent, a background command); the run goes on.
    func stopTask(profile: ServerProfile, runId: String, taskId: String) async throws
    /// "Branch in new chat": the history through the turn the typed message
    /// `afterUuid` starts (its answer included), as a new conversation.
    func forkSession(profile: ServerProfile, dir: String, session: String,
                     afterUuid: String) async throws -> String
    func forkSession(profile: ServerProfile, dir: String, session: String,
                     beforeUuid: String) async throws -> String
    func codexUserTurns(profile: ServerProfile, session: String) async throws -> [SSHService.UserMessageRef]
    func userMessageUuids(profile: ServerProfile, session: String) async throws
        -> [SSHService.UserMessageRef]
    func respondPermission(profile: ServerProfile, sid: String, requestId: String,
                           behavior: String, message: String?) async throws
}

/// What the workflow market and the schedule-creation policy drive.
@MainActor
protocol MarketSSHProtocol: SSHCommanding {
    func listTemplates(profile: ServerProfile) async throws -> [ServerTemplate]
    func listSchedules(profile: ServerProfile) async throws -> [WorkflowSchedule]
    func saveTemplate(profile: ServerProfile, filename: String, json: String) async throws
    /// Delete one of the person's own template files (the market's Mine shelf, 2026-10-20).
    func deleteTemplate(profile: ServerProfile, file: String) async throws
    func scheduleAdd(profile: ServerProfile, spec: WorkflowSpec, name: String,
                     time: String, keepRuns: Int) async throws -> String
    func fireSchedule(profile: ServerProfile, id: String) async throws -> String
}

/// What the Workflows LIST screen drives: the listings plus the writes that can
/// LOSE something — deleting a workflow, removing a schedule, turning one off.
@MainActor
protocol WorkflowListSSHProtocol: SSHCommanding {
    func listWorkflows(profile: ServerProfile) async throws -> [WorkflowSummary]
    func listSchedules(profile: ServerProfile) async throws -> [WorkflowSchedule]
    func setScheduleEnabled(profile: ServerProfile, id: String, enabled: Bool) async throws
    func removeSchedule(profile: ServerProfile, id: String) async throws
    /// Move a saved schedule to another daily time; the id stays (2026-10-20).
    func updateScheduleTime(profile: ServerProfile, id: String, time: String) async throws
    func fireSchedule(profile: ServerProfile, id: String) async throws -> String
    func workflowSpec(profile: ServerProfile, wfId: String) async throws -> WorkflowSpec?
    func deleteWorkflow(profile: ServerProfile, wfId: String) async throws
}

/// The real connection satisfies all of it as written — this is a seam, not a
/// refactor.
extension SSHService: SSHServiceProtocol, MarketSSHProtocol, WorkflowListSSHProtocol {}
