import Foundation
import Combine

/// The model quick-pick menus (chat Claude, chat Codex, workflow tiers), fed by
/// the Mac's paper — `pervio-orchestrate models`, which prints _pervio_lib's
/// tier table and chat menu. Read ONCE per connect (RootView, right after the
/// script handshake), cached in UserDefaults, and served to the pickers through
/// `ModelOption.presets` / `CodexModelOption.presets` / `WorkflowModelTier.presets`.
///
/// WHY. Until 2026-09-08 those lists were compiled into the app, so a new model
/// meant an app release even though nothing about it is app-side knowledge.
/// Now a new model is one line in the Mac's table; the phone learns it on its
/// next connect. Fallbacks, in order: the last cached paper, then the built-in
/// lists — an older server without the verb (or no network) changes nothing.
///
/// A menu changes a few times a year, so this deliberately does NOT ride every
/// list refresh the way the pin ledger does — once per connect is plenty.
@MainActor
final class ModelMenuStore: ObservableObject {
    static let shared = ModelMenuStore()

    struct Payload: Decodable {
        struct Entry: Decodable {
            let id: String; let note: String?
            /// Codex only: the reasoning levels this model supports and its
            /// default, from codex's own table (2026-10-18).
            let efforts: [String]?; let defaultEffort: String?
            /// Codex only: the model's faster service tier (2026-10-19).
            let fast: FastTier?
        }
        struct FastTier: Decodable { let id: String; let name: String?; let description: String? }
        struct Chat: Decodable {
            let claude: [Entry]?; let codex: [Entry]?; let cursor: [Entry]?; let recommended: String?
            /// Claude's effort levels as `claude --help` lists them; codex's
            /// config.toml speed tier and model (2026-10-19).
            let claudeEfforts: [String]?; let codexServiceTier: String?; let codexDefaultModel: String?
        }
        let tiers: [String: String]?
        let chat: Chat?
    }

    @Published private(set) var claude: [ModelOption]
    @Published private(set) var codex: [CodexModelOption]
    /// Cursor's menu is the account's own (`agent models`, cut to one entry per
    /// family on the Mac); "" = auto, Cursor picks.
    @Published private(set) var cursor: [ModelOption]
    @Published private(set) var tiers: [WorkflowModelTier]
    @Published private(set) var recommended: String
    /// Claude's levels, from the CLI's own help on the Mac (2026-10-19).
    @Published private(set) var claudeEfforts: [EffortOption]
    /// The Mac's codex speed setting ("priority" = Fast) and its config model —
    /// what a conversation that chose nothing runs with.
    @Published private(set) var codexServiceTier: String
    @Published private(set) var codexDefaultModel: String

    private let defaults: UserDefaults
    private let cacheKey = "pervio.modelMenu.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        claude = ModelOption.builtinPresets
        codex = CodexModelOption.builtinPresets
        cursor = ModelOption.builtinCursorPresets
        tiers = WorkflowModelTier.builtinPresets
        recommended = ModelOption.recommended
        claudeEfforts = EffortOption.all
        codexServiceTier = ""
        codexDefaultModel = ""
        if let data = defaults.data(forKey: cacheKey) {
            _ = apply(data, persist: false)
        }
    }

    /// Decode one paper and take it over the menus. Pure and tolerant: junk (or
    /// an empty section) changes nothing and returns false; a good paper is
    /// cached so the next launch starts from it.
    @discardableResult
    func apply(_ data: Data, persist: Bool = true) -> Bool {
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { return false }
        var touched = false
        if let c = p.chat?.claude, !c.isEmpty {
            claude = c.map { ModelOption(value: $0.id, label: Self.label($0)) }
                + [ModelOption(value: "", label: "Account default (empty)")]
            touched = true
        }
        if let x = p.chat?.codex, !x.isEmpty {
            codex = [CodexModelOption(value: "", label: "Codex config default (empty)")]
                + x.map { CodexModelOption(value: $0.id, label: Self.label($0),
                                           efforts: $0.efforts ?? [], defaultEffort: $0.defaultEffort ?? "",
                                           fast: $0.fast.map { CodexFastTier(id: $0.id, name: $0.name ?? "Fast", description: $0.description ?? "") }) }
            touched = true
        }
        if let e = p.chat?.claudeEfforts, !e.isEmpty {
            claudeEfforts = EffortOption.menu(levels: e)
            touched = true
        }
        if let t = p.chat?.codexServiceTier { codexServiceTier = t; touched = true }
        if let d = p.chat?.codexDefaultModel { codexDefaultModel = d; touched = true }
        if let cu = p.chat?.cursor, !cu.isEmpty {
            cursor = [ModelOption(value: "", label: "Cursor auto (empty)")]
                + cu.filter { $0.id != "auto" }.map { ModelOption(value: $0.id, label: Self.label($0)) }
            touched = true
        }
        if let t = p.tiers, !t.isEmpty {
            let order = ["frontier", "flagship", "balanced", "fast"]
            let names = order.filter { t[$0] != nil } + t.keys.filter { !order.contains($0) }.sorted()
            tiers = names.map { WorkflowModelTier(value: $0, label: "\($0) — today: \(t[$0] ?? "")") }
            touched = true
        }
        if let r = p.chat?.recommended, !r.isEmpty {
            recommended = r
            touched = true
        }
        if touched && persist { defaults.set(data, forKey: cacheKey) }
        return touched
    }

    private static func label(_ e: Payload.Entry) -> String {
        let n = (e.note ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? e.id : "\(e.id) — \(n)"
    }

    /// Once per connect: ask the Mac for its paper. Best-effort — a server too
    /// old for the verb, or no network, leaves the last good menu in place.
    func refresh(profile: ServerProfile, secret: String,
                 ssh: any SSHCommanding = SSHService()) async {
        do {
            try await ssh.connect(profile: profile, secret: secret)
            let out = try await ssh.runCommand("\(profile.orchestrateLauncher) models")
            await ssh.disconnect()
            if let open = out.firstIndex(of: "{"), let close = out.lastIndex(of: "}"), open <= close {
                _ = apply(Data(String(out[open...close]).utf8))
            }
        } catch {
            await ssh.disconnect()
            NSLog("[Pervio] model menu refresh skipped: %@", String(describing: error))
        }
    }
}
