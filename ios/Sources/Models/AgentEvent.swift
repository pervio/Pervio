import Foundation

/// A UI-relevant event distilled from one line of a coding agent's headless
/// NDJSON output. Backend-agnostic: Claude Code's `--output-format stream-json`
/// and OpenAI Codex's `exec --json` both parse into this same set of cases, so
/// ChatStore consumes one event vocabulary regardless of which CLI ran.
///
/// We parse defensively with JSONSerialization and ignore fields we don't care
/// about, so new fields in future CLI versions won't break us.
/// Codex envelope reference: docs/codex-event-schema.md.
enum AgentEvent {
    case initialized(sessionId: String, model: String?)
    case textDelta(String)                                   // streaming assistant text
    case thinkingDelta(String)                               // streaming reasoning
    case toolUse(ToolCall)                                    // model invoked a tool (with detail)
    case toolResult(toolUseId: String, text: String)          // a tool answered (text payload)
    case result(text: String, sessionId: String?, costUSD: Double?, isError: Bool,
                contextWindow: Int?)
    case contextUsage(Int)         // the latest request's input size ≈ context fullness
    case compacting(Bool)          // /compact progress: true = started, false = finished
    case streamError(String)
    case permissionRequest(requestId: String, call: ToolCall)  // a tool is BLOCKED awaiting Allow/Deny
    case permissionResolved(requestId: String)                 // …and was answered (by this phone or earlier)
    /// The engine's own background tasks, as it announces them (Claude Code's
    /// system/background_tasks_changed is the whole pending set; task_notification
    /// says one finished) — the "后台任务" card lives on these (2026-10-20).
    /// Its sub-agents are tasks too, with totals of their own (2026-11-22):
    /// started = one registered (a sub-agent its tool call waits for is in no
    /// pending set), progress = its running totals, update = a patch. What
    /// they add up to is `BackgroundBoard`.
    case backgroundTasks([BackgroundTask])
    case backgroundTaskStarted(BackgroundTask)
    case backgroundTaskProgress(taskId: String, activity: String?, usage: BackgroundTaskUsage?)
    case backgroundTaskUpdate(taskId: String, status: String?, description: String?, backgrounded: Bool?)
    case backgroundTaskDone(taskId: String, status: String, summary: String? = nil, usage: BackgroundTaskUsage? = nil)
    /// The Mac has taken a message fed into the run (`pervio-run say` wrote it
    /// to the stream, words and all) — and, later, the engine has made it part
    /// of the turn (its adapter's word). Between the two the message is in
    /// nobody's record; these are what a phone places it by (2026-11-21).
    case turnSent(String)
    case turnTaken(String)
    case ignored

    /// Parse one NDJSON line for the given backend. Returns multiple events when a
    /// single message carries several content blocks (e.g. two tool calls).
    static func parse(line: String, backend: AgentBackend = .claude) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }

        // Our own marks on the stream, the same for every engine.
        if obj["type"] as? String == "pervio" {
            guard let text = obj["text"] as? String, !text.isEmpty else { return [.ignored] }
            switch obj["subtype"] as? String {
            case "turn_sent":  return [.turnSent(text)]
            case "turn_taken": return [.turnTaken(text)]
            default:           return [.ignored]
            }
        }

        switch backend {
        case .claude: return parseClaude(obj)
        case .codex:  return parseCodex(obj)
        case .cursor: return parseClaude(obj)      // translated on the Mac (pervio-cursor-stream)
        }
    }

    // MARK: Claude Code — `--output-format stream-json`

    private static func parseClaude(_ obj: [String: Any]) -> [AgentEvent] {
        guard let type = obj["type"] as? String else { return [] }

        // A tool is BLOCKED awaiting the user's Allow/Deny — surfaced by pervio-approve in
        // the server's approval mode and tee'd onto this stream. Handle it BEFORE the
        // parent_tool_use_id drop below, so a SUBAGENT's request still reaches the user.
        // Shape: {type:"permission_request", request_id, tool_use_id, tool_name, input}.
        if type == "permission_request" { return permissionRequest(obj) }
        if type == "permission_resolved" { return permissionResolved(obj) }

        // Subagent (Task/Agent) activity carries the spawning tool's id in
        // `parent_tool_use_id`. Desktop Claude Code nests it under the single
        // "Agent" item; we drop it so the subagent's Read/Bash calls don't flatten
        // into the main transcript as a pile of chips. The Agent tool_use itself
        // (in the main thread) has no parent id, so it still shows.
        if obj["parent_tool_use_id"] as? String != nil { return [] }

        switch type {
        case "system":
            let subtype = obj["subtype"] as? String
            if subtype == "init", let sid = obj["session_id"] as? String {
                return [.initialized(sessionId: sid, model: obj["model"] as? String)]
            }
            // `/compact` emits status events: {status:"compacting"} when it starts,
            // then {compact_result:"success"|"failed", compact_error?} when it ends.
            // Surface them so a long compaction shows progress instead of a bare,
            // frozen-looking spinner. (Any failure reason also arrives via `result`.)
            if subtype == "status" {
                if obj["status"] as? String == "compacting" { return [.compacting(true)] }
                if obj["compact_result"] != nil { return [.compacting(false)] }
            }
            if let task = taskEvents(obj) { return task }
            return [.ignored]

        case "stream_event":
            guard let event = obj["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any] else { return [] }
            if delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                return [.textDelta(t)]
            }
            if delta["type"] as? String == "thinking_delta", let t = delta["thinking"] as? String {
                return [.thinkingDelta(t)]
            }
            return []

        case "assistant":
            guard let message = obj["message"] as? [String: Any] else { return [] }
            var events: [AgentEvent] = []
            // Context fullness = the LATEST single request's input size. The
            // `result` event's usage is summed across ALL of a turn's tool-call
            // requests, so it overcounts massively (and pins the ring at 100%);
            // each assistant message reports the real per-request size.
            if let usage = message["usage"] as? [String: Any] {
                let input = (usage["input_tokens"] as? Int) ?? 0
                let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                let ctx = input + cacheCreate + cacheRead
                if ctx > 0 { events.append(.contextUsage(ctx)) }
            }
            // Surface tool calls; text is already streamed via deltas.
            if let content = message["content"] as? [[String: Any]] {
                events += content.compactMap { block -> AgentEvent? in
                    guard block["type"] as? String == "tool_use",
                          let name = block["name"] as? String else { return nil }
                    return .toolUse(makeToolCall(name: name, input: block["input"], id: block["id"] as? String))
                }
            }
            return events

        case "user":
            // Tool results echo back as user-role lines in stream-json. Surface each
            // (tool_use id + text payload) so ChatStore can hang the workflow chip on
            // a pervio_start/pervio_rerun answer; every other result stays invisible
            // in the transcript, exactly as before (ChatStore drops unmatched ones).
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { block -> AgentEvent? in
                guard block["type"] as? String == "tool_result",
                      let id = block["tool_use_id"] as? String, !id.isEmpty else { return nil }
                return .toolResult(toolUseId: id, text: toolResultText(block["content"]))
            }

        case "result":
            let isError = (obj["is_error"] as? Bool) ?? (obj["subtype"] as? String != "success")
            let text = (obj["result"] as? String) ?? ""
            // Note: obj["usage"] here is CUMULATIVE across the turn's requests —
            // not the context size — so we do NOT derive contextTokens from it.
            var contextWindow: Int?
            if let modelUsage = obj["modelUsage"] as? [String: Any] {
                for (_, value) in modelUsage {
                    if let detail = value as? [String: Any], let cw = detail["contextWindow"] as? Int {
                        contextWindow = max(contextWindow ?? 0, cw)
                    }
                }
            }
            return [.result(text: text,
                            sessionId: obj["session_id"] as? String,
                            costUSD: obj["total_cost_usd"] as? Double,
                            isError: isError,
                            contextWindow: contextWindow)]

        default:
            return [.ignored]
        }
    }

    // MARK: OpenAI Codex — `exec --json` (thread / turn / item envelope)
    // All shapes empirically verified; see docs/codex-event-schema.md. Codex does
    // NOT stream text deltas — a whole agent_message arrives once in item.completed,
    // so it appends as one big textDelta (the bubble fills in one shot).

    private static func parseCodex(_ obj: [String: Any]) -> [AgentEvent] {
        guard let type = obj["type"] as? String else { return [.ignored] }
        switch type {
        case "permission_request":
            // Codex over app-server (pervio-codex-app) asks the same way Claude's
            // approval mode does: the Mac blocks the item, puts this line on the
            // stream, and waits for the phone's Allow/Deny (`respond` over the
            // same sid). A command comes as Bash with its command line, a patch
            // outside the workspace as Edit with the root it wants.
            return permissionRequest(obj)
        case "permission_resolved":
            return permissionResolved(obj)

        case "thread.started":
            // thread_id is Codex's resume key (the analogue of Claude's session_id).
            return [.initialized(sessionId: (obj["thread_id"] as? String) ?? "", model: nil)]

        case "turn.started":
            return [.ignored]

        case "system":
            // A Codex sub-agent runs as a thread of its own; pervio-codex-app
            // reports it as a task, in the words Claude Code uses for its own.
            return taskEvents(obj) ?? [.ignored]

        case "item.started", "item.completed":
            // Items reuse the same id across started→completed. We act only on
            // .completed so a tool chip / message isn't emitted twice.
            guard type == "item.completed",
                  let item = obj["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return [.ignored] }
            switch itemType {
            case "agent_message":
                guard let text = item["text"] as? String, !text.isEmpty else { return [.ignored] }
                return [.textDelta(text)]
            case "command_execution":
                let cmd = (item["command"] as? String) ?? ""
                return [.toolUse(ToolCall(
                    name: "Bash",
                    label: "Bash  " + String(cmd.prefix(80)),
                    filePath: nil, oldString: nil, newString: nil, content: nil,
                    command: cmd, toolUseId: item["id"] as? String))]
            case "file_change":
                let changes = (item["changes"] as? [[String: Any]]) ?? []
                let first = changes.first?["path"] as? String
                let kind = changes.first?["kind"] as? String ?? "edit"
                let name = kind == "add" ? "Write" : (kind == "delete" ? "Delete" : "Edit")
                let detail = first.map { shorten($0) } ?? "\(changes.count) file(s)"
                return [.toolUse(ToolCall(
                    name: name,
                    label: "\(name)  \(detail)",
                    filePath: first, oldString: nil, newString: nil, content: nil,
                    command: nil, toolUseId: item["id"] as? String))]
            default:
                return [.ignored]
            }

        case "turn.completed":
            var events: [AgentEvent] = []
            // Codex reports usage only at turn end (no per-message size like Claude),
            // so the context ring updates once per turn from the turn-end totals.
            // `input_tokens` already INCLUDES the cached prefix — codex's
            // `cached_input_tokens` is a breakdown of input, not an addition
            // (real rollouts: total_tokens == input_tokens + output_tokens
            // exactly, cached ≤ input). Unlike claude, whose input_tokens
            // EXCLUDES cache reads/writes so the three ADD up there. Summing
            // input+cached here double-counted the cache and pushed the ring
            // past 100% (a real long chat showed 304017 on a 258400 window).
            if let usage = obj["usage"] as? [String: Any] {
                let ctx = (usage["input_tokens"] as? Int) ?? 0
                if ctx > 0 { events.append(.contextUsage(ctx)) }
            }
            // Terminal event for the turn. Text already arrived via agent_message,
            // so result text is empty (won't overwrite the bubble); costUSD is not
            // reported by codex exec.
            events.append(.result(text: "", sessionId: nil, costUSD: nil,
                                  isError: false, contextWindow: nil))
            return events

        case "error":
            return [.streamError((obj["message"] as? String) ?? "Codex error")]

        case "turn.failed":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? ""
            return [.result(text: msg, sessionId: nil, costUSD: nil,
                            isError: true, contextWindow: nil)]

        default:
            return [.ignored]
        }
    }

    /// A blocked tool awaiting Allow/Deny, in the one shape both engines' server
    /// sides emit: {request_id, tool_use_id, tool_name, input}.
    private static func permissionRequest(_ obj: [String: Any]) -> [AgentEvent] {
        let rid = (obj["request_id"] as? String) ?? (obj["tool_use_id"] as? String) ?? ""
        guard !rid.isEmpty else { return [.ignored] }
        let name = (obj["tool_name"] as? String) ?? "tool"
        var call = makeToolCall(name: name, input: obj["input"], id: obj["tool_use_id"] as? String)
        // What a workflow call would RUN, resolved on the Mac (pervio-approve).
        call.shownSpec = (obj["shown"] as? [String: Any])?["spec_b64"] as? String
        return [.permissionRequest(requestId: rid, call: call)]
    }

    /// The answer to a request — written by the Mac when a decision lands. A
    /// reopened run replays both lines, so the phone can tell an old request
    /// (answered) from one still waiting for it (2026-10-19).
    private static func permissionResolved(_ obj: [String: Any]) -> [AgentEvent] {
        let rid = (obj["request_id"] as? String) ?? ""
        return rid.isEmpty ? [.ignored] : [.permissionResolved(requestId: rid)]
    }

    /// Build a ToolCall (chip label + the detail needed for the diff/detail view).
    private static func makeToolCall(name: String, input: Any?, id: String?) -> ToolCall {
        let inp = input as? [String: Any] ?? [:]
        return ToolCall(
            name: name,
            label: toolSummary(name: name, input: input),
            filePath: inp["file_path"] as? String,
            oldString: inp["old_string"] as? String,
            newString: inp["new_string"] as? String,
            content: name == "Write" ? inp["content"] as? String
                   : name == "ExitPlanMode" ? inp["plan"] as? String : nil,
            command: name == "Bash" ? inp["command"] as? String : nil,
            toolUseId: id,
            mcpInput: name.hasPrefix("mcp__") ? stringifiedInput(inp) : nil
        )
    }

    /// MCP call arguments as displayable strings, so the permission sheet can
    /// summarize a pervio call (template / dir / runId / time…) without touching
    /// the network. Only MCP tools carry this — ordinary tools keep the extracted
    /// fields above.
    private static func stringifiedInput(_ inp: [String: Any]) -> [String: String]? {
        guard !inp.isEmpty else { return nil }
        var out: [String: String] = [:]
        for (k, v) in inp { out[k] = stringify(v) }
        return out
    }

    private static func stringify(_ v: Any) -> String {
        if let n = v as? NSNumber {
            // JSONSerialization booleans are CFBoolean NSNumbers; a plain `as? Bool`
            // would also swallow 0/1 integers (keepRuns: 1 → "true"), so type-check.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if let s = v as? String { return s }
        if let a = v as? [Any] { return a.map(stringify).joined(separator: ", ") }
        return String(describing: v)
    }

    /// A tool_result's text payload: a plain string, or text blocks joined.
    private static func toolResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
    }

    /// Short human-readable label for a tool call, e.g. "Write src/foo.swift".
    private static func toolSummary(name: String, input: Any?) -> String {
        // The plan chip is labeled by what tapping it does (reopen the approval
        // sheet). Must match pervio-sessions' _tool_label byte-for-byte so live and
        // reloaded turns render identically.
        if name == "ExitPlanMode" { return "Plan ready · tap to review" }
        guard let input = input as? [String: Any] else { return name }
        let detail: String?
        switch name {
        case "Read", "Write", "Edit", "NotebookEdit":
            detail = (input["file_path"] as? String).map { shorten($0) }
        case "Bash":
            detail = (input["command"] as? String).map { String($0.prefix(80)) }
        case "Grep":
            detail = input["pattern"] as? String
        case "Glob":
            detail = input["pattern"] as? String
        case "WebFetch", "WebSearch":
            detail = (input["url"] as? String) ?? (input["query"] as? String)
        default:
            detail = nil
        }
        return detail.map { "\(name)  \($0)" } ?? name
    }

    private static func shorten(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count <= 2 ? path : ".../" + parts.suffix(2).joined(separator: "/")
    }

    /// The task events, in Claude Code's own shapes (measured on the real CLI
    /// 2026-10-20 and 2026-11-22) — and the shapes pervio-codex-app speaks for
    /// a Codex sub-agent, so one reading serves both engines. nil when the
    /// line is not about a task.
    private static func taskEvents(_ obj: [String: Any]) -> [AgentEvent]? {
        guard obj["type"] as? String == "system", let subtype = obj["subtype"] as? String else { return nil }
        switch subtype {
        case "background_tasks_changed":
            // The pending BACKGROUND set, whole, whenever it changes. A line
            // with no task list is not a set — read as an empty one it would
            // take every running task off the page (the 2026-11-22 review).
            guard let rows = obj["tasks"] as? [[String: Any]] else { return [.ignored] }
            return [.backgroundTasks(rows.prefix(BackgroundBoard.rowCap).compactMap { backgroundTask($0, foreground: false) })]
        case "task_started":
            // One task registered. `is_backgrounded` false = the tool call that
            // spawned it is waiting for it (how every sub-agent runs where
            // background tasks are off): the pending set will never list it.
            guard let task = backgroundTask(obj, foreground: (obj["is_backgrounded"] as? Bool) == false) else { return [.ignored] }
            return [.backgroundTaskStarted(task)]
        case "task_progress":
            guard let id = obj["task_id"] as? String else { return [.ignored] }
            return [.backgroundTaskProgress(taskId: id, activity: obj["description"] as? String,
                                            usage: BackgroundTaskUsage(obj["usage"]))]
        case "task_updated":
            guard let id = obj["task_id"] as? String else { return [.ignored] }
            let patch = (obj["patch"] as? [String: Any]) ?? [:]
            return [.backgroundTaskUpdate(taskId: id, status: patch["status"] as? String,
                                          description: patch["description"] as? String,
                                          backgrounded: patch["is_backgrounded"] as? Bool)]
        case "task_notification":
            // No status, no ending: "completed" is not a thing to assume.
            guard let id = obj["task_id"] as? String, let status = obj["status"] as? String else { return [.ignored] }
            return [.backgroundTaskDone(taskId: id, status: status,
                                        summary: (obj["summary"] as? String).map { String($0.prefix(BackgroundBoard.summaryCap)) },
                                        usage: BackgroundTaskUsage(obj["usage"]))]
        default:
            return nil
        }
    }

    /// One task as Claude Code describes it — a row of background_tasks_changed
    /// or a task_started, the same fields in both. nil for what the engine
    /// itself marks as housekeeping (`ambient` / `skip_transcript`: "hosts
    /// should exclude them from activity indicators"). `startedAt` is the
    /// phone's clock when it first heard of the task.
    private static func backgroundTask(_ t: [String: Any], foreground: Bool) -> BackgroundTask? {
        guard let id = t["task_id"] as? String, !id.isEmpty else { return nil }
        if (t["ambient"] as? Bool) == true || (t["skip_transcript"] as? Bool) == true { return nil }
        let type = (t["task_type"] as? String) ?? ""
        let parent = (t["parent_task_id"] as? String) ?? ""
        let agentType = (t["subagent_type"] as? String) ?? ""
        return BackgroundTask(id: id, description: String(((t["description"] as? String) ?? type).prefix(BackgroundBoard.textCap)),
                              startedAt: Date(),
                              kind: BackgroundTask.Kind(taskType: type),
                              agentType: agentType.isEmpty ? nil : String(agentType.prefix(80)),
                              parentId: parent.isEmpty ? nil : parent,
                              foreground: foreground)
    }
}
