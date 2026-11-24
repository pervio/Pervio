import Foundation

/// Which coding-agent CLI a conversation drives on the server. Pervio normalizes
/// each backend's headless event stream into `AgentEvent` (see AgentEvent.swift)
/// and the server wrappers (pervio-chat / pervio-run) translate the shared
/// `--backend` flag into the right CLI invocation. Default is Claude Code so
/// existing saved profiles and older servers keep working unchanged.
enum AgentBackend: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex
    /// Cursor's `agent -p` (2026-10-14): its stream is translated to Claude's
    /// shape on the Mac (pervio-cursor-stream), so the phone parses it as Claude.
    case cursor

    var id: String { rawValue }

    /// Label for the picker / header.
    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "OpenAI Codex"
        case .cursor: return "Cursor Agent"
        }
    }

    /// Engines that can be pointed at a third-party endpoint (a "provider").
    /// Cursor only speaks to its own account.
    var supportsProviders: Bool { self != .cursor }
    /// Engines with a reasoning-effort knob of their own (Cursor's models encode it).
    var hasEffort: Bool { self != .cursor }

    /// Short tag for compact UI (e.g. the conversation header).
    var tag: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .cursor: return "Cursor"
        }
    }

    /// Asset-catalog image name for the backend's brand logo (vector SVG in
    /// Assets.xcassets). Each mark is its vendor's trademark — see THIRD_PARTY_NOTICES.md.
    var iconAsset: String {
        switch self {
        case .claude: return "claude-code"
        case .codex:  return "codex"
        case .cursor: return "cursor"
        }
    }

    /// One-line description shown under the name in the picker.
    var tagline: String {
        switch self {
        case .claude: return "claude -p · full model & effort control"
        case .codex:  return "codex exec · server's default model"
        case .cursor: return "agent -p · your Cursor account's models"
        }
    }
}
