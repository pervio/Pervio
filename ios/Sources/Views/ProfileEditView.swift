import SwiftUI

struct ProfileEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State var profile: ServerProfile
    @State private var secret: String = ""
    @State private var hasSavedSecret = false
    @State private var probing = false
    @State private var probedKeys: [String] = []
    @State private var probeError: String?

    // Per-hop probe state, keyed by the hop's stable id rather than by its
    // position: a drag that reorders the rows must carry each hop's fetched
    // fingerprints WITH it, not leave them pointing at whichever machine slid
    // into that slot. Trusting a key attributed to the wrong hop is precisely
    // the mistake this screen exists to prevent.
    @State private var probingHop: UUID?
    @State private var probedHopKeys: [UUID: [String]] = [:]
    @State private var hopProbeError: [UUID: String] = [:]

    // Per-hop credentials the user is typing, keyed by hop id — held here and
    // written to the Keychain only on Save, exactly like the main secret. And
    // like the main secret, a STORED one is never read back into a field: we
    // only note that it exists (`hopsWithSavedSecret`), so a private key cannot
    // be shoulder-read off this screen or captured in the app-switcher snapshot.
    @State private var hopSecrets: [UUID: String] = [:]
    @State private var hopsWithSavedSecret: Set<UUID> = []
    /// The sign-in method each saved secret was saved FOR (the profile's own
    /// under `nil`). A saved secret counts only while its method is unchanged:
    /// a private key must never be offered as a password (see AppStore.upsert).
    @State private var savedHopAuth: [UUID: JumpHop.Auth] = [:]
    @State private var savedAuthKind: ServerProfile.AuthKind?
    @State private var loadedSaved = false
    /// The add-provider sheet, presented from the page (not a Section).
    @State private var providerSheet: ProviderSheet?


    /// Installed on that Mac, per the last connect's probe; nil = not probed yet.
    private func installed(_ b: AgentBackend) -> Bool? {
        EngineStore.shared.probe(for: profile).map { $0.has(b) }
    }

    /// The secret a Mac-side write (provider, token) can connect with: the
    /// one typed here, else the stored one.
    private var reachSecret: String? {
        secret.isEmpty ? (savedSecretUsable ? store.secret(for: profile) : nil) : secret
    }
    /// The stored main secret is for the method now selected.
    private var savedSecretUsable: Bool { hasSavedSecret && savedAuthKind == profile.authKind }
    /// The method was switched and nothing typed for the new one: not saved like that.
    private var mainSecretMissing: Bool { hasSavedSecret && !savedSecretUsable && secret.isEmpty }
    private func hopSavedUsable(_ hop: JumpHop) -> Bool {
        hopsWithSavedSecret.contains(hop.id) && savedHopAuth[hop.id] == hop.auth
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $profile.name)
                    TextField("Host (IP or domain)", text: $profile.host)
                        .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Port", value: $profile.port, format: .number)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $profile.username)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Project dir on server", text: $profile.projectDir)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    Text(L.dirScopeHint()).font(.caption).foregroundStyle(.secondary)
                }

                Section("Authentication") {
                    Picker("Method", selection: $profile.authKind) {
                        Text("Private key").tag(ServerProfile.AuthKind.privateKey)
                        Text("Password").tag(ServerProfile.AuthKind.password)
                    }
                    if profile.authKind == .privateKey {
                        Text(savedSecretUsable
                             ? "A private key is saved (Keychain). Leave blank to keep it; paste a new one only to replace."
                             : "Paste your private key (the contents of id_rsa / id_ed25519). Stored only in the iOS Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $secret)
                            .frame(minHeight: 120)
                            .font(.system(.footnote, design: .monospaced))
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .privacySensitive()
                    } else {
                        SecureField(savedSecretUsable ? "Password saved — type to replace" : "Password", text: $secret)
                    }
                }

                Section("Server identity (host-key pinning)") {
                    Text("The app connects only if the server presents this exact host key — this is what blocks a man-in-the-middle. Tap “Fetch” to read it from the server, check the fingerprint, then trust it. (Or paste an OpenSSH line yourself.) Without a pinned key the app refuses to connect.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $profile.pinnedHostKey)
                        .frame(minHeight: 60)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)

                    Button { Task { await fetchHostKey() } } label: {
                        Label(probing ? "Fetching…" : "Fetch host key from server",
                              systemImage: "key.viewfinder")
                    }
                    .disabled(probing || profile.host.isEmpty || profile.username.isEmpty)

                    if let probeError {
                        Text(probeError).font(.caption).foregroundStyle(.red)
                    }
                    if !probedKeys.isEmpty {
                        Text("Server presented these keys — verify the fingerprint, then trust:")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(probedKeys, id: \.self) { line in
                            Text(SSHService.hostKeyFingerprint(line).map { "\(keyAlgo(line))  \($0)" } ?? line)
                                .font(.caption2.monospaced()).foregroundStyle(.primary).lineLimit(1)
                        }
                        Button {
                            profile.pinnedHostKey = probedKeys.joined(separator: "\n")
                            probedKeys = []
                        } label: {
                            Label("Trust & pin these keys", systemImage: "checkmark.shield")
                        }
                        .tint(.green)
                    }
                }

                routeSection

                // The server's defaults: the engine a new conversation starts on,
                // its model / effort / run mode in THAT engine's own terms, and the
                // provider (the Mac's roster). A conversation can change any of
                // these for itself; this is only where new ones begin.
                Section("Engine defaults (new conversations)") {
                    Picker("Engine", selection: $profile.backend) {
                        ForEach(AgentBackend.allCases) { b in
                            Text(b.tag + (installed(b) == false ? " · not installed" : "")).tag(b)
                        }
                    }
                    if profile.backend == .codex {
                        Picker("Default mode", selection: Binding(
                            get: { CodexSandboxOption.mode(of: profile).id },
                            set: { id in CodexSandboxOption.all.first { $0.id == id }?.apply(to: &profile) })) {
                            ForEach(CodexSandboxOption.all) { s in Text(s.title).tag(s.id) }
                        }
                        TextField("Codex model (empty = config default)", text: $profile.codexModel)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Menu("Quick pick model…") {
                            ForEach(CodexModelOption.presets) { m in Button(m.label) { profile.codexModel = m.value } }
                        }
                        .font(.callout)
                        Picker("Default effort", selection: $profile.codexEffort) {
                            ForEach(CodexEffortOption.all) { e in Text(e.label).tag(e.value) }
                        }
                    } else if profile.backend == .cursor {
                        Picker("Default run mode", selection: Binding(
                            get: { CursorRunMode.named(profile.permissionMode).id },
                            set: { profile.permissionMode = $0 })) {
                            ForEach(CursorRunMode.all) { mode in Text(mode.title).tag(mode.id) }
                        }
                        TextField("Cursor model (empty = auto)", text: $profile.cursorModel)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Menu("Quick pick model…") {
                            ForEach(ModelOption.cursorPresets) { m in Button(m.label) { profile.cursorModel = m.value } }
                        }
                        .font(.callout)
                    } else {
                        Picker("Default run mode", selection: $profile.permissionMode) {
                            ForEach(RunMode.all) { mode in
                                Text(mode.title).tag(mode.id)
                            }
                        }
                        TextField("Model (optional, e.g. opus / sonnet)", text: $profile.model)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Menu("Quick pick model…") {
                            ForEach(ModelOption.presets) { m in
                                Button(m.label) { profile.model = m.value }
                            }
                        }
                        .font(.callout)
                        Picker("Default effort", selection: $profile.effort) {
                            ForEach(EffortOption.presets) { e in
                                Text(e.label).tag(e.value)
                            }
                        }
                    }
                    if profile.backend.supportsProviders {
                        Picker("Default provider", selection: $profile.provider) {
                            Text(L.providerAccountDefault()).tag("")
                            ForEach(EngineStore.shared.probe(for: profile)?.providers(for: profile.backend) ?? []) { p in
                                Text(p.label).tag(p.name)
                            }
                        }
                    }
                    TextField("Launcher dir", text: $profile.launcherDir)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }

                ProviderSection(profile: profile, secret: reachSecret, sheet: $providerSheet)
                MacCredentialSection(kind: .claudeToken, profile: profile, secret: reachSecret)
                MacCredentialSection(kind: .cursorKey, profile: profile, secret: reachSecret)

                if profile.permissionMode == "bypassPermissions" {
                    Section {
                        Label("bypassPermissions lets Claude run any command and edit any file without asking. Use only on a server you fully trust.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .sheet(item: $providerSheet) { target in
                ProviderAddSheet(profile: profile, secret: reachSecret ?? "", editing: target.editing) { roster, _ in
                    EngineStore.shared.setProviders(roster, for: profile)
                }
            }
            .navigationTitle(profile.name.isEmpty ? "New Server" : profile.name)
            // Reached by a swipe-Edit from the servers ledger, so its header has
            // to land in the same key as the page behind it: a small inline
            // title with Cancel/Save on the shoulders, not a large title that
            // shoves the first field down half a screen. LAYOUT ONLY — the two
            // buttons keep their standard placements (`.cancellationAction` /
            // `.confirmationAction`, i.e. leading and trailing) and their exact
            // behaviour, including the Save-disabled route validation below.
            .pervioBar(profile.name.isEmpty ? "New Server" : profile.name, back: false)
            .toolbar {
                BarItem(.cancellationAction) {
                    BarWord(text: L.cancel()) { dismiss() }
                }
                BarItem(.confirmationAction) {
                    BarWord(text: L.save(), weight: .semibold) {
                        store.upsert(profile, secret: secret.isEmpty ? nil : secret,
                                     hopSecrets: hopSecrets)
                        dismiss()
                    }
                    // A half-filled hop row is refused at SAVE rather than at
                    // connect: an addressless row is silently ignored by the
                    // connection, so saving one would leave the user looking at
                    // a route they believe is three machines long while two are
                    // being used. Cheaper to say so here. Same for a hop set to
                    // its own credential with nothing behind it — that route
                    // cannot authenticate, and finding out at connect time makes
                    // the user go looking at the server.
                    .disabled(!profile.isComplete || !routeIsWellFormed || !routeCredentialsFilled
                              || routeSharesThePassword || mainSecretMissing)
                }
            }
            .onAppear {
                // Do NOT preload the stored secret into a plaintext field — that would
                // expose the private key on screen and in the app-switcher snapshot.
                // We only note one exists; a blank field on Save keeps it (see upsert).
                hasSavedSecret = store.secret(for: profile) != nil
                hopsWithSavedSecret = Set(profile.route.filter {
                    store.hopSecret(for: profile, hop: $0) != nil
                }.map(\.id))
                if !loadedSaved {          // once: later appearances see the edits, not what is stored
                    loadedSaved = true
                    savedAuthKind = hasSavedSecret ? profile.authKind : nil
                    savedHopAuth = Dictionary(uniqueKeysWithValues: profile.route.map { ($0.id, $0.auth) })
                }
            }
        }
    }

    // MARK: - 经由 / Route — the machines this connection passes THROUGH
    //
    // The target is edited above; this is the path to it, top to bottom, in the
    // order the connection walks. Rows can be added, deleted and DRAGGED,
    // because on a route the order is the meaning: swapping two hops is a
    // different path, not a different arrangement of the same one.
    //
    // Every row carries its own fetch → verify → pin ceremony, and each is
    // aimed at that hop THROUGH the hops above it (`hopProbeProfile(at:)`), so
    // an unknown key is never carried to the user by an unverified machine.
    // That is why a row's Fetch stays disabled until every row above it is
    // pinned — and says so, rather than failing later with an error the user
    // has to decode.

    private var routeSection: some View {
        Section {
            Text(L.routeBlurb()).font(.caption).foregroundStyle(.secondary)

            if profile.route.isEmpty {
                Text(L.routeEmpty()).font(.caption).foregroundStyle(.secondary)
            }

            // Bound by SwiftUI's own element bindings and identified by the
            // hop's stable id, with the INDEX looked up per render rather than
            // captured: the index is what the row is CALLED ("第 2 跳") and what
            // the probe path needs, but a row that holds `$profile.route[i]`
            // reads a stale `i` during a delete animation and indexes past the
            // end of the array.
            ForEach($profile.route) { $hop in
                if let index = profile.route.firstIndex(where: { $0.id == hop.id }) {
                    hopRow(index: index, hop: hop, binding: $hop)
                }
            }
            .onMove { from, to in profile.route.move(fromOffsets: from, toOffset: to) }
            .onDelete { offsets in
                for i in offsets { hopStateForgotten(profile.route[i].id) }
                profile.route.remove(atOffsets: offsets)
            }

            Button {
                var hop = JumpHop()
                // Under a password login a hop never rides the server's
                // credential (the jump host would be handed the password).
                if profile.authKind == .password { hop.auth = .password }
                profile.route.append(hop)
            } label: {
                Label(L.routeAddHop(), systemImage: "plus.circle")
            }

            if !routeIsWellFormed {
                Text(L.routeBlankRow()).font(.caption).foregroundStyle(.orange)
            }
            if !routeCredentialsFilled {
                Text(L.routeHopNoCredential()).font(.caption).foregroundStyle(.orange)
            }
            if routeSharesThePassword {
                Text(L.routeHopSharedPassword()).font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("route-shared-password")
            }
        } header: {
            HStack {
                Text(L.routeSectionTitle())
                Spacer()
                // Reordering needs edit mode; without this the drag handles the
                // whole feature depends on never appear.
                if !profile.route.isEmpty { EditButton().font(.caption) }
            }
        }
    }

    @ViewBuilder
    private func hopRow(index: Int, hop: JumpHop, binding: Binding<JumpHop>) -> some View {
        let id = hop.id
        DisclosureGroup {
            TextField(L.routeHopHostField(), text: binding.host)
                .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField(L.routeHopPortField(), value: binding.port, format: .number)
                .keyboardType(.numberPad)
            TextField(L.routeHopUserField(), text: binding.username)
                .autocorrectionDisabled().textInputAutocapitalization(.never)

            // WHOSE credential opens this machine. One picker row, and in the
            // default state (the server's own credential — every route that
            // exists today) nothing else appears at all: a user who has never
            // met a machine that wants a different key sees one extra line of
            // chrome, not a second credentials form per hop.
            Picker(L.routeHopAuthField(), selection: binding.auth) {
                // "Same as the server" is offered for a key login only — or when
                // it is what an older route already says, so the row shows the
                // truth (and its warning) until the person picks another.
                if profile.authKind != .password || hop.auth == .profile {
                    Text(L.routeHopAuthProfile()).tag(JumpHop.Auth.profile)
                }
                Text(L.routeHopAuthKey()).tag(JumpHop.Auth.privateKey)
                Text(L.routeHopAuthPassword()).tag(JumpHop.Auth.password)
            }
            switch hop.auth {
            case .profile:
                EmptyView()
            case .privateKey:
                Text(hopSavedUsable(hop) ? L.routeHopKeySaved() : L.routeHopKeyHint())
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: hopSecretBinding(id))
                    .frame(minHeight: 120)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .privacySensitive()
            case .password:
                SecureField(hopSavedUsable(hop) ? L.routeHopPasswordSaved()
                                                             : L.routeHopPasswordField(),
                            text: hopSecretBinding(id))
                    .privacySensitive()
            }

            TextEditor(text: binding.pinnedHostKey)
                .frame(minHeight: 60)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled().textInputAutocapitalization(.never)

            Button { Task { await fetchHopKey(index: index) } } label: {
                Label(probingHop == id ? L.routeHopFetching() : L.routeHopFetchKey(),
                      systemImage: "key.viewfinder")
            }
            .disabled(probingHop != nil || hop.host.isEmpty || profile.username.isEmpty
                      || firstUnpinnedHopAbove(index) != nil)

            if let blocker = firstUnpinnedHopAbove(index) {
                Text(L.routeHopBlockedByEarlier(blocker + 1))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = hopProbeError[id] {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            if let keys = probedHopKeys[id], !keys.isEmpty {
                Text(L.routeHopVerify()).font(.caption).foregroundStyle(.secondary)
                ForEach(keys, id: \.self) { line in
                    Text(SSHService.hostKeyFingerprint(line).map { "\(keyAlgo(line))  \($0)" } ?? line)
                        .font(.caption2.monospaced()).foregroundStyle(.primary).lineLimit(1)
                }
                Button {
                    binding.wrappedValue.pinnedHostKey = keys.joined(separator: "\n")
                    probedHopKeys[id] = nil
                } label: {
                    Label(L.routeHopTrust(), systemImage: "checkmark.shield")
                }
                .tint(.green)
            }
        } label: {
            RouteHopSummary(index: index, hop: hop)
        }
    }

    /// Index of the first hop ABOVE `index` that carries no pin, if any. Fetching
    /// hop `index`'s key would have to travel through it, and a key handed over
    /// by a machine we cannot identify proves nothing about the machine it
    /// claims to come from.
    private func firstUnpinnedHopAbove(_ index: Int) -> Int? {
        profile.route[..<index].firstIndex {
            !$0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && $0.pinnedHostKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Every row has an address. A blank row is not a hop (the connection skips
    /// it), so saving one would show a route longer than the one that runs.
    private var routeIsWellFormed: Bool {
        profile.route.allSatisfy {
            !$0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Every hop that claims its own credential has one — typed now, or already
    /// in the Keychain from a previous save. A hop that claims one and has none
    /// authenticates with an empty secret, which fails on that hop; the route is
    /// unusable and the editor says so before it is written down.
    /// A hop still on "same as the server" under a password login — a route
    /// saved before 2026-11-21, or the login method switched to password with
    /// the route already there. Not saved like that, and not dialed either.
    private var routeSharesThePassword: Bool {
        profile.route.contains { SSHService.hopWouldReceiveTargetPassword($0, of: profile) }
    }

    private var routeCredentialsFilled: Bool {
        profile.route.allSatisfy { hop in
            !hop.hasOwnCredential
            || !(hopSecrets[hop.id] ?? "").isEmpty
            || hopSavedUsable(hop)
        }
    }

    /// The typed-but-unsaved credential for one hop. Kept out of `JumpHop` on
    /// purpose: the hop is persisted as JSON, and a secret on it would be
    /// written to UserDefaults in the clear.
    private func hopSecretBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { hopSecrets[id] ?? "" }, set: { hopSecrets[id] = $0 })
    }

    private func hopStateForgotten(_ id: UUID) {
        probedHopKeys[id] = nil
        hopProbeError[id] = nil
        // A deleted row's typed credential dies with the row; the STORED one is
        // dropped by `upsert` on save (and only then — a cancelled edit must
        // leave the Keychain exactly as it found it).
        hopSecrets[id] = nil
    }

    /// Fetch ONE hop's host key for pinning — the same look-before-trusting
    /// ceremony as `fetchHostKey`, aimed at that hop and reached THROUGH the hops
    /// above it, each of which is pinned and validated on the way. The hop being
    /// identified is not logged in to; only the hops above it are.
    private func fetchHopKey(index: Int) async {
        guard let probe = profile.hopProbeProfile(at: index) else { return }
        let id = profile.route[index].id
        hopProbeError[id] = nil
        probedHopKeys[id] = nil
        let sec = reachSecret ?? ""
        guard !sec.isEmpty || !probe.usesRoute else {
            hopProbeError[id] = "Enter the private key / password first."; return
        }
        probingHop = id
        defer { probingHop = nil }
        do {
            // The hops this probe travels THROUGH may each have their own
            // credential, and the one just typed is not in the Keychain yet —
            // without handing them over, pinning a hop behind a machine with its
            // own key would be impossible until after a save.
            let keys = try await SSHService().probeHostKeys(profile: probe, secret: sec,
                                                            hopSecrets: hopSecrets)
            if keys.isEmpty {
                hopProbeError[id] = L.routeHopNoKeys()
            } else {
                probedHopKeys[id] = keys
            }
        } catch {
            hopProbeError[id] = (error as? LocalizedError)?.errorDescription
                ?? L.routeHopUnreachable()
        }
    }

    /// Begin a handshake with the server just far enough to be shown its host
    /// key, so the user can verify the fingerprint and pin it. Nothing is logged
    /// in to: the machine at the far end gets no user name, password or key, so
    /// no credential is needed to fetch — except on a route, whose hops (already
    /// pinned, and validated on the way) have to be opened to get there.
    private func fetchHostKey() async {
        probeError = nil; probedKeys = []
        let sec = reachSecret ?? ""
        guard !sec.isEmpty || !profile.usesRoute else {
            probeError = "Enter the private key / password first."; return
        }
        probing = true
        defer { probing = false }
        do {
            let keys = try await SSHService().probeHostKeys(profile: profile, secret: sec)
            if keys.isEmpty {
                probeError = "The server presented no host key this app can pin — paste one manually."
            } else {
                probedKeys = keys
            }
        } catch {
            probeError = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach the server."
        }
    }

    private func keyAlgo(_ line: String) -> String {
        String(line.split(separator: " ").first ?? "key")
    }
}

/// The COLLAPSED route-hop row: its title ("第 N 跳" / "Hop N"), the endpoint,
/// the pin badge (已钉/未钉 · green/orange), and — when the hop carries its own
/// credential — the 独立凭据 badge riding the same line. Factored out of
/// `ProfileEditView.hopRow`'s DisclosureGroup label so a snapshot test can
/// render the hop list on its own: `ImageRenderer` cannot rasterize the whole
/// `Form`/`NavigationStack` editor (it renders the "unavailable" placeholder),
/// but this plain row it can. `ProfileEditView` uses exactly this as its label,
/// so what the snapshot pins is what the editor draws.
struct RouteHopSummary: View {
    let index: Int
    let hop: JumpHop

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L.routeHopTitle(index + 1)).font(.callout)
            HStack(spacing: 6) {
                Text(hop.host.isEmpty ? "—" : hop.endpoint)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if hop.pinnedHostKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(L.routeHopUnpinned(), systemImage: "exclamationmark.shield")
                        .font(.caption2).foregroundStyle(.orange).labelStyle(.titleAndIcon)
                } else {
                    Label(L.routeHopPinned(), systemImage: "checkmark.shield")
                        .font(.caption2).foregroundStyle(.green).labelStyle(.titleAndIcon)
                }
                // Rides the line that is already there, so a hop with its
                // own key is visible while COLLAPSED without costing a row.
                if hop.hasOwnCredential {
                    Label(L.routeHopOwnCredential(), systemImage: "key.horizontal")
                        .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
            }
        }
    }
}
