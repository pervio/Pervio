import Foundation
import Combine

/// A third-party endpoint an engine can be pointed at, as the Mac's roster
/// (pervio-provider) lists it — never with its key. Claude and Codex only.
struct ProviderInfo: Codable, Equatable, Identifiable, Hashable {
    var name: String
    var engine: String
    var label: String
    var baseUrl: String
    var models: [String]
    var defaultModel: String
    var hasKey: Bool
    var source: String
    var wireApi: String?
    /// Which vendor preset and region it was made from, and whether its model
    /// names are the vendor's live answer ("live"), the preset's ("preset") or typed.
    var preset: String?
    var region: String?
    var modelsSource: String?

    var id: String { name }
    var agent: AgentBackend { AgentBackend(rawValue: engine) ?? .claude }
}

/// What a base URL looks like, from its path alone: the Anthropic-compatible
/// shape Claude Code needs (…/anthropic, 通义's claude-code-proxy) or the
/// OpenAI-compatible one Codex needs (…/v1, 智谱's /paas/v4, 通义's
/// compatible-mode). nil when the path says nothing (OpenRouter's bare /api).
/// The form only warns on a mismatch; it never rewrites what was typed.
enum ProviderUrlShape {
    case anthropic, openai
    static func guess(_ url: String) -> ProviderUrlShape? {
        let u = url.trimmingCharacters(in: .whitespaces).lowercased()
        guard let hostEnd = u.range(of: "://") else { return nil }
        let path = u[hostEnd.upperBound...].drop(while: { $0 != "/" })
        if path.contains("anthropic") || path.contains("claude-code-proxy") { return .anthropic }
        if path.contains("/paas/v4") || path.contains("compatible-mode") || path.hasSuffix("/v1") || path.contains("/v1/") || path.contains("/openai") { return .openai }
        return nil
    }
}

/// A vendor people point Claude Code / Codex at, as the Mac's table lists it
/// (_pervio_lib.PROVIDER_PRESETS, checked against the vendors' docs): the
/// Anthropic-compatible URL for Claude, the OpenAI-compatible one for Codex,
/// per region where the vendor splits China / international, plus the model
/// names to start from. The person adds just the key.
struct ProviderPreset: Codable, Identifiable, Hashable {
    struct Region: Codable, Identifiable, Hashable {
        var id: String
        var label: String
        var claudeUrl: String
        var codexUrl: String
        var modelsUrl: String
    }
    var id: String
    var label: String
    var note: String?
    var docs: String?
    var models: [String]
    var defaultModel: String
    var wireApi: String?
    var regions: [Region]

    /// Several regions → the person must pick one (nothing is assumed).
    var needsRegion: Bool { regions.count > 1 }
    func region(_ rid: String) -> Region? {
        if regions.count == 1 && rid.isEmpty { return regions.first }
        return regions.first { $0.id == rid }
    }
    func url(for engine: AgentBackend, region rid: String) -> String? {
        guard let r = region(rid) else { return nil }
        return engine == .codex ? r.codexUrl : r.claudeUrl
    }
}

/// What a Mac actually has installed — `pervio-chat engines`, answered on
/// connect as `{"claude": "<path or empty>", "codex": …, "cursor": …, "tmux": …,
/// "providers": [...]}`. One record per server, cached per phone so the server
/// row can say it before the next connect.
///
/// WHY (2026-10-13, the first outside testers): a codex-only Mac met a profile
/// whose default engine is Claude, and its very first message died with
/// "claude not found" — read by the tester as 未登录. The phone now asks the Mac
/// what it has, flips the profile's default engine to the one installed, and
/// the market greys out templates whose engine is missing on that Mac.
struct EngineProbe: Codable, Equatable {
    var claude: String = ""
    var codex: String = ""
    var cursor: String = ""
    var tmux: String = ""
    var providers: [ProviderInfo] = []
    var presets: [ProviderPreset] = []
    /// Why the Mac could not list providers/presets (pervio-provider missing or
    /// failing) — shown in the add-provider sheet instead of a silent empty menu.
    var probeError: String? = nil
    /// A CURSOR_API_KEY is in the Mac's credentials.env — Cursor's agent then runs
    /// without its keychain login, which an SSH session usually finds locked.
    var cursorKey: Bool = false
    /// Cursor's agent was logged in to its FILE credential store on the Mac
    /// (~/.cursor/auth.json, made by a login whose link the person opened on
    /// the phone) — the store an SSH session can read; no key needed.
    var cursorLogin: Bool = false

    init(claude: String = "", codex: String = "", cursor: String = "", tmux: String = "",
         providers: [ProviderInfo] = [], presets: [ProviderPreset] = [], probeError: String? = nil,
         cursorKey: Bool = false, cursorLogin: Bool = false) {
        self.claude = claude; self.codex = codex; self.cursor = cursor; self.tmux = tmux
        self.providers = providers; self.presets = presets; self.probeError = probeError
        self.cursorKey = cursorKey; self.cursorLogin = cursorLogin
    }

    private enum CodingKeys: String, CodingKey { case claude, codex, cursor, tmux, providers, presets, probeError, cursorKey, cursorLogin }

    /// Field-tolerant: a record cached by an older build (no cursor, no
    /// providers) still decodes; a key the Mac did not send is just empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = (try? c.decode(String.self, forKey: .claude)) ?? ""
        codex = (try? c.decode(String.self, forKey: .codex)) ?? ""
        cursor = (try? c.decode(String.self, forKey: .cursor)) ?? ""
        tmux = (try? c.decode(String.self, forKey: .tmux)) ?? ""
        providers = (try? c.decode([ProviderInfo].self, forKey: .providers)) ?? []
        presets = (try? c.decode([ProviderPreset].self, forKey: .presets)) ?? []
        let err = (try? c.decode(String.self, forKey: .probeError)) ?? ""
        probeError = err.isEmpty ? nil : err
        cursorKey = (try? c.decode(Bool.self, forKey: .cursorKey)) ?? false
        cursorLogin = (try? c.decode(Bool.self, forKey: .cursorLogin)) ?? false
    }

    func has(_ b: AgentBackend) -> Bool {
        switch b {
        case .claude: return !claude.isEmpty
        case .codex:  return !codex.isEmpty
        case .cursor: return !cursor.isEmpty
        }
    }
    var hasTmux: Bool { !tmux.isEmpty }
    var installed: [AgentBackend] { AgentBackend.allCases.filter(has) }

    /// The roster for one engine (Cursor has none).
    func providers(for b: AgentBackend) -> [ProviderInfo] {
        providers.filter { $0.engine == b.rawValue }
    }
    func provider(named name: String) -> ProviderInfo? {
        name.isEmpty ? nil : providers.first { $0.name == name }
    }

    /// Parse the verb's stdout. Tolerant: the JSON object is picked out of
    /// whatever surrounds it (a login banner, an echo from credentials.env);
    /// junk — or an older server answering the verb with its usage error — is nil.
    static func parse(_ out: String) -> EngineProbe? {
        guard let open = out.firstIndex(of: "{"), let close = out.lastIndex(of: "}"),
              open <= close,
              let p = try? JSONDecoder().decode(EngineProbe.self,
                                                from: Data(String(out[open...close]).utf8))
        else { return nil }
        return p
    }

    /// The engine a profile should default to on this Mac: nil when its current
    /// choice is installed (nothing to do), else the first installed engine.
    /// Never points at a missing engine — a Mac with none keeps the profile as
    /// is, and the first message says "claude not found" as before.
    func preferredBackend(over current: AgentBackend) -> AgentBackend? {
        if has(current) { return nil }
        return AgentBackend.allCases.first(where: has)
    }

    /// The server row's one-line inventory: "claude ✓ · codex ✗ · cursor ✗ · tmux ✓".
    var caption: String {
        (AgentBackend.allCases.map { "\($0.rawValue) \(has($0) ? "✓" : "✗")" }
            + ["tmux \(hasTmux ? "✓" : "✗")"]).joined(separator: " · ")
    }
}

@MainActor
final class EngineStore: ObservableObject {
    static let shared = EngineStore()

    /// Keyed by profile id string (a UUID-keyed dictionary would JSON-encode as
    /// a flat array — it round-trips, but reads as nonsense in the defaults).
    @Published private(set) var byProfile: [String: EngineProbe] = [:]

    private let defaults: UserDefaults
    private let cacheKey = "pervio.engines.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: cacheKey),
           let m = try? JSONDecoder().decode([String: EngineProbe].self, from: data) {
            byProfile = m
        }
    }

    func probe(for profile: ServerProfile?) -> EngineProbe? {
        guard let profile else { return nil }
        return byProfile[profile.id.uuidString]
    }

    func record(_ p: EngineProbe, for profile: ServerProfile) {
        byProfile[profile.id.uuidString] = p
        if let data = try? JSONEncoder().encode(byProfile) { defaults.set(data, forKey: cacheKey) }
    }

    /// The roster changed on the Mac (a provider added or removed from the
    /// phone): keep the cached record current without a full re-probe.
    func setProviders(_ providers: [ProviderInfo], for profile: ServerProfile) {
        var p = probe(for: profile) ?? EngineProbe()
        p.providers = providers
        record(p, for: profile)
    }

    /// Once per connect: ask the Mac. Best-effort — a server too old for the
    /// verb, or no network, leaves the last record in place and returns nil.
    @discardableResult
    func refresh(profile: ServerProfile, secret: String,
                 ssh: any SSHCommanding = SSHService()) async -> EngineProbe? {
        do {
            try await ssh.connect(profile: profile, secret: secret)
            let out = try await ssh.runCommand("\(profile.chatLauncher) engines")
            await ssh.disconnect()
            guard let p = EngineProbe.parse(out) else { return nil }
            record(p, for: profile)
            return p
        } catch {
            await ssh.disconnect()
            NSLog("[Pervio] engine probe skipped: %@", String(describing: error))
            return nil
        }
    }
}
