import Foundation

/// A tool invocation with enough detail to render a tappable chip AND a diff /
/// detail view when tapped. Built both live (from the stream-json `tool_use`
/// input) and from loaded history (pervio-sessions blocks).
struct ToolCall: Identifiable, Equatable, Hashable {
    let id = UUID()
    let name: String          // "Edit" | "Write" | "Bash" | "Read" | ...
    let label: String         // chip text, e.g. "Edit  .../Foo.swift"
    var filePath: String?
    var oldString: String?    // Edit / NotebookEdit
    var newString: String?    // Edit / NotebookEdit
    var content: String?      // Write
    var command: String?      // Bash
    var toolUseId: String?    // for lazily fetching the detail from history
    /// Raw call arguments, stringified — carried ONLY for MCP tools (mcp__…), so
    /// the permission sheet can summarize a pervio call (template/dir/runId/time…)
    /// in plain words without a network round-trip. Ordinary tools stay nil.
    var mcpInput: [String: String]? = nil
    /// For a call that would start or schedule a workflow: the workflow as the
    /// Mac says it would run — base64(JSON), from the approval request's
    /// `shown.spec_b64` (pervio-approve). The sheet reads THIS, not the model's
    /// arguments; nil from a Mac whose scripts predate it.
    var shownSpec: String? = nil

    /// We already have the detail in hand (live turns embed it).
    var hasDetail: Bool {
        (oldString != nil && newString != nil) || content != nil || command != nil
    }

    /// The chip is tappable — either the detail is in hand, or we can fetch it on
    /// demand by tool_use id (history turns ship only a lightweight label).
    /// ExitPlanMode is fetchable too: its `content` is the plan text, and tapping
    /// the chip reopens the plan-approval sheet.
    var canShowDetail: Bool {
        hasDetail || (toolUseId != nil && ["Edit", "NotebookEdit", "Write", "Bash", "ExitPlanMode"].contains(name))
    }
}

// MARK: - The Dynamic Island's tool row

extension ToolCall {
    /// The island's bottom line — "Bash · npm test", "Read · .../paper_07.pdf".
    ///
    /// Derived from `label` (the transcript chip's text, which pervio-sessions
    /// produces byte-for-byte the same way) so the island and the transcript can
    /// never disagree about what just ran. Only the shape differs: the island has
    /// ONE monospaced line, no wrapping and about forty characters, so the
    /// separator is a middot and the argument is clipped — from the FRONT for a
    /// path (the file name is the informative end) and from the BACK for a command
    /// (`npm test --coverage …`).
    var islandLine: String {
        let shown = Self.islandName(name)
        let sep = "  "                                  // what toolSummary joins with
        guard label.hasPrefix(name + sep) else { return Self.clip(label, 42, keepTail: false) }
        let arg = String(label.dropFirst(name.count + sep.count))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = Self.clip(arg, 30, keepTail: arg.contains("/"))
        return short.isEmpty ? shown : "\(shown) · \(short)"
    }

    /// The SF Symbol beside it. Shared with the widget (see IslandGlyph) so the
    /// glyph the app stamps into the push and the one the island falls back to
    /// when a payload has none are the same mapping.
    var islandIcon: String { IslandGlyph.forTool(name) }

    /// "mcp__perviotools__pervio_start" → "pervio_start". The full MCP name eats
    /// the whole line and says nothing a user recognises.
    private static func islandName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        return name.components(separatedBy: "__").last ?? name
    }

    /// Clip to `limit`, keeping the tail (paths) or the head (everything else),
    /// with a leading/trailing ellipsis so the cut is visible.
    private static func clip(_ s: String, _ limit: Int, keepTail: Bool) -> String {
        guard s.count > limit else { return s }
        return keepTail ? "…" + String(s.suffix(limit - 1))
                        : String(s.prefix(limit - 1)) + "…"
    }
}

// MARK: - Workflow chip (pervio_start / pervio_rerun → wfId)

extension ToolCall {
    /// Synthetic chip name for a workflow launched from chat: the pervio_start /
    /// pervio_rerun tool_result answered {"wfId": …}, and tapping the chip pushes
    /// the workflow monitor. Not a real agent tool — only we ever mint it.
    static let workflowChipName = "Workflow"

    /// The two MCP tools whose result carries a wfId worth a chip. Correlation is
    /// strict (tool_use id + one of these names), so a stray 12-char string in any
    /// other tool's output can never mint a chip.
    static let workflowLaunchTools: Set<String> =
        ["mcp__perviotools__pervio_start", "mcp__perviotools__pervio_rerun"]

    /// The transcript chip for a freshly launched workflow (wfId kept in `content`).
    static func workflowChip(wfId: String) -> ToolCall {
        ToolCall(name: workflowChipName, label: "\(workflowChipName)  \(wfId)",
                 filePath: nil, oldString: nil, newString: nil,
                 content: wfId, command: nil, toolUseId: nil)
    }

    /// Non-nil (the wfId) when this call IS the workflow chip — drives the
    /// tap-to-monitor push. Validated again here so nothing else can ride it.
    var workflowChipId: String? {
        guard name == Self.workflowChipName, let id = content,
              id.range(of: "^[a-z0-9]{12}$", options: .regularExpression) != nil
        else { return nil }
        return id
    }

    /// The wfId a pervio_start / pervio_rerun tool_result answered with, or nil.
    /// Deliberately narrow: only those two tools' results count, the payload must
    /// JSON-decode to an object with a "wfId" string, and the id must be exactly
    /// 12 chars of [a-z0-9] (pervio-orchestrate's run-id alphabet).
    static func workflowId(fromToolResult text: String, toolName: String) -> String? {
        guard workflowLaunchTools.contains(toolName) else { return nil }
        struct R: Decodable { let wfId: String? }
        guard let r = try? JSONDecoder().decode(R.self, from: Data(text.utf8)),
              let wfId = r.wfId,
              wfId.range(of: "^[a-z0-9]{12}$", options: .regularExpression) != nil
        else { return nil }
        return wfId
    }
}
