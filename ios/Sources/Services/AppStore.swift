import Foundation
import Combine

/// The Claude knobs one conversation remembers — kept per Claude session id so
/// each conversation keeps its own model / effort / run-mode / permission, and
/// changing one doesn't bleed into the others.
struct ConvParams: Codable, Equatable {
    var model: String
    var effort: String
    var runMode: Bool
    var permissionMode: String
    // Optional so params saved before Codex support still decode (nil = absent).
    var codexModel: String?
    var codexEffort: String?
    var codexSandbox: String?
    var codexReviewer: String?
    var codexServiceTier: String?
    // Optional for the same reason: saved before Cursor / providers existed.
    var cursorModel: String?
    var provider: String?

    init(_ p: ServerProfile) {
        model = p.model; effort = p.effort; runMode = p.runMode; permissionMode = p.permissionMode
        codexModel = p.codexModel; codexEffort = p.codexEffort; codexSandbox = p.codexSandbox
        codexReviewer = p.codexReviewer; codexServiceTier = p.codexServiceTier
        cursorModel = p.cursorModel; provider = p.provider
    }
    func apply(to p: inout ServerProfile) {
        // runMode is recorded but NOT applied: Chat/Run is the person's own
        // setting (per server, last choice wins), not a property of the
        // conversation — restoring it flipped a Chat user back to Run on every
        // open (2026-10-16). See AppStore.setRunMode.
        p.model = model; p.effort = effort; p.permissionMode = permissionMode
        if let codexModel { p.codexModel = codexModel }
        if let codexEffort { p.codexEffort = codexEffort }
        if let codexSandbox { p.codexSandbox = codexSandbox }
        if let codexReviewer { p.codexReviewer = codexReviewer }
        if let codexServiceTier { p.codexServiceTier = codexServiceTier }
        if let cursorModel { p.cursorModel = cursorModel }
        if let provider { p.provider = provider }
    }
}

/// Top-level app state: the list of saved server profiles. Non-secret fields
/// persist to UserDefaults; secrets live in the Keychain (see `saveSecret`).
@MainActor
final class AppStore: ObservableObject {
    @Published var profiles: [ServerProfile] = []
    /// Polls background runs for the server you're currently inside (set by
    /// ProjectsView); drives the global "running tasks" pill.
    @Published var activeMonitor: RunMonitor?
    /// Per-conversation knobs, keyed by Claude session id.
    /// What an OLDER build saved per conversation, keyed by the conversation's
    /// id alone. Read only to be moved, one conversation at a time, to
    /// `scopedParams` (see `params(for:on:)`); nothing new is written here.
    @Published var sessionParams: [String: ConvParams] = [:]
    /// A conversation's model / effort / permission, keyed by the computer it
    /// is on AND its id (ConversationState): the same id answered by another
    /// computer is another conversation, with settings of its own.
    @Published private(set) var scopedParams: [String: ConvParams] = [:]
    /// Which server the home screen features (publications card, quick entries).
    /// nil (never chosen) falls back to the first profile — the old behavior.
    @Published var homeProfileId: String?
    /// Set when the user TAPS a notification (AppDelegate → PervioApp);
    /// RootView consumes it (navigates, then clears it back to nil). A one-shot
    /// mailbox, not state: it survives here rather than in the delegate so the
    /// navigation code lives with the NavigationPath it steers.
    @Published var notificationRoute: NotificationRoute?
    /// Phone-local "pin this conversation to the top" state, shared by BOTH
    /// session lists (home Recent + a project's history) so a pin made in one
    /// shows in the other. Its own ObservableObject (views observe IT, not the
    /// AppStore, so a pin re-sorts only the list that shows it); lives here so
    /// there is one instance the whole app reads, alongside the other local
    /// preferences. See PinStore.
    let pins = PinStore()
    private let defaultsKey = "pervio.profiles.v1"
    private let paramsKey = "pervio.sessionParams.v1"
    private let scopedParamsKey = "pervio.convParams.v2"
    private let homeKey = "pervio.homeProfileId.v1"

    init() { load() }

    /// Begin polling runs for `profile` (called when you enter a server). Reuses
    /// the existing monitor if it's already that server.
    func activateRuns(for profile: ServerProfile, secret: String) {
        // The same server, as it is saved now: keep its monitor — and start
        // its poll again if a refusal had stopped it (start() does nothing
        // while one is going).
        if let m = activeMonitor, m.serves(profile, secret: secret) { m.start(); return }
        activeMonitor?.stop()
        let m = RunMonitor(profile: profile, secret: secret)
        m.start()
        activeMonitor = m
    }

    func deactivateRuns() {
        activeMonitor?.stop()
        activeMonitor = nil
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = decoded
        }
        migrateRunModeDefault()
        if let data = UserDefaults.standard.data(forKey: paramsKey),
           let decoded = try? JSONDecoder().decode([String: ConvParams].self, from: data) {
            sessionParams = decoded
        }
        if let data = UserDefaults.standard.data(forKey: scopedParamsKey),
           let decoded = try? JSONDecoder().decode([String: ConvParams].self, from: data) {
            scopedParams = decoded
        }
        migrateCodexFullAccessDefault()
        homeProfileId = UserDefaults.standard.string(forKey: homeKey)
    }

    /// 2026-10-18: Codex's default became full access, as in the Codex app (the
    /// person's call). Profiles and per-conversation params saved under the old
    /// workspace-write default carry it explicitly and would keep the sandbox
    /// forever; lift them once. Read-only was a choice, so it stays.
    private func migrateCodexFullAccessDefault() {
        let key = "pervio.codexSandboxDefault.2026-10"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for i in profiles.indices where profiles[i].codexSandbox == "workspace-write" {
            profiles[i].codexSandbox = "danger-full-access"
        }
        for (sid, p) in sessionParams where p.codexSandbox == "workspace-write" {
            sessionParams[sid]?.codexSandbox = "danger-full-access"
        }
        for (key, p) in scopedParams where p.codexSandbox == "workspace-write" {
            scopedParams[key]?.codexSandbox = "danger-full-access"
        }
        UserDefaults.standard.set(true, forKey: key)
        persist()
        persistParams()
    }

    /// 2026-08-22: Run mode became the DEFAULT. Profiles saved under the old
    /// default carry an explicit `false` that would silently override the new
    /// one, so flip them ONCE; any later manual choice sticks (the flag), and
    /// per-conversation params are never touched.
    private func migrateRunModeDefault() {
        let key = "pervio.runModeDefault.2026-08"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for i in profiles.indices { profiles[i].runMode = true }
        UserDefaults.standard.set(true, forKey: key)
        persist()
    }

    // MARK: Home server

    /// The server the home screen leads with. Falls back to the first profile
    /// when nothing was chosen — or when the chosen profile was deleted.
    var homeProfile: ServerProfile? {
        profiles.first { $0.id.uuidString == homeProfileId } ?? profiles.first
    }

    func setHomeProfile(_ profile: ServerProfile) {
        homeProfileId = profile.id.uuidString
        UserDefaults.standard.set(homeProfileId, forKey: homeKey)
    }

    // MARK: Per-conversation params

    /// The settings saved for conversation `sessionId` ON `profile`'s computer.
    ///
    /// What an older build saved under the id alone goes to the first computer
    /// that opens a conversation of that id, and is gone from the old table —
    /// it can never be handed to a second one. (In every honest case an id
    /// lives on one computer, so the first to ask is its owner. The folders a
    /// conversation may write to and its waiting messages are stricter: with
    /// several computers saved they are not handed over at all — ChatStore.)
    func params(for sessionId: String, on profile: ServerProfile) -> ConvParams? {
        let key = ConversationState.paramsKey(scope: ConversationState.scope(of: profile), sid: sessionId)
        if let own = scopedParams[key] { return own }
        guard let old = sessionParams.removeValue(forKey: sessionId) else { return nil }
        scopedParams[key] = old
        persistParams()
        return old
    }

    /// The chat's session id changed on screen (ChatView's onChange).
    ///
    /// Two very different events look identical from here, and telling them apart
    /// is the whole point:
    ///  * a chat ADOPTED an id (a new chat's first turn, or a fork branching off
    ///    this one) — the knobs on screen are that conversation's, so save them;
    ///  * the user SWITCHED to another conversation — the id changes first and
    ///    nothing has restored the target's settings yet, so the knobs on screen
    ///    still belong to the chat we left. Saving them here overwrote the
    ///    target's own model/effort/permission with a stranger's. Restore the
    ///    target's own (or, if it never chose any, the server's defaults — the
    ///    same rule ChatView.onAppear applies, never another conversation's) and
    ///    write nothing under its id.
    func chatDidChangeSession(_ store: ChatStore) {
        guard let sid = store.sessionId else { return }
        guard !store.consumeConversationSwitch() else {
            restoreKnobs(into: &store.profile, sessionId: sid)
            return
        }
        saveParams(ConvParams(store.profile), for: sid, on: store.profile)
    }

    /// Put a conversation's own knobs back on screen (ChatView.onAppear, and the
    /// switch branch above): what it saved, else the server's defaults — never
    /// another conversation's. Both go through ConvParams.apply so the set of
    /// knobs lives in ONE place: a hand-written field list here once skipped
    /// `provider` (and cursorModel), so re-entering a conversation kept its
    /// vendor model name but dropped the vendor, and the next turn carried
    /// "glm-5.3" to Anthropic — "There's an issue with the selected model"
    /// (2026-10-15, the first provider tester).
    func restoreKnobs(into profile: inout ServerProfile, sessionId: String?) {
        if let sid = sessionId, let saved = params(for: sid, on: profile) {
            saved.apply(to: &profile)
        } else if let server = profiles.first(where: { $0.id == profile.id }) {
            ConvParams(server).apply(to: &profile)
        }
    }

    /// The Chat/Run choice, remembered on the server entry: the composer's toggle
    /// writes it here, every conversation on that server (new or reopened)
    /// starts from it, and nothing else — not a conversation's saved knobs —
    /// overrides it.
    func setRunMode(_ on: Bool, server id: UUID) {
        guard let i = profiles.firstIndex(where: { $0.id == id }), profiles[i].runMode != on else { return }
        profiles[i].runMode = on
        persist()
    }

    /// Remember a conversation's knobs (no-op if unchanged).
    func saveParams(_ p: ConvParams, for sessionId: String, on profile: ServerProfile) {
        let key = ConversationState.paramsKey(scope: ConversationState.scope(of: profile), sid: sessionId)
        let hadOld = sessionParams.removeValue(forKey: sessionId) != nil    // superseded: never to be handed on
        guard scopedParams[key] != p || hadOld else { return }
        scopedParams[key] = p
        persistParams()
    }

    /// Drop a conversation's saved knobs (called when the conversation is deleted).
    func removeParams(for sessionId: String, on profile: ServerProfile) {
        let scope = ConversationState.scope(of: profile)
        // The composer chip's sticky flag and the folder lists live outside the
        // settings table — clear them here too or deleted conversations leak keys.
        for slot in ConversationState.Slot.allCases {
            UserDefaults.standard.removeObject(forKey: ConversationState.key(slot, scope: scope, sid: sessionId))
        }
        let a = scopedParams.removeValue(forKey: ConversationState.paramsKey(scope: scope, sid: sessionId)) != nil
        // What an older build left under the id alone goes too when this is the
        // only computer saved; with several, it may be another one's and stays
        // until that conversation is opened or deleted there.
        var b = false
        if ConversationState.isOnlyScope(scope, profilesData: try? JSONEncoder().encode(profiles)) {
            ConversationState.adoptLegacy(scope: scope, sid: sessionId, sole: false)
            b = sessionParams.removeValue(forKey: sessionId) != nil
        }
        if a || b { persistParams() }
    }

    private func persistParams() {
        if let data = try? JSONEncoder().encode(sessionParams) {
            UserDefaults.standard.set(data, forKey: paramsKey)
        }
        if let data = try? JSONEncoder().encode(scopedParams) {
            UserDefaults.standard.set(data, forKey: scopedParamsKey)
        }
    }

    func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Save a profile, its secret, and any per-hop credentials the editor is
    /// holding — and, just as importantly, throw away the credentials this save
    /// makes meaningless.
    ///
    /// `hopSecrets` is keyed by hop id; an entry that is empty means "leave what
    /// is stored alone", the same blank-means-keep rule the main secret field
    /// has always had (nothing is ever preloaded into a visible field, so a
    /// blank field cannot be read as "erase it").
    ///
    /// Three cleanups happen here rather than in the editor, because this is the
    /// only place that can see the route being REPLACED as well as the one
    /// arriving — the editor can be cancelled, and a cancelled edit must leave
    /// the Keychain exactly as it found it:
    ///   * a hop the user deleted takes its credential with it;
    ///   * a hop switched back to the profile's own credential drops the one it
    ///     no longer uses — a key with nothing pointing at it is a key nobody
    ///     will ever notice is still on the device;
    ///   * (and `delete` below removes the whole route's.)
    func upsert(_ profile: ServerProfile, secret: String?, hopSecrets: [UUID: String] = [:]) {
        let previous = profiles.first(where: { $0.id == profile.id })
        let previousRoute = previous?.route ?? []
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        // "Blank keeps what is stored" holds for the SAME sign-in method only.
        // A secret is one string in one Keychain slot whatever it is: kept
        // across a switch from private key to password, the key's whole text
        // was what went out as the password — to a machine that until then had
        // only ever checked a signature (the 2026-11-22 review). A switch with
        // nothing typed leaves nothing stored; the editor asks for the new one.
        if let secret, !secret.isEmpty {
            Keychain.set(secret, for: profile.id.uuidString)
        } else if let previous, previous.authKind != profile.authKind {
            Keychain.delete(profile.id.uuidString)
        }

        let surviving = Set(profile.route.map(\.id))
        for hop in previousRoute where !surviving.contains(hop.id) {
            Keychain.delete(profile.hopSecretKey(hop))
        }
        for hop in profile.route {
            if hop.hasOwnCredential {
                if let typed = hopSecrets[hop.id], !typed.isEmpty {
                    Keychain.set(typed, for: profile.hopSecretKey(hop))
                } else if let was = previousRoute.first(where: { $0.id == hop.id }), was.auth != hop.auth {
                    Keychain.delete(profile.hopSecretKey(hop))      // the same rule, per hop
                }
            } else {
                Keychain.delete(profile.hopSecretKey(hop))
            }
        }
        persist()
    }

    func delete(_ profile: ServerProfile) {
        profiles.removeAll { $0.id == profile.id }
        Keychain.delete(profile.id.uuidString)
        // The route's own credentials go with the profile that named them.
        // Nothing else can reach them afterwards: the key is built from this
        // profile's id and the hop's, and both are gone.
        for hop in profile.route {
            Keychain.delete(profile.hopSecretKey(hop))
        }
        persist()
    }

    func secret(for profile: ServerProfile) -> String? {
        Keychain.get(profile.id.uuidString)
    }

    /// One hop's own stored credential, or nil. The editor asks only whether it
    /// EXISTS (never to show it), exactly as it does for the profile's secret.
    func hopSecret(for profile: ServerProfile, hop: JumpHop) -> String? {
        Keychain.get(profile.hopSecretKey(hop))
    }
}
