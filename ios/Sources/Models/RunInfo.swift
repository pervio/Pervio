import Foundation

/// One detached background run, as reported by `pervio-run list`. A run is one
/// Claude turn executing server-side, decoupled from the live SSH channel.
struct RunInfo: Decodable, Identifiable, Hashable {
    let runId: String
    let sessionId: String     // the Claude session this turn belongs to (for reattach)
    let dir: String           // project dir
    let preview: String       // first line of the prompt — used as the row title
    let started: Int          // unix seconds
    let state: String         // "running" | "done" | "failed"
    let bytes: Int            // size of out.jsonl so far
    let backend: String?      // "" / nil = claude; "codex" = codex (from meta.json)
    /// The group (pervio-group) this run belongs to, "" / nil for a plain run.
    /// The pill counts a group's runs as ONE task.
    let group: String?
    /// The server entry (profile id) on the phone that started this run, so a
    /// tapped completion notification reopens that entry, not the home one.
    let origin: String?
    /// The run has written its result but its process is still alive (Claude
    /// Code waiting on a background task of its own): finished as far as the
    /// person is concerned — not "working" (2026-10-18).
    let replied: Bool
    /// Blocked on this phone's Allow/Deny right now (an unanswered permission_request in its output).
    let waiting: Bool
    /// The approval channel the run was started with — nil for a run that can't ask.
    let approveSid: String?
    /// Still takes a further message (its process and keeper alive): the phone feeds it instead of starting a second process (2026-10-20).
    let accepting: Bool
    /// The engine's own background tasks still pending, as the Mac's keeper last saw them.
    let background: [RunBackgroundTask]
    /// Byte offset in out.jsonl where the run's CURRENT turn starts — a reopen
    /// replays from here, never from 0: a living run's earlier replies are in the
    /// history already, and replaying them onto the last bubble doubled them (2026-10-21).
    let turnFrom: Int
    /// The fed message the engine took last in the turn now open — the replay
    /// starts after it. A copy of the conversation read a moment earlier may
    /// not hold it yet; the chat reads again when it is missing (2026-11-21).
    let lastTaken: String

    enum CodingKeys: String, CodingKey {
        case runId, sessionId, dir, preview, started, state, bytes, backend, group, origin, replied, waiting, approveSid, accepting, background, turnFrom, lastTaken
    }
    // Field-tolerant decode: one malformed record must not throw and take the WHOLE
    // list down with it. The synthesized (all-mandatory) decoder did exactly that —
    // `listRuns` swallows the throw into `[]`, so a single bad meta.json emptied the
    // runs pill AND cleared RunMonitor's prevRunning, silencing every completion
    // banner. Mirrors the per-field `try?` style in Workflow.swift; well-formed rows
    // decode identically. (Records with no usable runId are dropped in `listRuns`.)
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        runId = (try? c.decode(String.self, forKey: .runId)) ?? ""
        sessionId = (try? c.decode(String.self, forKey: .sessionId)) ?? ""
        dir = (try? c.decode(String.self, forKey: .dir)) ?? ""
        preview = (try? c.decode(String.self, forKey: .preview)) ?? ""
        started = (try? c.decode(Int.self, forKey: .started)) ?? 0
        state = (try? c.decode(String.self, forKey: .state)) ?? ""
        bytes = (try? c.decode(Int.self, forKey: .bytes)) ?? 0
        backend = try? c.decode(String.self, forKey: .backend)
        group = try? c.decode(String.self, forKey: .group)
        let o = (try? c.decode(String.self, forKey: .origin)) ?? ""
        origin = o.isEmpty ? nil : o
        replied = (try? c.decode(Bool.self, forKey: .replied)) ?? false
        waiting = (try? c.decode(Bool.self, forKey: .waiting)) ?? false
        let sid = (try? c.decode(String.self, forKey: .approveSid)) ?? ""
        approveSid = sid.isEmpty ? nil : sid
        accepting = (try? c.decode(Bool.self, forKey: .accepting)) ?? false
        background = (try? c.decode([RunBackgroundTask].self, forKey: .background)) ?? []
        turnFrom = (try? c.decode(Int.self, forKey: .turnFrom)) ?? 0
        lastTaken = (try? c.decode(String.self, forKey: .lastTaken)) ?? ""
    }

    var id: String { runId }
    /// The background tasks a person is told about: not the engine's own
    /// housekeeping (`ambient` — "hosts should exclude them from activity indicators").
    var shownBackground: [RunBackgroundTask] { background.filter { !$0.ambient } }
    /// Still working: alive AND not yet replied. A replied-but-alive process is
    /// winding down (its own background task) — done, for the pill and the banners.
    var isRunning: Bool { state == "running" && !replied }
    var isFailed: Bool { state == "failed" }
    var startedDate: Date { Date(timeIntervalSince1970: TimeInterval(started)) }
    var title: String {
        var p = preview
        if p.hasPrefix("<pervio-group"), let end = p.range(of: "</pervio-group>") {
            p = String(p[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return p.isEmpty ? "(no prompt)" : p
    }
    /// Which agent this run drove — so reopening it loads the right transcript
    /// store and labels the pill correctly (default Claude for older runs).
    var agent: AgentBackend { AgentBackend(rawValue: backend ?? "") ?? .claude }
}


/// A background task as `pervio-run list/status` reports it (the keeper's ledger).
/// Everything past the first three is absent from a Mac whose scripts are older
/// than 2026-11-22: such a row is a task of unknown kind with no totals.
struct RunBackgroundTask: Decodable, Hashable {
    let taskId: String
    let description: String
    let startedAt: Int
    /// Claude Code's task_type (local_agent, local_bash, …), as it came.
    let taskType: String
    let agentType: String
    /// The sub-agent that launched it, by task id.
    let parent: String
    /// Housekeeping the engine asks hosts not to show.
    let ambient: Bool
    let tokens: Int?
    let toolUses: Int?
    let activity: String
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        taskId = (try? c.decode(String.self, forKey: .taskId)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        startedAt = (try? c.decode(Int.self, forKey: .startedAt)) ?? 0
        taskType = (try? c.decode(String.self, forKey: .taskType)) ?? ""
        agentType = (try? c.decode(String.self, forKey: .agentType)) ?? ""
        parent = (try? c.decode(String.self, forKey: .parent)) ?? ""
        ambient = (try? c.decode(Bool.self, forKey: .ambient)) ?? false
        tokens = try? c.decode(Int.self, forKey: .tokens)
        toolUses = try? c.decode(Int.self, forKey: .toolUses)
        activity = (try? c.decode(String.self, forKey: .activity)) ?? ""
    }
    enum CodingKeys: String, CodingKey { case taskId, description, startedAt, taskType, agentType, parent, ambient, tokens, toolUses, activity }
}
