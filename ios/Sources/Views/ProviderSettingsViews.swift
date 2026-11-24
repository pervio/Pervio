import SwiftUI

/// Server settings: the Mac's roster of third-party providers (pervio-provider)
/// and the Claude setup-token. Both are written to the MAC over one SSH call —
/// a key or token typed here travels once and never lives on the phone.
///
/// Why on the Mac: workflows, Duet rounds and detached runs start their own
/// processes there with no phone in sight, so the key has to be where the
/// engine runs. ~/.pervio/providers/<name>.env, 0600, like credentials.env.
/// What the page presents for the Providers section: the blank form, or one
/// provider's form filled in (an edit = re-add under the same name on the Mac;
/// an empty key keeps the stored one).
enum ProviderSheet: Identifiable {
    case add
    case edit(ProviderInfo)
    var id: String { if case .edit(let p) = self { return "edit:" + p.name }; return "add" }
    var editing: ProviderInfo? { if case .edit(let p) = self { return p }; return nil }
}

struct ProviderSection: View {
    let profile: ServerProfile
    let secret: String?
    /// Owned by the page: a `.sheet` hung on a Section inside a Form is torn
    /// down with the row refresh and dismisses itself at once (2026-10-15).
    @Binding var sheet: ProviderSheet?
    @ObservedObject private var engines = EngineStore.shared
    @State private var busy = false
    @State private var note: String?

    private var providers: [ProviderInfo] { engines.probe(for: profile)?.providers ?? [] }
    private var canReach: Bool { profile.isComplete && (secret?.isEmpty == false) }

    var body: some View {
        Section {
            if providers.isEmpty {
                Text("None yet. A provider is a third-party endpoint for Claude Code or Codex (GLM, Kimi, MiniMax, DeepSeek…): a base URL, its API key and its model names. Accounts (Claude / Codex / Cursor logins) stay where their CLIs keep them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(providers) { p in
                // Pervio's own files open for editing; ones discovered in
                // settings.json / config.toml are the CLI's, read-only here.
                Button { if p.source == "pervio" && canReach { sheet = .edit(p) } } label: {
                    HStack(spacing: 10) {
                        HStack(spacing: -4) {
                            Image(p.agent.iconAsset).resizable().scaledToFit().frame(width: 18, height: 18)
                            VendorMark(preset: p.preset, label: p.label, size: 16)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(p.label).font(.callout).foregroundStyle(.primary)
                                if !p.hasKey { Text("· no key").font(.caption).foregroundStyle(.orange) }
                                if p.source != "pervio" {
                                    Text(p.source == "claude-settings" ? "settings.json" : "config.toml")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Text(p.baseUrl + (p.defaultModel.isEmpty ? "" : " · " + p.defaultModel))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if p.source == "pervio", let ms = p.modelsSource, ms != "manual" {
                                Text(ms == "live" ? L.providerModelsLive() : L.providerModelsPreset())
                                    .font(.caption2).foregroundStyle(ms == "live" ? Color.green : Color.orange)
                            }
                        }
                        Spacer()
                        if p.source == "pervio" {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    if p.source == "pervio" {
                        Button(role: .destructive) { Task { await remove(p) } } label: { Label("Delete", systemImage: "trash") }
                        Button { Task { await refresh(p) } } label: { Label(L.providerRefreshModels(), systemImage: "arrow.clockwise") }
                            .tint(.blue)
                        Button { sheet = .edit(p) } label: { Label(L.providerEditTitle(), systemImage: "pencil") }
                            .tint(.orange)
                    }
                }
            }
            Button { sheet = .add } label: { Label(L.providerAdd(), systemImage: "plus.circle") }
                .disabled(!canReach || busy)
            if providers.contains(where: { $0.source == "pervio" }) {
                Text(L.providerRowHint()).font(.caption).foregroundStyle(.secondary)
            }
            if !canReach {
                Text("Save the connection first — the provider is written to the Mac over SSH.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.orange) }
        } header: {
            Text("Providers (keys live on the Mac)")
        }
    }

    private func refresh(_ p: ProviderInfo) async {
        guard let secret else { return }
        busy = true; defer { busy = false }
        let ssh = SSHService()
        do {
            try await ssh.connect(profile: profile, secret: secret)
            let roster = try await ssh.providerRefresh(profile: profile, name: p.name)
            await ssh.disconnect()
            engines.setProviders(roster, for: profile)
            note = nil
        } catch {
            await ssh.disconnect()
            note = pervioErrorText(error, "The vendor did not answer.")
        }
    }

    private func remove(_ p: ProviderInfo) async {
        guard let secret else { return }
        busy = true; defer { busy = false }
        let ssh = SSHService()
        do {
            try await ssh.connect(profile: profile, secret: secret)
            let roster = try await ssh.providerRemove(profile: profile, name: p.name)
            await ssh.disconnect()
            engines.setProviders(roster, for: profile)
            note = nil
        } catch {
            await ssh.disconnect()
            note = pervioErrorText(error, "Could not remove it.")
        }
    }
}

/// One provider, typed once. The key goes straight to the Mac; the field is
/// cleared on dismiss and never persisted on the phone. With `editing` set the
/// same form opens filled in: the name is fixed (it is the file's name on the
/// Mac), the key may stay empty (the stored one is kept), the rest is written
/// back by the same `add` verb. `onSaved` gets the roster and the saved name.
struct ProviderAddSheet: View {
    let profile: ServerProfile
    let secret: String
    let editing: ProviderInfo?
    let onSaved: ([ProviderInfo], String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var engines = EngineStore.shared
    @State private var refreshing = false
    @State private var engine: AgentBackend = .claude
    /// The vendor preset ("" = custom) and, when the vendor splits regions,
    /// the region — never assumed, the person picks (2026-10-15).
    @State private var presetId = ""
    @State private var regionId = ""
    @State private var name = ""
    @State private var label = ""
    @State private var baseUrl = ""
    @State private var apiKey = ""
    @State private var models = ""
    @State private var defaultModel = ""
    @State private var wireApi = "chat"
    @State private var busy = false
    @State private var errorText: String?

    init(profile: ServerProfile, secret: String, editing: ProviderInfo? = nil, onSaved: @escaping ([ProviderInfo], String) -> Void) {
        self.profile = profile
        self.secret = secret
        self.editing = editing
        self.onSaved = onSaved
        if let e = editing {
            _engine = State(initialValue: e.agent)
            _presetId = State(initialValue: e.preset ?? "")
            _regionId = State(initialValue: e.region ?? "")
            _name = State(initialValue: e.name)
            _label = State(initialValue: e.label)
            _baseUrl = State(initialValue: e.baseUrl)
            _models = State(initialValue: e.models.joined(separator: ", "))
            _defaultModel = State(initialValue: e.defaultModel)
            _wireApi = State(initialValue: (e.wireApi?.isEmpty == false) ? e.wireApi! : "chat")
        }
    }

    private var presets: [ProviderPreset] { engines.probe(for: profile)?.presets ?? [] }

    /// The vendor table comes from the Mac (`pervio-chat engines`); an empty one
    /// means a stale cache or a Mac whose scripts are out of date — ask again.
    private func refreshRoster() async {
        guard !secret.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        _ = await engines.refresh(profile: profile, secret: secret)
    }
    private var preset: ProviderPreset? { presets.first { $0.id == presetId } }
    private var regionMissing: Bool { preset?.needsRegion == true && regionId.isEmpty }
    /// A new provider needs a key; an edit may leave it empty to keep the stored one.
    private var keyOK: Bool { !apiKey.isEmpty || editing?.hasKey == true }

    private var ready: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && baseUrl.hasPrefix("http") && keyOK && !regionMissing
    }

    /// The engine and the URL disagree in shape (Claude with an OpenAI-style
    /// path, Codex with an Anthropic-style one). A hint only — the person
    /// asked that nothing they typed be rewritten (2026-10-15).
    private var urlHint: String? {
        guard let shape = ProviderUrlShape.guess(baseUrl) else { return nil }
        let text: String
        if engine == .claude, shape == .openai { text = L.providerUrlLooksOpenAI() }
        else if engine == .codex, shape == .anthropic { text = L.providerUrlLooksAnthropic() }
        else { return nil }
        if let p = preset, let u = p.url(for: engine, region: regionId), !u.isEmpty,
           u.lowercased() != baseUrl.trimmingCharacters(in: .whitespaces).lowercased() {
            return text + " " + L.providerUrlVendorHas(u)
        }
        return text
    }

    /// Fill what the vendor table knows; the person keeps anything typed over it.
    private func applyPreset() {
        guard let p = preset else { return }
        if name.isEmpty || presets.contains(where: { $0.id == name }) { name = p.id }
        label = p.label
        models = p.models.joined(separator: ", ")
        defaultModel = p.defaultModel
        wireApi = p.wireApi ?? "chat"
        if p.regions.count == 1 { regionId = p.regions[0].id } else if !p.regions.contains(where: { $0.id == regionId }) { regionId = "" }
        baseUrl = p.url(for: engine, region: regionId) ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L.providerVendor(), selection: $presetId) {
                        Text(L.providerCustom()).tag("")
                        ForEach(presets) { p in Text(p.label).tag(p.id) }
                    }
                    if let p = preset, p.needsRegion {
                        Picker(L.providerRegion(), selection: $regionId) {
                            Text(L.providerRegionPick()).tag("")
                            ForEach(p.regions) { r in Text(r.label).tag(r.id) }
                        }
                        Text(L.providerRegionHint()).font(.caption).foregroundStyle(.secondary)
                    }
                    if let p = preset, let note = p.note, !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    if let p = preset, let docs = p.docs, !docs.isEmpty {
                        Text(docs).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    if presets.isEmpty {
                        Text(L.providerPresetsMissing(engines.probe(for: profile)?.probeError))
                            .font(.caption).foregroundStyle(.orange)
                        Button { Task { await refreshRoster() } } label: {
                            Label(refreshing ? "…" : L.refreshNow(), systemImage: "arrow.clockwise")
                        }
                        .disabled(refreshing || secret.isEmpty)
                    }
                } footer: {
                    Text(L.providerPresetHint())
                }
                .task { if presets.isEmpty { await refreshRoster() } }
                .onChange(of: presetId) { _, _ in applyPreset() }
                .onChange(of: regionId) { _, _ in if let p = preset { baseUrl = p.url(for: engine, region: regionId) ?? "" } }
                .onChange(of: engine) { _, _ in if let p = preset { baseUrl = p.url(for: engine, region: regionId) ?? ""; wireApi = p.wireApi ?? "chat" } }
                Section("Engine") {
                    Picker("Engine", selection: $engine) {
                        ForEach(AgentBackend.allCases.filter(\.supportsProviders)) { b in Text(b.label).tag(b) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    TextField("name (short, e.g. glm)", text: $name)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .disabled(editing != nil).foregroundStyle(editing != nil ? .secondary : .primary)
                    TextField("label shown in menus (e.g. 智谱 GLM)", text: $label)
                    TextField(engine == .claude ? "base URL (…/api/anthropic)" : "base URL (…/v1)", text: $baseUrl)
                        .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                    if let urlHint {
                        Label(urlHint, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    SecureField(editing?.hasKey == true ? L.providerKeyKeep() : "API key", text: $apiKey)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                } header: {
                    Text("Provider")
                } footer: {
                    if editing != nil { Text(L.providerNameFixed()) }
                }
                Section("Models") {
                    TextField("model names, comma-separated", text: $models)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("default model (empty = the first)", text: $defaultModel)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    if engine == .codex {
                        Picker("Wire API", selection: $wireApi) {
                            Text("chat").tag("chat"); Text("responses").tag("responses")
                        }
                    }
                    Text(engine == .claude
                         ? "Claude Code will run with ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN set to these — the way GLM, Kimi and MiniMax document it."
                         : "Codex will run with a model_providers override pointing here; most OpenAI-compatible endpoints use the chat wire API.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let errorText { Text(errorText).font(.caption).foregroundStyle(.orange) }
            }
            .pervioBar(editing == nil ? "Add provider" : L.providerEditTitle(), back: false)
            .toolbar {
                BarItem(.cancellationAction) { BarWord(text: L.cancel()) { dismiss() } }
                BarItem(.confirmationAction) {
                    BarWord(text: busy ? L.credentialSaving() : L.credentialSave(), weight: .semibold) { Task { await save() } }
                        .disabled(!ready || busy)
                }
            }
        }
    }

    private func save() async {
        busy = true; defer { busy = false }
        let savedName = name.trimmingCharacters(in: .whitespaces).lowercased()
        var payload: [String: Any] = [
            "name": savedName,
            "engine": engine.rawValue,
            "label": label.trimmingCharacters(in: .whitespaces),
            "baseUrl": baseUrl.trimmingCharacters(in: .whitespaces),
            "models": models.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            "defaultModel": defaultModel.trimmingCharacters(in: .whitespaces),
            "wireApi": wireApi,
        ]
        // An empty key on an edit means "keep the one on the Mac" — the verb
        // only replaces the stored key when a new one is sent.
        if !apiKey.isEmpty { payload["apiKey"] = apiKey }
        if let p = preset {
            payload["preset"] = p.id
            payload["region"] = regionId
            if let r = p.region(regionId), !r.modelsUrl.isEmpty {
                payload["modelsUrl"] = r.modelsUrl
                payload["fetchModels"] = true     // the vendor's live list beats the table
            }
        }
        let ssh = SSHService()
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try await ssh.connect(profile: profile, secret: secret)
            let roster = try await ssh.providerAdd(profile: profile, payload: data)
            await ssh.disconnect()
            apiKey = ""
            onSaved(roster, savedName)
            dismiss()
        } catch {
            await ssh.disconnect()
            errorText = pervioErrorText(error, "Could not save it to the Mac.")
        }
    }
}

/// A login the Mac must hold for the non-interactive SSH process Pervio starts
/// (its keychain is out of reach): `claude setup-token` for Claude, an API key
/// for Cursor's agent. Both go to the Mac's ~/.pervio/credentials.env, which
/// pervio-chat sources. Typed once, sent once, never kept on the phone.
enum MacCredential {
    case claudeToken, cursorKey

    var header: String { self == .claudeToken ? L.claudeTokenHeader() : L.cursorSectionHeader() }
    var placeholder: String { self == .claudeToken ? L.claudeTokenPlaceholder() : L.cursorKeyPlaceholder() }
    var note: String { self == .claudeToken ? L.claudeTokenNote() : L.cursorKeyNote() }
    var identifier: String { self == .claudeToken ? "claude-token" : "cursor-key" }
}

struct MacCredentialSection: View {
    let kind: MacCredential
    let profile: ServerProfile
    let secret: String?
    // The shared store, as the sections above use it — it is NOT an environment
    // object (declaring it as one crashed the New Server editor, e2e 2026-10-16).
    @ObservedObject private var engines = EngineStore.shared
    @Environment(\.openURL) private var openURL
    @State private var value = ""
    @State private var busy = false
    @State private var note: String?
    @State private var noteOK = false
    @State private var loginBusy = false
    @State private var loginNote: String?

    private var canReach: Bool { profile.isComplete && (secret?.isEmpty == false) }
    /// The Mac's own word on whether a Cursor key is on file (from the engines probe).
    private var onFile: Bool? {
        kind == .cursorKey ? engines.probe(for: profile)?.cursorKey : nil
    }
    /// …and whether the agent is logged in to its file store there — then the
    /// key is not needed at all.
    private var fileLogin: Bool {
        kind == .cursorKey && (engines.probe(for: profile)?.cursorLogin ?? false)
    }

    var body: some View {
        Section {
            if kind == .cursorKey {
                // The one action: sign in once through the link; the key is the
                // alternative, folded away (the person's ruling, 2026-10-16).
                Text(fileLogin ? L.cursorFileLoginOnMac() : L.cursorLoginStatus(nil))
                    .font(.caption).foregroundStyle(fileLogin ? Color.green : Color.secondary)
                Button(loginBusy ? L.cursorLoginWaiting() : L.cursorLoginButton()) { Task { await login() } }
                    .disabled(!canReach || loginBusy)
                    .accessibilityIdentifier("cursor-login")
                if let loginNote { Text(loginNote).font(.caption).foregroundStyle(.orange) }
                DisclosureGroup(L.cursorKeyAlternative()) { credentialFields }
            } else {
                credentialFields
            }
        } header: {
            Text(kind.header)
        }
    }

    @ViewBuilder private var credentialFields: some View {
        SecureField(kind.placeholder, text: $value)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            .accessibilityIdentifier("\(kind.identifier)-field")
        HStack {
            Button(busy ? L.credentialSaving() : L.credentialSave()) { Task { await send(value) } }
                .disabled(!canReach || busy || value.isEmpty)
            Spacer()
            Button(L.credentialClear(), role: .destructive) { Task { await send("") } }
                .disabled(!canReach || busy)
        }
        Text(kind.note).font(.caption).foregroundStyle(.secondary)
        if kind == .cursorKey, let onFile {
            Text(L.cursorKeyOnFile(onFile)).font(.caption).foregroundStyle(onFile ? Color.green : Color.secondary)
        }
        if let note { Text(note).font(.caption).foregroundStyle(noteOK ? Color.green : Color.orange) }
    }

    /// Settings' copy of the chat's one tap: its own SSH session, the link to
    /// the browser, then the probe refreshed so the status line says so.
    private func login() async {
        guard let secret else { return }
        loginBusy = true; defer { loginBusy = false }
        loginNote = nil
        let ssh = SSHService()
        do {
            try await ssh.connect(profile: profile, secret: secret)
        } catch {
            loginNote = pervioErrorText(error, L.credentialWriteFailed()); return
        }
        let launcher = profile.providerLauncher
        let st = await CursorLoginFlow.run(
            run: { action in try await ssh.runCommand(CursorLoginFlow.command(launcher, action)) },
            open: { url in openURL(url) })
        await ssh.disconnect()
        if st.phase == .done {
            loginNote = nil
            _ = await engines.refresh(profile: profile, secret: secret)
        } else {
            loginNote = L.cursorLoginFailed(st.error)
        }
    }

    private func send(_ newValue: String) async {
        guard let secret else { return }
        busy = true; defer { busy = false }
        let ssh = SSHService()
        do {
            try await ssh.connect(profile: profile, secret: secret)
            let has: Bool
            switch kind {
            case .claudeToken: has = try await ssh.claudeToken(profile: profile, token: newValue)
            case .cursorKey:   has = try await ssh.cursorKey(profile: profile, key: newValue)
            }
            await ssh.disconnect()
            value = ""
            noteOK = true
            note = has ? L.credentialSaved() : L.credentialCleared()
            // The probe's cursorKey (and the Cursor model menu, now that `agent
            // models` can answer) follow on the next refresh.
            _ = await engines.refresh(profile: profile, secret: secret)
        } catch {
            await ssh.disconnect()
            noteOK = false
            note = pervioErrorText(error, L.credentialWriteFailed())
        }
    }
}
