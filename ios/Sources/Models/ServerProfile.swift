import Foundation

/// One machine on the way to the target — a single hop of a `ServerProfile`'s
/// route.
///
/// A hop is deliberately NOT a whole profile: it has an address, an identity,
/// and nothing else. The project dir, the model, the permission mode, the
/// backend — all of that belongs to the destination, and a hop that carried
/// those fields would invite the reading that you are "connecting to" a bastion.
/// You are passing through it.
///
/// `pinnedHostKey` is not optional in any meaningful sense: the app refuses to
/// dial a hop it cannot identify, exactly as it refuses an unpinned target. A
/// route is only as trustworthy as its least-identified machine.
struct JumpHop: Identifiable, Codable, Equatable, Hashable {

    /// WHICH credential this hop is authenticated with.
    ///
    /// `.profile` — the default, and what every saved route decodes to — is the
    /// shipped behaviour: one credential (the profile's own Keychain secret)
    /// opens every machine on the way, which is the common bastion setup.
    ///
    /// The other two exist because a real path is not always uniform: a hop in
    /// the middle may accept only ANOTHER key, or only a password. Before this,
    /// such a machine made the whole route impossible — you cannot carry one
    /// private key through a box that has never heard of it — and the failure
    /// arrived as a plain "authentication rejected" on that hop, with no way to
    /// act on it. A per-hop credential is therefore not a convenience; it is the
    /// difference between "this route works" and "this route cannot exist".
    ///
    /// The material itself NEVER lives here. A `JumpHop` is persisted to
    /// UserDefaults as JSON, so a key or password stored on it would be written
    /// to a backup-able plist in the clear. This enum says only WHERE to look:
    /// the Keychain, under `ServerProfile.hopSecretKey(profile:hop:)` — the same
    /// store, the same accessibility class, the same lifetime rules as the
    /// profile's own secret.
    enum Auth: String, Codable, CaseIterable {
        /// Use the profile's own credential (the shipped behaviour).
        case profile
        /// This hop has its own private key in the Keychain.
        case privateKey
        /// This hop has its own password in the Keychain.
        case password
    }

    /// Explicit so the tolerant decoder below and the encoder agree on names —
    /// and so `auth` can be omitted from the JSON when it is the default (see
    /// `encode(to:)`).
    private enum CodingKeys: String, CodingKey {
        case id, host, port, username, pinnedHostKey, auth
    }

    /// Stable across saves so the editor's rows keep their identity through a
    /// drag, a delete, and a relaunch. It is also the second half of this hop's
    /// Keychain key, which is why it must never be regenerated on load: a new id
    /// would orphan the hop's credential.
    var id: UUID = UUID()
    var host: String = ""
    var port: Int = 22
    /// Empty = the same username as the target.
    var username: String = ""
    /// Pinned host key line(s) for THIS machine. Empty = the connection is
    /// refused before anything is dialed.
    var pinnedHostKey: String = ""
    /// Whose credential opens THIS machine. Default = the profile's, i.e. every
    /// route that exists today.
    var auth: Auth = .profile

    /// "host:port" — how every error message names this machine, so a user
    /// reading "hop 2" can tell which box that is without counting rows.
    var endpoint: String {
        "\(host.trimmingCharacters(in: .whitespacesAndNewlines)):\(port)"
    }

    /// The auth KIND this hop authenticates with, given the profile's own.
    /// `.profile` resolves to whatever the target uses, which is exactly what
    /// `hopProfile` did before per-hop credentials existed.
    func authKind(under profileKind: ServerProfile.AuthKind) -> ServerProfile.AuthKind {
        switch auth {
        case .profile:    return profileKind
        case .privateKey: return .privateKey
        case .password:   return .password
        }
    }

    /// True when this hop carries a credential of its own — i.e. something is
    /// (or should be) stored in the Keychain under its key.
    var hasOwnCredential: Bool { auth != .profile }
}

extension JumpHop {
    /// Tolerant, for the same reason `ServerProfile`'s is: a field added later
    /// must not wipe a saved route. A hop written before per-hop credentials
    /// existed has no `auth` key at all and decodes to `.profile` — the
    /// behaviour it has always had.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(UUID.self, forKey: .id) { id = v }
        if let v = try? c.decode(String.self, forKey: .host) { host = v }
        if let v = try? c.decode(Int.self, forKey: .port) { port = v }
        if let v = try? c.decode(String.self, forKey: .username) { username = v }
        if let v = try? c.decode(String.self, forKey: .pinnedHostKey) { pinnedHostKey = v }
        if let v = try? c.decode(Auth.self, forKey: .auth) { auth = v }
    }

    /// Hand-written for ONE reason: the default `auth` is not written at all.
    ///
    /// A route of ordinary hops must encode to the same bytes it encoded to
    /// before this field existed — same keys, same order — so that adding
    /// per-hop credentials cannot change one byte of what is already on a user's
    /// phone, and a downgrade reads its own JSON back unchanged. Writing
    /// `"auth":"profile"` everywhere would have been harmless to this build and
    /// noise in every other.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(pinnedHostKey, forKey: .pinnedHostKey)
        if auth != .profile { try c.encode(auth, forKey: .auth) }
    }
}

/// A saved connection to one server. Non-secret fields live in UserDefaults;
/// the private key / password is stored separately in the Keychain, keyed by `id`.
struct ServerProfile: Identifiable, Codable, Equatable, Hashable {
    enum AuthKind: String, Codable, CaseIterable {
        case privateKey   // RSA / ed25519 key (recommended)
        case password
    }

    // Explicit keys so the tolerant decoder (in the extension below) and the
    // synthesized encoder agree on field names.
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, projectDir, authKind
        case pinnedHostKey, permissionMode, model, effort, runMode, launcherDir, backend
        case codexModel, codexEffort, codexSandbox, codexReviewer, codexServiceTier
        case cursorModel, provider
        case route
    }

    /// The single-jump fields the shipped build wrote, READ ONLY. They are not
    /// stored properties any more and are never written again — a saved profile
    /// is understood, not migrated, so nothing has to run at launch and an
    /// interrupted upgrade cannot leave half a route on disk.
    private enum LegacyJumpKeys: String, CodingKey {
        case jumpHost, jumpPort, jumpUsername, jumpPinnedHostKey
    }

    var id: UUID = UUID()
    var name: String = "My Server"
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    /// Working directory on the server that Claude Code operates in.
    var projectDir: String = "~"
    var authKind: AuthKind = .privateKey
    /// Pinned server host public key(s) (OpenSSH lines, e.g. "ssh-ed25519 AAAA...").
    /// The app refuses to connect unless the server presents one of these keys —
    /// this is what defeats a man-in-the-middle. Empty = connection REFUSED
    /// (SSHService throws); use the editor's "Fetch host key" to pin on first use.
    var pinnedHostKey: String = ""
    /// Permission mode (--permission-mode): auto | default | acceptEdits | plan | bypassPermissions.
    /// Defaults to "auto" to match Claude Code's own default.
    var permissionMode: String = "auto"
    /// Optional model override: alias ("opus"/"sonnet"/"fable") or full version
    /// ("claude-opus-4-8"); empty = account default. New profiles pin a specific
    /// version (the recommended pick) rather than the moving "opus" alias, so the
    /// default stays predictable across server CLI updates.
    var model: String = ModelOption.recommended
    /// Reasoning effort: low | medium | high | xhigh | max | ultracode;
    /// empty = session default. See EffortOption for the full list.
    var effort: String = ""
    /// Composer default: false = Chat, true = Run (detached). Saved per server so
    /// it doesn't reset to Chat every time you reopen a conversation.
    // Default TRUE since 2026-08-22 (user ruling): turns run as detached runs —
    // visible in the run list, reattachable, and they survive the phone leaving.
    var runMode: Bool = true
    /// Which coding-agent CLI to drive (Claude Code or OpenAI Codex). Selectable
    /// per conversation via the settings sheet; the server wrappers translate it.
    var backend: AgentBackend = .claude
    /// Codex has its own model namespace (gpt-5.x) and reasoning levels, kept
    /// separate from the Claude `model`/`effort` so switching backend never feeds
    /// a Claude id to Codex. Empty = the server's codex config default.
    var codexModel: String = ""
    var codexEffort: String = ""
    /// Codex's own permission axis is the `--sandbox` level (it has no Claude-style
    /// permission modes), so it's stored separately and never mapped from `permissionMode`.
    /// Full access by default, as in the Codex app (the person's call, 2026-10-18):
    /// no sandbox, nothing to approve. AppStore migrates profiles saved under the
    /// old workspace-write default once.
    var codexSandbox: String = "danger-full-access"
    /// Who settles a Codex approval under the workspace-write sandbox: "auto"
    /// (codex's own reviewer, the Codex app's "Approve for me") or "user" (the
    /// phone's Allow/Deny, "Ask for approval"). Meaningless under full access
    /// or read-only, where nothing is asked. Rides as `--reviewer user` only.
    var codexReviewer: String = "auto"
    /// Codex's speed tier for this conversation (2026-10-19): "" follows the
    /// Mac's codex config, a tier id ("priority" = codex's Fast) or "default"
    /// (standard) sets it. Rides as `--service-tier` only when set.
    var codexServiceTier: String = ""
    /// Cursor's own model namespace (auto, gpt-5.3-codex, claude-opus-5-thinking-high…).
    /// Empty = "auto", Cursor picks.
    var cursorModel: String = ""
    /// A third-party provider by name (the Mac's roster, pervio-provider) for
    /// Claude or Codex. Empty = the engine's own account. Cursor ignores it.
    var provider: String = ""

    // MARK: The route (经由) — the machines this connection passes THROUGH
    //
    // "The phone can reach A; A can reach B; B can reach the box behind it."
    // `host` always names the FINAL target; `route` names, IN ORDER, the
    // machines the connection is tunneled through to get there. Empty = dial the
    // target directly, which is what every profile that never had a jump host
    // decodes to and what the overwhelming majority of profiles will always be.
    //
    // ORDER IS THE MEANING. `route[0]` is dialed from the phone; each later hop
    // is reached through a direct-tcpip channel of the one before it; the target
    // is reached through the last. A route is a path, not a set of candidates —
    // there is deliberately no automatic route selection, no fallback, and no
    // reordering. One route per profile; if you reach the same machine two ways,
    // that is two profiles, and which one you tapped is which way you went.
    //
    // EVERY MACHINE IS PINNED, INDIVIDUALLY. Lengthening the route does not
    // loosen the boundary by one byte: each hop's key is validated on the
    // handshake that reaches it and the target's on the final tunneled one, all
    // validators are built BEFORE anything is dialed, and a hop that is unpinned
    // or answers with the wrong key refuses the whole connection.
    //
    // ONE CREDENTIAL BY DEFAULT, PER-HOP WHEN THE PATH DEMANDS IT. Unless a hop
    // says otherwise, this profile's Keychain secret authenticates every machine
    // on the way — the common bastion setup. A hop that sets `auth` carries its
    // own key or password instead, stored in the SAME Keychain under a
    // profile+hop key (`hopSecretKey`) and never in this JSON. That is what lets
    // a route cross a machine which only knows another key.

    /// Empty (the default, and what every previously saved profile with no jump
    /// host decodes to) = connect directly, exactly as before.
    var route: [JumpHop] = []

    /// The hops that will actually be dialed, in order, with their addresses
    /// trimmed. A row whose host is blank is a row the user has not filled in
    /// yet — the editor keeps it, the connection ignores it. (Silently dialing
    /// "" would be bad; silently SKIPPING a hop the user believes is pinned
    /// would be worse, so the editor's Save gate refuses a route with a blank
    /// row rather than leaving this to be discovered at connect time.)
    var routeHops: [JumpHop] {
        route.compactMap { hop in
            let h = hop.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !h.isEmpty else { return nil }
            var trimmed = hop
            trimmed.host = h
            return trimmed
        }
    }

    var usesRoute: Bool { !routeHops.isEmpty }

    /// "host:port" — how the target is named in every route-scoped message.
    var endpoint: String { "\(host):\(port)" }

    /// One hop as a profile of its own: the hop's address, identity and auth
    /// KIND, and no route of its own (a hop never chains further — the chaining
    /// is the caller's job, hop by hop). This is what the connect path validates
    /// each hop against, so every error names the machine that actually failed.
    ///
    /// The auth kind follows the hop (`.profile` = the target's, i.e. what this
    /// always did); the MATERIAL does not travel here, because a profile has
    /// nowhere to put a secret — see `hopSecretKey` and `SSHService.hopSecret`.
    func hopProfile(_ hop: JumpHop) -> ServerProfile {
        var p = self
        p.host = hop.host.trimmingCharacters(in: .whitespacesAndNewlines)
        p.port = hop.port
        p.username = hop.username.isEmpty ? username : hop.username
        p.pinnedHostKey = hop.pinnedHostKey
        p.authKind = hop.authKind(under: authKind)
        p.route = []
        return p
    }

    /// The Keychain account one hop's own credential is stored under.
    ///
    /// Composed of the two ids that already exist and are already stable — the
    /// profile's and the hop's — so it is unique across every server and every
    /// row of every route, and it survives a rename, a re-address and a drag
    /// that reorders the route (position is not part of the key; identity is).
    ///
    /// The separator matters: a UUID string never contains "/", so a hop key can
    /// never collide with the profile's own account (a bare 36-character UUID),
    /// and one profile's hop can never be read as another's. Same service, same
    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` class, same delete-on-
    /// delete lifetime as the profile secret — one storage convention, not two.
    static func hopSecretKey(profile: UUID, hop: UUID) -> String {
        "\(profile.uuidString)/hop/\(hop.uuidString)"
    }

    func hopSecretKey(_ hop: JumpHop) -> String {
        Self.hopSecretKey(profile: id, hop: hop.id)
    }

    /// The profile the editor probes when it fetches hop `index`'s key: that hop
    /// as the destination, reached through every hop BEFORE it.
    ///
    /// This is what keeps the trust ceremony honest on a long route. Probing
    /// accepts whatever key answers — that is its whole purpose — so the machine
    /// that CARRIES those bytes must already be pinned and validated. Otherwise
    /// a rogue earlier hop could hand the user its own key to trust, and the
    /// pinning ceremony would certify the man in the middle.
    /// `index` addresses the EDITOR's rows (`route`), not the filtered
    /// `routeHops`, so the row the user tapped is the machine that gets probed
    /// even while a blank row sits above it — and the blank row is dropped from
    /// the path rather than dialed.
    func hopProbeProfile(at index: Int) -> ServerProfile? {
        guard route.indices.contains(index) else { return nil }
        let hop = route[index]
        guard !hop.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var p = hopProfile(hop)
        p.route = route[..<index].filter {
            !$0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return p
    }

    var isComplete: Bool {
        !host.isEmpty && !username.isEmpty && port > 0
    }

    /// Path to the pervio launcher scripts on the server (see docs/deploy-guide.md).
    /// Kept overridable in case they are installed somewhere other than ~/bin.
    var launcherDir: String = "~/.pervio/bin"

    /// `launcherDir` is interpolated into the remote shell command UNQUOTED —
    /// quoting it would defeat the leading-`~` home expansion the shell does. So
    /// restrict it to a safe path charset; any value containing shell
    /// metacharacters or whitespace (e.g. smuggled in via a future profile
    /// import / iCloud sync) falls back to the default location and therefore
    /// cannot inject a command. Path traversal here is harmless (it just won't
    /// find the script), so `.`/`..` are allowed; shell metacharacters are not.
    var safeLauncherDir: String {
        let d = launcherDir.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = d.range(of: "^~?[A-Za-z0-9._/-]+$", options: .regularExpression) != nil
        return ok ? d : "~/.pervio/bin"
    }

    var chatLauncher: String { "\(safeLauncherDir)/pervio-chat" }
    var runLauncher: String { "\(safeLauncherDir)/pervio-run" }
    var termLauncher: String { "\(safeLauncherDir)/pervio-term" }
    var sessionsLauncher: String { "\(safeLauncherDir)/pervio-sessions" }
    var portsLauncher: String { "\(safeLauncherDir)/pervio-ports" }
    /// The working directory IS this server's scope on the phone: "~" shows
    /// everything, "~/a" only a and what is below it — conversations, search,
    /// background tasks, folder picking and file browsing alike (the person's
    /// rule, 2026-10-15: "填 ~ 看全部,填 ~/a 只看 a"). Two profiles for one Mac
    /// are two windows. Empty reads as "~".
    var scopeDir: String {
        let d = projectDir.trimmingCharacters(in: .whitespaces)
        return d.isEmpty ? "~" : d
    }

    /// Does this entry's scope contain `dir`, as far as the phone can tell
    /// without the Mac's home path? "~" contains everything; otherwise `dir` is
    /// the scope or below it, in either spelling ("~/a" vs "/Users/x/a" — the
    /// tilde scope is matched by its tail). Best-effort: used only to pick which
    /// entry a notification lands in when the originating one is gone.
    func scopeContains(_ dir: String) -> Bool {
        let scope = scopeDir.hasSuffix("/") && scopeDir.count > 1 ? String(scopeDir.dropLast()) : scopeDir
        let d = dir.hasSuffix("/") && dir.count > 1 ? String(dir.dropLast()) : dir
        if scope == "~" || scope == "/" { return true }
        if d == scope || d.hasPrefix(scope + "/") { return true }
        if scope.hasPrefix("~/"), d.hasPrefix("/") {
            let tail = String(scope.dropFirst(1))          // "/a"
            return d.hasSuffix(tail) || d.contains(tail + "/")
        }
        return false
    }
    var uploadLauncher: String { "\(safeLauncherDir)/pervio-upload" }
    var orchestrateLauncher: String { "\(safeLauncherDir)/pervio-orchestrate" }
    var viewLauncher: String { "\(safeLauncherDir)/pervio-view" }
    var pushLauncher: String { "\(safeLauncherDir)/pervio-push" }
    var groupLauncher: String { "\(safeLauncherDir)/pervio-group" }
    var providerLauncher: String { "\(safeLauncherDir)/pervio-provider" }

    /// The model the active engine runs, in that engine's own namespace.
    var activeModel: String {
        switch backend {
        case .claude: return model
        case .codex:  return codexModel
        case .cursor: return cursorModel
        }
    }
}

extension ServerProfile {
    /// Tolerant decoder: a field missing from older saved JSON keeps its default
    /// instead of failing the whole decode — otherwise introducing a new field
    /// would silently wipe the user's saved servers on next launch. Defined in an
    /// extension so the memberwise `ServerProfile()` initializer is preserved.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(UUID.self, forKey: .id) { id = v }
        if let v = try? c.decode(String.self, forKey: .name) { name = v }
        if let v = try? c.decode(String.self, forKey: .host) { host = v }
        if let v = try? c.decode(Int.self, forKey: .port) { port = v }
        if let v = try? c.decode(String.self, forKey: .username) { username = v }
        if let v = try? c.decode(String.self, forKey: .projectDir) { projectDir = v }
        if let v = try? c.decode(AuthKind.self, forKey: .authKind) { authKind = v }
        if let v = try? c.decode(String.self, forKey: .pinnedHostKey) { pinnedHostKey = v }
        if let v = try? c.decode(String.self, forKey: .permissionMode) { permissionMode = v }
        if let v = try? c.decode(String.self, forKey: .model) { model = v }
        if let v = try? c.decode(String.self, forKey: .effort) { effort = v }
        if let v = try? c.decode(Bool.self, forKey: .runMode) { runMode = v }
        if let v = try? c.decode(String.self, forKey: .launcherDir) { launcherDir = v }
        if let v = try? c.decode(AgentBackend.self, forKey: .backend) { backend = v }
        if let v = try? c.decode(String.self, forKey: .codexModel) { codexModel = v }
        if let v = try? c.decode(String.self, forKey: .codexEffort) { codexEffort = v }
        if let v = try? c.decode(String.self, forKey: .codexSandbox) { codexSandbox = v }
        if let v = try? c.decode(String.self, forKey: .codexReviewer) { codexReviewer = v }
        if let v = try? c.decode(String.self, forKey: .codexServiceTier) { codexServiceTier = v }
        if let v = try? c.decode(String.self, forKey: .cursorModel) { cursorModel = v }
        if let v = try? c.decode(String.self, forKey: .provider) { provider = v }

        // The route, or the single jump host it grew out of. A profile written
        // by this build carries `route` and that is the answer, EVEN WHEN IT IS
        // EMPTY — "I deleted my route" has to survive a relaunch, so a leftover
        // legacy key must not resurrect a hop. Only a profile written before
        // routes existed falls through to the old fields, and it does so without
        // being rewritten: nothing migrates at launch, so nothing can be left
        // half-migrated by a crash, and a downgrade loses the extra hops rather
        // than silently connecting through fewer of them (an unreachable target
        // is a visible failure; a quietly shortened route would not be).
        if let v = try? c.decode([JumpHop].self, forKey: .route) {
            route = v
        } else if let legacy = try? decoder.container(keyedBy: LegacyJumpKeys.self),
                  let host = try? legacy.decode(String.self, forKey: .jumpHost),
                  !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var hop = JumpHop()
            hop.host = host
            if let v = try? legacy.decode(Int.self, forKey: .jumpPort) { hop.port = v }
            if let v = try? legacy.decode(String.self, forKey: .jumpUsername) { hop.username = v }
            if let v = try? legacy.decode(String.self, forKey: .jumpPinnedHostKey) {
                hop.pinnedHostKey = v
            }
            route = [hop]
        }
    }
}
