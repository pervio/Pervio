import Foundation

/// The permission ("run") modes Claude Code actually accepts via
/// `--permission-mode` (verified against claude 2.1.150's `--help` choices:
/// acceptEdits, auto, bypassPermissions, default, dontAsk, plan). Each carries
/// an SF Symbol + description so the UI can mirror Claude Code's mode picker.
struct RunMode: Identifiable, Hashable {
    let id: String          // the exact --permission-mode value
    let title: String
    let subtitle: String
    let icon: String        // SF Symbol name
    var isDangerous: Bool = false

    static let all: [RunMode] = [
        .init(id: "auto", title: "Auto",
              subtitle: "Picks the best permission mode for each task",
              icon: "bolt.fill"),
        .init(id: "default", title: "Ask before edits",
              subtitle: "Claude asks before each edit or command — approve or deny right on your phone.",
              icon: "hand.raised"),
        .init(id: "acceptEdits", title: "Edit automatically",
              subtitle: "Apply file edits without asking",
              icon: "chevron.left.forwardslash.chevron.right"),
        .init(id: "plan", title: "Plan",
              subtitle: "Explore and present a plan before editing — read-only",
              icon: "list.bullet.clipboard"),
        .init(id: "bypassPermissions", title: "Bypass — yolo",
              subtitle: "Run anything without asking · trusted servers only",
              icon: "exclamationmark.triangle.fill", isDangerous: true),
    ]

    static func named(_ id: String) -> RunMode {
        all.first { $0.id == id } ?? all[0]
    }
}
