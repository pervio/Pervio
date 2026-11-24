import Foundation

/// Single source of truth for the Claude Code knobs the UI exposes, so the
/// profile editor and the in-chat settings sheet can't drift out of sync.

/// Reasoning-effort levels. Headless `claude -p` (which pervio-chat drives)
/// accepts low/medium/high/xhigh/max via `--effort`. "ultracode" (= xhigh +
/// dynamic multi-agent workflow orchestration) is NOT a valid `--effort` value
/// headless; pervio-chat translates it to `--settings '{"ultracode": true}'`.
struct EffortOption: Identifiable, Hashable {
    let value: String   // the --effort value ("" = session default)
    let label: String
    var id: String { value }

    static let all: [EffortOption] = [
        .init(value: "",          label: "Default"),
        .init(value: "low",       label: "Low"),
        .init(value: "medium",    label: "Medium"),
        .init(value: "high",      label: "High"),
        .init(value: "xhigh",     label: "Extra high"),
        .init(value: "max",       label: "Max"),
        .init(value: "ultracode", label: "Ultracode (xhigh + workflows)"),
    ]

    /// Claude's levels as the Mac read them from `claude --help` (the paper's
    /// claudeEfforts, 2026-10-19); the shipped list until a paper arrives.
    @MainActor static var presets: [EffortOption] { ModelMenuStore.shared.claudeEfforts }

    /// The picker rows for a list of levels: Default first, Pervio's own
    /// ultracode last, a level the CLI added but we never named shown capitalised.
    static func menu(levels: [String]) -> [EffortOption] {
        let known = Dictionary(uniqueKeysWithValues: all.map { ($0.value, $0.label) })
        return [all[0]]
            + levels.filter { !$0.isEmpty && $0 != "ultracode" }
                    .map { EffortOption(value: $0, label: known[$0] ?? ($0.prefix(1).uppercased() + $0.dropFirst())) }
            + all.filter { $0.value == "ultracode" }
    }

    static func label(for value: String) -> String {
        all.first { $0.value == value }?.label ?? value
    }
}

/// Model quick-pick presets. `value` is what gets passed to `claude --model`
/// (empty = account default).
struct ModelOption: Identifiable, Hashable {
    let value: String
    let label: String
    var id: String { label }

    /// What new profiles default to and the "recommended" pick. Opus 5 is the
    /// coding default of the 5 family (id verified against the server CLI
    /// 2026-08-06); claude-fable-5 is the most capable overall but has its OWN
    /// weekly pool (the usage line shows it) — worth pinning per conversation
    /// rather than as the everyday default.
    static let recommended = "claude-opus-5"

    /// The menu the pickers show: the Mac's paper (`pervio-orchestrate models`,
    /// read once per connect and cached by ModelMenuStore) — or, before any
    /// server has answered, the built-in list below. Since 2026-09-08 a new
    /// model is one server-side line, not an app release.
    @MainActor static var presets: [ModelOption] { ModelMenuStore.shared.claude }

    /// Cursor's menu (the Mac's paper overrides this; see ModelMenuStore.cursor).
    @MainActor static var cursorPresets: [ModelOption] { ModelMenuStore.shared.cursor }
    static let builtinCursorPresets: [ModelOption] = [
        .init(value: "",                            label: "Cursor auto (empty)"),
        .init(value: "gpt-5.3-codex",               label: "gpt-5.3-codex — Codex 5.3"),
        .init(value: "composer-2.5",                label: "composer-2.5 — Composer 2.5"),
        .init(value: "claude-opus-5-thinking-high", label: "claude-opus-5-thinking-high"),
        .init(value: "gpt-5.6-sol-high",            label: "gpt-5.6-sol-high"),
    ]

    static let builtinPresets: [ModelOption] = [
        .init(value: "claude-opus-5",             label: "claude-opus-5 — recommended"),
        .init(value: "claude-fable-5-1",          label: "claude-fable-5-1 — most capable, own quota"),
        .init(value: "claude-sonnet-5",           label: "claude-sonnet-5"),
        .init(value: "claude-haiku-4-5-20251001", label: "claude-haiku-4-5-20251001"),
        .init(value: "opus",                      label: "opus / sonnet / haiku (server alias)"),
        .init(value: "",                          label: "Account default (empty)"),
    ]
}

/// Model TIERS for WORKFLOW steps only. The server (pervio-orchestrate, via
/// _pervio_lib.MODEL_TIERS) translates these names to a concrete model id at
/// launch, so a saved spec survives model churn — upgrading the fleet is one
/// server-table edit instead of surgery on every schedule. Chat model pickers
/// must NOT offer these: chats go straight to the CLI, which only knows real ids.
struct WorkflowModelTier: Identifiable, Hashable {
    let value: String
    let label: String
    var id: String { value }

    @MainActor static var presets: [WorkflowModelTier] { ModelMenuStore.shared.tiers }

    static let builtinPresets: [WorkflowModelTier] = [
        .init(value: "frontier", label: "frontier — the hardest calls only (own quota, top price)"),
        .init(value: "flagship", label: "flagship — deep judgement (server picks today's best)"),
        .init(value: "balanced", label: "balanced — bulk reading & scoring"),
        .init(value: "fast",     label: "fast — cheap mechanical turns"),
    ]
}

/// Codex model quick-picks (server runs `codex exec --model`). Values are real
/// codex model slugs verified from the server's ~/.codex models cache; empty =
/// the server's codex config default (config.toml `model`).
struct CodexModelOption: Identifiable, Hashable {
    let value: String
    let label: String
    /// The reasoning levels codex's own table lists for this model, and its
    /// default — empty for the built-in floor and for older servers.
    var efforts: [String] = []
    var defaultEffort: String = ""
    /// The model's faster service tier as codex's own table describes it
    /// ("Fast · 2x speed, increased usage"); nil when the model has none.
    var fast: CodexFastTier? = nil
    var id: String { label }

    // Slugs + positioning from ~/.codex/models_cache.json (codex 0.146.1,
    // read 2026-08-06); labels paraphrase the cache's own descriptions.
    // gpt-5.6-sol-wm exists too but is a Work-Mode routing alias, not a pick.
    @MainActor static var presets: [CodexModelOption] { ModelMenuStore.shared.codex }

    static let builtinPresets: [CodexModelOption] = [
        .init(value: "",              label: "Codex config default (empty)"),
        .init(value: "gpt-5.6-sol",   label: "gpt-5.6-sol — frontier"),
        .init(value: "gpt-6-astra",   label: "gpt-6-astra — new (Sep 2026), pick per conversation"),
        .init(value: "gpt-5.6-terra", label: "gpt-5.6-terra — balanced everyday"),
        .init(value: "gpt-5.6-luna",  label: "gpt-5.6-luna — fast, affordable"),
    ]
}

/// Codex reasoning levels (`-c model_reasoning_effort`). `all` is codex's whole
/// enum (none … ultra); what a model really supports comes from codex's own
/// model table through `options(for:menu:)` — gpt-6.1-sol has ultra, luna
/// stops at max, nothing current has none or minimal (2026-10-18). Empty =
/// the model's own default. These are codex's own terms — no mapping from Claude.
struct CodexEffortOption: Identifiable, Hashable {
    let value: String
    let label: String
    var id: String { value }

    static let all: [CodexEffortOption] = [
        .init(value: "",        label: "Default (model's own)"),
        .init(value: "none",    label: "None — no reasoning"),
        .init(value: "minimal", label: "Minimal"),
        .init(value: "low",     label: "Low"),
        .init(value: "medium",  label: "Medium"),
        .init(value: "high",    label: "High"),
        .init(value: "xhigh",   label: "Extra high"),
        .init(value: "max",     label: "Max"),
        .init(value: "ultra",   label: "Ultra"),
    ]

    static func label(for value: String) -> String {
        all.first { $0.value == value }?.label ?? value
    }

    /// The picker's rows for one model: the levels codex's table lists for it,
    /// behind a "Default" that names the model's own default; the whole enum
    /// when the table says nothing (an unknown id, the built-in floor).
    static func options(for model: String, menu: [CodexModelOption]) -> [CodexEffortOption] {
        guard let m = menu.first(where: { $0.value == model && !$0.efforts.isEmpty }) else { return all }
        let def = m.defaultEffort.isEmpty ? "Default (model's own)" : "Default (\(label(for: m.defaultEffort)))"
        return [.init(value: "", label: def)] + m.efforts.map { .init(value: $0, label: label(for: $0)) }
    }
}

/// Cursor's three ways to run, carried on the SAME permissionMode field as
/// Claude's (pervio-chat maps them: plan → --mode plan, bypassPermissions →
/// --force, anything else → Cursor's default). Probed on agent 2026.10.14: the
/// default edits files but runs only allowlisted shell commands; nobody can be
/// asked mid-turn, so there is no "ask" tier.
struct CursorRunMode: Identifiable, Hashable {
    let id: String           // the permissionMode value
    let title: String
    let subtitle: String
    let icon: String
    var isDangerous: Bool = false

    static let all: [CursorRunMode] = [
        .init(id: "plan", title: "Read-only (plan)",
              subtitle: "Reads and proposes a plan — never edits (agent --mode plan)",
              icon: "list.bullet.clipboard"),
        .init(id: "acceptEdits", title: "Edit files, allowlisted commands",
              subtitle: "Cursor's default: edits files; shell only from its allowlist, the rest is refused",
              icon: "chevron.left.forwardslash.chevron.right"),
        .init(id: "bypassPermissions", title: "Run everything — force",
              subtitle: "Every command and edit, no questions (agent --force) · trusted servers only",
              icon: "exclamationmark.triangle.fill", isDangerous: true),
    ]

    /// Any other Claude mode (default/auto) lands on Cursor's default.
    static func named(_ id: String) -> CursorRunMode {
        all.first { $0.id == id } ?? all[1]
    }
}

/// Codex's OWN permission model: a `--sandbox` level (codex has no Claude-style
/// permission modes). Approvals are always off headless — the phone can't answer
/// an approval prompt — so the sandbox is the only thing that limits codex.
/// Verified codex sandbox enum: read-only | workspace-write | danger-full-access.
struct CodexSandboxOption: Identifiable, Hashable {
    let value: String        // the exact --sandbox value
    /// Who settles an approval under this mode: "auto" (codex's own reviewer)
    /// or "user" (the phone). Only workspace-write ever asks, so only the two
    /// rows on that sandbox differ here.
    var reviewer: String = "auto"
    let title: String
    let subtitle: String
    let icon: String         // SF Symbol
    var isDangerous: Bool = false
    var id: String { reviewer == "user" ? value + "+ask" : value }

    // The Codex app's modes, in its order and with its names. Full access is
    // the default (the person's call, 2026-10-18). "Approve for me" is codex's
    // workspace-write sandbox with its own reviewing subagent settling whatever
    // reaches beyond it (app-server approvalsReviewer auto_review); "Ask for
    // approval" is the same sandbox with the phone's Allow/Deny settling it —
    // in a live chat; a detached run has nobody to ask, so the Mac treats it as
    // never asking. Read-only is a hard line nothing lifts.
    static let all: [CodexSandboxOption] = [
        .init(value: "danger-full-access", title: "Full access",
              subtitle: "No sandbox, never asks — the Codex app's default",
              icon: "bolt.fill"),
        .init(value: "workspace-write", title: "Approve for me",
              subtitle: "Stays inside the project folder; Codex's own reviewer decides anything beyond it",
              icon: "chevron.left.forwardslash.chevron.right"),
        .init(value: "workspace-write", reviewer: "user", title: "Ask for approval",
              subtitle: "Stays inside the project folder; anything beyond it waits for your Allow/Deny here (Chat only)",
              icon: "hand.raised"),
        .init(value: "read-only", title: "Read-only",
              subtitle: "Read & plan only — can't edit files or run commands",
              icon: "list.bullet.clipboard"),
    ]

    /// The modes a headless turn can mean (workflow steps): nobody is there to
    /// answer, so "Ask for approval" is not among them.
    static var headless: [CodexSandboxOption] { all.filter { $0.reviewer != "user" } }

    /// The row a profile is on. Unknown values land on the default (full access).
    static func mode(of p: ServerProfile) -> CodexSandboxOption {
        all.first { $0.matches(p) } ?? all[0]
    }

    func matches(_ p: ServerProfile) -> Bool {
        value == p.codexSandbox && (value != "workspace-write" || (p.codexReviewer == "user") == (reviewer == "user"))
    }

    func apply(to p: inout ServerProfile) {
        p.codexSandbox = value
        p.codexReviewer = reviewer
    }
}


/// A codex model's faster service tier, from codex's own model table.
struct CodexFastTier: Hashable {
    let id: String            // the service_tier value codex takes ("priority")
    let name: String          // "Fast"
    let description: String   // "2x speed, increased usage" / "1.5x speed"
}

/// The Fast switch (2026-10-19): which tier a conversation's model offers, and
/// whether the switch reads as on — a conversation that never chose follows
/// the Mac's codex config (`service_tier` in config.toml).
enum CodexSpeed {
    static func tier(model: String, menu: [CodexModelOption], defaultModel: String) -> CodexFastTier? {
        let id = model.isEmpty ? defaultModel : model
        guard !id.isEmpty else { return nil }
        return menu.first { $0.value == id }?.fast
    }
    static func isFast(_ p: ServerProfile, macTier: String) -> Bool {
        let t = p.codexServiceTier.isEmpty ? macTier : p.codexServiceTier
        return !t.isEmpty && t != "default"
    }
}
