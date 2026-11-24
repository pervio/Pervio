import Foundation

// These types mirror `pervio-sessions` / `pervio-run` JSON and are decoded in
// batches (`[ProjectInfo]`, `[SessionSummary]`, `[SessionSearchHit]`,
// `[TranscriptTurn]`). Each uses a
// field-tolerant `init(from:)` (per-field `try?` + default, like Workflow.swift) so
// ONE malformed record can't throw and take the whole batch with it: a bad row in a
// transcript blanked the entire chat on open, and a bad session/project row blanked
// the whole drawer / list. Well-formed rows decode identically; only corrupt or
// future-shaped ones now degrade instead of nuking the batch. An unknown `backend`
// enum value (e.g. a future "gemini") likewise degrades to nil rather than throwing.

/// One project (working directory) Claude Code has sessions for on the server.
/// Mirrors `pervio-sessions projects` JSON.
/// One folder on the home page (`pervio-sessions home`): a project with its
/// newest conversations riding along, so the page needs no second round trip.
struct HomeProject: Codable, Identifiable, Hashable {
    let path: String
    let sessions: Int
    let modified: Int
    let recent: [SessionSummary]

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var modifiedDate: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }

    enum CodingKeys: String, CodingKey { case path, sessions, modified, recent }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        sessions = (try? c.decode(Int.self, forKey: .sessions)) ?? 0
        modified = (try? c.decode(Int.self, forKey: .modified)) ?? 0
        recent = (try? c.decode([SessionSummary].self, forKey: .recent)) ?? []
    }
    /// The same folder with other rows (previews, tests).
    init(copy p: HomeProject, recent: [SessionSummary]) {
        path = p.path; sessions = p.sessions; modified = p.modified; self.recent = recent
    }
}

/// The home page's two blocks in one answer: the folders worked in most
/// recently (the default folder excluded) and the default folder's own chats.
/// `dir` is the default folder as the Mac spells it (absolute), the same
/// spelling the project list uses, so pins made here and in the project's
/// history page share one key.
struct HomeFeed: Codable {
    let dir: String
    let projects: [HomeProject]
    let recent: [SessionSummary]

    enum CodingKeys: String, CodingKey { case dir, projects, recent }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        dir = (try? c.decode(String.self, forKey: .dir)) ?? ""
        projects = (try? c.decode([HomeProject].self, forKey: .projects)) ?? []
        recent = (try? c.decode([SessionSummary].self, forKey: .recent)) ?? []
    }
}

struct ProjectInfo: Codable, Identifiable, Hashable {
    let path: String        // real cwd, e.g. /home/you/myproject
    let sessions: Int
    let modified: Int       // unix seconds

    var id: String { path }
    var modifiedDate: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }

    enum CodingKeys: String, CodingKey { case path, sessions, modified }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        sessions = (try? c.decode(Int.self, forKey: .sessions)) ?? 0
        modified = (try? c.decode(Int.self, forKey: .modified)) ?? 0
    }
}

/// One past conversation. Mirrors `pervio-sessions list` JSON.
struct SessionSummary: Codable, Identifiable, Hashable {
    let id: String          // session UUID (Claude session_id or Codex thread_id)
    let preview: String     // first human message, used as a title
    let modified: Int
    let bytes: Int
    let backend: AgentBackend?   // which agent ran it; nil = older server JSON = Claude
    /// The Mac's pin ledger, stamped on every `list` row (2026-09-08). nil =
    /// an older server that sends no flag — the phone then keeps its cache.
    let pinned: Bool?
    let pinnedAt: Int?
    /// The group (pervio-group) this conversation is a member of — the list
    /// shows the group as one row and hides the members behind it.
    var group: String? = nil
    /// The person's own name for the conversation (pervio-sessions meta), and
    /// the folders it was handed as writable extra directories (2026-10-17).
    var customTitle: String? = nil
    var dirs: [String]? = nil

    /// Resolved backend (older servers don't report it → Claude).
    var agent: AgentBackend { backend ?? .claude }
    var modifiedDate: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }
    var title: String {
        if let t = customTitle, !t.isEmpty { return t }
        return preview.isEmpty ? "(no preview)" : preview
    }

    enum CodingKeys: String, CodingKey { case id, preview, modified, bytes, backend, pinned, pinnedAt, group, dirs; case customTitle = "title" }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        preview = (try? c.decode(String.self, forKey: .preview)) ?? ""
        modified = (try? c.decode(Int.self, forKey: .modified)) ?? 0
        bytes = (try? c.decode(Int.self, forKey: .bytes)) ?? 0
        backend = try? c.decode(AgentBackend.self, forKey: .backend)
        pinned = try? c.decode(Bool.self, forKey: .pinned)
        pinnedAt = try? c.decode(Int.self, forKey: .pinnedAt)
        group = try? c.decode(String.self, forKey: .group)
        customTitle = try? c.decode(String.self, forKey: .customTitle)
        dirs = try? c.decode([String].self, forKey: .dirs)
    }

    /// Memberwise init (the custom `init(from:)` above suppresses the synthesized
    /// one) — used to hand a search hit to the existing attach-context flow.
    init(id: String, preview: String, modified: Int, bytes: Int, backend: AgentBackend?,
         pinned: Bool? = nil, pinnedAt: Int? = nil) {
        self.id = id
        self.preview = preview
        self.modified = modified
        self.bytes = bytes
        self.backend = backend
        self.pinned = pinned
        self.pinnedAt = pinnedAt
    }
}

/// One cross-project full-text search hit. Mirrors `pervio-sessions search` JSON:
/// `[{project, id, backend, modified, snippet, preview}]`, newest first.
struct SessionSearchHit: Codable, Identifiable, Hashable {
    let project: String     // real project cwd, e.g. /home/you/myproject
    let id: String          // session UUID (Claude session_id or Codex thread_id)
    let backend: AgentBackend?   // nil = unknown/future value → treat as Claude
    let modified: Int
    let snippet: String     // ±context around the first true hit (≤160 chars total)
    let preview: String     // the conversation's first human message

    var agent: AgentBackend { backend ?? .claude }
    var modifiedDate: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }
    var projectName: String { (project as NSString).lastPathComponent }

    /// The picked hit as a SessionSummary, so search results ride the SAME
    /// attach flow as browse picks (ChatStore.attachContextAsync). `bytes` isn't
    /// reported by search and isn't used by that flow.
    var summary: SessionSummary {
        SessionSummary(id: id, preview: preview, modified: modified, bytes: 0, backend: backend)
    }

    enum CodingKeys: String, CodingKey { case project, id, backend, modified, snippet, preview }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        project = (try? c.decode(String.self, forKey: .project)) ?? ""
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        backend = try? c.decode(AgentBackend.self, forKey: .backend)
        modified = (try? c.decode(Int.self, forKey: .modified)) ?? 0
        snippet = (try? c.decode(String.self, forKey: .snippet)) ?? ""
        preview = (try? c.decode(String.self, forKey: .preview)) ?? ""
    }
}

/// One turn when loading a transcript. Mirrors `pervio-sessions transcript` JSON.
/// A file a folder's agents read on their own — CLAUDE.md, AGENTS.md, a rules
/// file, a memory note — as `pervio-sessions project-docs` lists them (2026-10-17).
struct ProjectDoc: Codable, Identifiable, Hashable {
    let path: String
    let kind: String      // claude-md | agents-md | rules | cursor-rules | memory
    let name: String
    let bytes: Int
    var id: String { path }
    var isMemory: Bool { kind == "memory" }
}

/// A window of a conversation with its bearings — `pervio-sessions turns`:
/// turns numbered from..to of total, and the record files they came from.
struct TurnsWindow: Decodable {
    let total: Int
    let from: Int
    let to: Int
    let files: [String]
    let turns: [TranscriptTurn]
}

/// One TCP service listening on the Mac, as `pervio-ports list` reports it —
/// what the web preview offers to open (2026-11-06).
struct ListeningPort: Codable, Identifiable, Hashable {
    let port: Int
    /// "loopback" (only the Mac itself can reach it) or "all".
    let bind: String
    let process: String
    let pid: Int
    /// Epoch seconds the process started; 0 when the Mac could not say.
    let since: Int
    var id: Int { port }
    var isLoopback: Bool { bind == "loopback" }
    var sinceDate: Date? { since > 0 ? Date(timeIntervalSince1970: TimeInterval(since)) : nil }

    enum CodingKeys: String, CodingKey { case port, bind, process, pid, since }
    init(port: Int, bind: String, process: String, pid: Int, since: Int) {
        self.port = port; self.bind = bind; self.process = process; self.pid = pid; self.since = since
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        port = (try? c.decode(Int.self, forKey: .port)) ?? 0
        bind = (try? c.decode(String.self, forKey: .bind)) ?? "all"
        process = (try? c.decode(String.self, forKey: .process)) ?? ""
        pid = (try? c.decode(Int.self, forKey: .pid)) ?? 0
        since = (try? c.decode(Int.self, forKey: .since)) ?? 0
    }
}

struct TranscriptTurn: Codable, Hashable {
    let role: String        // "user" | "assistant"
    let text: String
    let tools: [String]
    let thinking: String?   // extended-thinking text (older servers omit it)
    let blocks: [TranscriptBlock]?   // ordered content (older servers omit it)
    /// A user turn delivered by a group (pervio-group): "human" (the shared
    /// message), "synth" (the primary's synthesis request) or "relay" (the
    /// round's conclusion handed to a partner). Absent for the user's own words.
    let via: String?
    /// A user turn sent mid-turn and absorbed into the running reply (the
    /// server reads it from Claude Code's queued_command record). Absent otherwise.
    let mid: Bool?

    enum CodingKeys: String, CodingKey { case role, text, tools, thinking, blocks, via, mid }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        role = (try? c.decode(String.self, forKey: .role)) ?? ""
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        tools = (try? c.decode([String].self, forKey: .tools)) ?? []
        thinking = try? c.decode(String.self, forKey: .thinking)
        blocks = try? c.decode([TranscriptBlock].self, forKey: .blocks)
        via = try? c.decode(String.self, forKey: .via)
        mid = try? c.decode(Bool.self, forKey: .mid)
    }
}

/// One ordered content block of an assistant turn (text / thinking / tool), so
/// the phone renders the turn in execution order instead of clumping.
struct TranscriptBlock: Codable, Hashable {
    let t: String           // "text" | "thinking" | "tool"
    let v: String           // text content, or the tool chip label
    // Tool fields (present only when t == "tool"; older servers omit these). The
    // heavy detail (old/new/content/command) is now fetched lazily by `id`.
    let id: String?         // tool_use id, for the lazy tool-detail fetch
    let name: String?
    let filePath: String?
    let oldString: String?
    let newString: String?
    let content: String?
    let command: String?
    /// The tool's RESULT text — the server attaches it only for the workflow
    /// launch tools (pervio_start/pervio_rerun answer {"wfId": …}), so a reload
    /// can rebuild the tap-to-monitor chip. Older servers omit it.
    let result: String?

    enum CodingKeys: String, CodingKey {
        case t, v, id, name, filePath, oldString, newString, content, command, result
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        t = (try? c.decode(String.self, forKey: .t)) ?? ""
        v = (try? c.decode(String.self, forKey: .v)) ?? ""
        id = try? c.decode(String.self, forKey: .id)
        name = try? c.decode(String.self, forKey: .name)
        filePath = try? c.decode(String.self, forKey: .filePath)
        oldString = try? c.decode(String.self, forKey: .oldString)
        newString = try? c.decode(String.self, forKey: .newString)
        content = try? c.decode(String.self, forKey: .content)
        command = try? c.decode(String.self, forKey: .command)
        result = try? c.decode(String.self, forKey: .result)
    }

    /// Build a ToolCall for the tap-to-see-diff detail view.
    var toolCall: ToolCall {
        ToolCall(name: name ?? "", label: v, filePath: filePath,
                 oldString: oldString, newString: newString,
                 content: content, command: command, toolUseId: id)
    }
}
