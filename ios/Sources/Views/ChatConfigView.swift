import SwiftUI

/// Per-conversation parameters, mirroring the knobs Claude Code exposes. Edits a
/// binding to the live ChatStore profile, so changes apply to the next message.
struct ChatConfigView: View {
    @Binding var profile: ServerProfile
    /// True once the conversation has a session id (Claude session_id / Codex
    /// thread_id). Agents keep separate, incompatible session stores, so the
    /// backend can't be switched mid-conversation — the picker locks.
    var backendLocked: Bool = false
    /// A group member's knobs (GroupView): the agent is fixed by the member's
    /// conversation and the directory is the group's, so neither section shows.
    var memberMode: Bool = false
    @Environment(\.dismiss) private var dismiss
    /// What the Mac has (engines, the provider roster), from the connect-time probe.
    @ObservedObject private var engines = EngineStore.shared
    /// The stored SSH secret, so a provider can be added from HERE (written to
    /// the Mac over SSH) without a detour through the server form.
    @EnvironmentObject private var appStore: AppStore
    @State private var providerSheet: ProviderSheet?

    private var probe: EngineProbe? { engines.probe(for: profile) }
    /// Providers the active engine can use (Cursor: none).
    private var providerChoices: [ProviderInfo] {
        profile.backend.supportsProviders ? (probe?.providers(for: profile.backend) ?? []) : []
    }
    private var activeProvider: ProviderInfo? { probe?.provider(named: profile.provider) }

    /// Switch provider: the model follows it (the provider's default), so a
    /// name from the other vendor's namespace is never sent to this one.
    private func setProvider(_ name: String) {
        profile.provider = name
        if let p = probe?.provider(named: name) {
            if profile.backend == .codex { profile.codexModel = p.defaultModel } else { profile.model = p.defaultModel }
        } else if profile.backend == .codex {
            profile.codexModel = ""
        } else {
            profile.model = ModelOption.recommended
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !memberMode { Section("Agent") {
                    ForEach(AgentBackend.allCases) { b in
                        let missing = probe != nil && probe?.has(b) == false
                        let dimmed = (backendLocked && profile.backend != b) || (missing && profile.backend != b)
                        Button {
                            if !backendLocked && !missing {
                                profile.backend = b
                                if !b.supportsProviders { profile.provider = "" }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(b.iconAsset)
                                    .resizable().scaledToFit()
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.label).foregroundStyle(.primary)
                                    Text(missing ? L.engineNotInstalled() : b.tagline).font(.caption)
                                        .foregroundStyle(missing ? Color.orange : Color.secondary)
                                }
                                Spacer(minLength: 8)
                                if profile.backend == b {
                                    Image(systemName: backendLocked ? "lock.fill" : "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .opacity(dimmed ? 0.35 : 1)
                        }
                        .buttonStyle(.plain)
                        .disabled(dimmed)
                    }
                    if backendLocked {
                        Text("This conversation runs on \(profile.backend.label). Agents keep separate, incompatible histories, so you can't switch mid-conversation — start a New conversation to use a different agent.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } }

                // A third-party endpoint for this engine, from the Mac's roster
                // (server settings → Providers). Keys never leave the Mac; this
                // picker only names one. Changeable any time, like the model.
                if profile.backend.supportsProviders {
                    Section("Provider") {
                        Picker("Provider", selection: Binding(get: { profile.provider },
                                                              set: { setProvider($0) })) {
                            Text(L.providerAccountDefault()).tag("")
                            ForEach(providerChoices) { p in
                                Text(p.hasKey ? p.label : p.label + " · " + L.providerNoKey()).tag(p.name)
                            }
                        }
                        if let ap = activeProvider {
                            HStack(spacing: 6) {
                                VendorMark(preset: ap.preset, label: ap.label, size: 14)
                                Text(ap.baseUrl).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        if let ap = activeProvider, ap.source == "pervio" {
                            Button { providerSheet = .edit(ap) } label: { Label(L.providerEdit(), systemImage: "pencil") }
                                .disabled(appStore.secret(for: profile) == nil)
                        }
                        Button { providerSheet = .add } label: { Label(L.providerAdd(), systemImage: "plus.circle") }
                            .disabled(appStore.secret(for: profile) == nil)
                        if providerChoices.isEmpty {
                            Text(L.providerNoneHint()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Model") {
                    if profile.backend == .cursor {
                        TextField("cursor model — empty = auto", text: $profile.cursorModel)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Menu("Quick pick…") {
                            ForEach(ModelOption.cursorPresets) { m in
                                Button(m.label) { profile.cursorModel = m.value }
                            }
                        }
                        .font(.callout)
                        Text("Cursor's own menu (your account's models; `agent models` on the Mac). Empty = auto, Cursor picks. Effort is built into the model name.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let pr = engines.probe(for: profile), !pr.cursor.isEmpty, !pr.cursorKey, !pr.cursorLogin {
                            // Said before the first turn, not after a failed one (2026-10-19).
                            Label(L.cursorLoginHint(), systemImage: "person.badge.key.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else if let ap = activeProvider, !ap.models.isEmpty {
                        // The provider's models, not the engine's own menu.
                        TextField("model", text: profile.backend == .codex ? $profile.codexModel : $profile.model)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Menu("Quick pick…") {
                            ForEach(ap.models, id: \.self) { m in
                                Button(m) { if profile.backend == .codex { profile.codexModel = m } else { profile.model = m } }
                            }
                        }
                        .font(.callout)
                        Text("Models \(ap.label) offers (from its provider file on the Mac).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if profile.backend == .codex {
                        TextField("codex model — e.g. gpt-5.6-sol", text: $profile.codexModel)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Menu("Quick pick…") {
                            ForEach(CodexModelOption.presets) { m in
                                Button(m.label) { profile.codexModel = m.value }
                            }
                        }
                        .font(.callout)
                        Text("Codex model slugs (gpt-5.x). Empty = the server's codex config default. Codex runs under the server's `codex login`.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("model — alias or full version", text: $profile.model)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Menu("Quick pick…") {
                            ForEach(ModelOption.presets) { m in
                                Button(m.label) { profile.model = m.value }
                            }
                        }
                        .font(.callout)
                        Text("The quick-pick list is the model table of the claude on your Mac — every version it knows, newest first — so a new model appears once Claude Code there has updated. Pick a full version (e.g. claude-fable-5-2) to pin one exactly; an alias like \"opus\", \"sonnet\" or \"fable\" always means that family's newest. Fable draws from its own weekly quota. A /model typed in the chat changes this setting too.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if profile.backend.hasEffort { Section("Effort (reasoning depth)") {
                    if profile.backend == .codex {
                        let options = CodexEffortOption.options(for: profile.codexModel, menu: CodexModelOption.presets)
                        Picker("Effort", selection: $profile.codexEffort) {
                            ForEach(options) { e in
                                Text(e.label).tag(e.value)
                            }
                            // A level set earlier that this model's table does not list
                            // stays selectable (and visible), never silently swapped.
                            if !profile.codexEffort.isEmpty, !options.contains(where: { $0.value == profile.codexEffort }) {
                                Text(CodexEffortOption.label(for: profile.codexEffort) + " (not in this model's table)").tag(profile.codexEffort)
                            }
                        }
                        Text("The levels come from Codex's own model table on your Mac, per model; \"Default\" is that model's own default. Pick Low for quick replies.")
                            .font(.caption).foregroundStyle(.secondary)
                        CodexSpeedRow(profile: $profile)
                    } else {
                        Picker("Effort", selection: $profile.effort) {
                            ForEach(EffortOption.presets) { e in
                                Text(e.label).tag(e.value)
                            }
                        }
                        Text("Higher effort = more thinking. xhigh/max for hard problems, low for quick replies. \"Ultracode\" runs xhigh PLUS multi-agent workflow orchestration — most thorough, but spawns many agents (much higher token cost). Use it for big, hard tasks.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } }

                Section("Run mode (tool permissions)") {
                    if profile.backend == .cursor {
                        ForEach(CursorRunMode.all) { mode in
                            Button {
                                profile.permissionMode = mode.id
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: mode.icon)
                                        .foregroundStyle(mode.isDangerous ? Color.orange : Color.accentColor)
                                        .frame(width: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mode.title).foregroundStyle(.primary)
                                        Text(mode.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    if CursorRunMode.named(profile.permissionMode).id == mode.id {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        Text("Cursor can't show approval prompts on the phone, so it never asks — pick the level above (agent --mode plan / default / --force).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if profile.backend == .codex {
                        CodexModeRows(profile: $profile)
                    } else {
                        ForEach(RunMode.all) { mode in
                            Button {
                                profile.permissionMode = mode.id
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: mode.icon)
                                        .foregroundStyle(mode.isDangerous ? Color.orange : Color.accentColor)
                                        .frame(width: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mode.title).foregroundStyle(.primary)
                                        Text(mode.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    if profile.permissionMode == mode.id {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if memberMode {
                    Text(L.groupMemberSettingsHint()).font(.caption).foregroundStyle(.secondary)
                } else {
                    Section("Directory") {
                        Label(profile.projectDir, systemImage: "folder")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            // Presented from the page: a sheet on a Section inside a Form
            // dismisses itself on the next row refresh (2026-10-15).
            .sheet(item: $providerSheet) { target in
                ProviderAddSheet(profile: profile, secret: appStore.secret(for: profile) ?? "", editing: target.editing) { roster, name in
                    engines.setProviders(roster, for: profile)
                    guard let p = roster.first(where: { $0.name == name }), p.engine == profile.backend.rawValue else { return }
                    let current = profile.backend == .codex ? profile.codexModel : profile.model
                    // A new one becomes this conversation's provider right away; an
                    // edited one stays picked, its model re-read only if the list lost it.
                    if target.editing == nil || (profile.provider == name && !p.models.isEmpty && !p.models.contains(current)) {
                        setProvider(name)
                    }
                }
            }
            // A roster cached by an older build, or a server that was never
            // probed (only the home server is, at launch): ask the Mac again
            // so the provider picker and the vendor table are real.
            .task {
                if probe?.presets.isEmpty ?? true, let s = appStore.secret(for: profile) {
                    _ = await engines.refresh(profile: profile, secret: s)
                }
            }
            .pervioBar("Conversation settings", back: false)
            .toolbar {
                BarItem(.confirmationAction) { BarWord(text: L.done(), weight: .semibold) { dismiss() } }
            }
        }
    }
}


/// Codex's mode picker — the Codex app's four modes (ClaudeOptions.CodexSandboxOption),
/// each a (--sandbox, who-reviews) pair, with the one the profile is on ticked.
/// Its own view so the sheet and a snapshot test render the same rows.
struct CodexModeRows: View {
    @Binding var profile: ServerProfile

    var body: some View {
        ForEach(CodexSandboxOption.all) { s in
            Button {
                s.apply(to: &profile)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: s.icon)
                        .foregroundStyle(s.isDangerous ? Color.orange : Color.accentColor)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).foregroundStyle(.primary)
                        Text(s.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if s.matches(profile) {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        Text("Full access is the default, as in the Codex app. The two sandboxed modes keep Codex inside the project folder and differ in who settles anything beyond it: Codex's own reviewer, or you, here. In Run mode nobody can answer, so Ask never asks.")
            .font(.caption).foregroundStyle(.secondary)
    }
}


/// Codex's Fast switch (2026-10-19): shown when the conversation's model (or,
/// unset, the Mac's config model) has a faster service tier in codex's own
/// table. Off/on starts from the Mac's config.toml `service_tier`; a flip is
/// remembered per conversation and rides as --service-tier.
struct CodexSpeedRow: View {
    @Binding var profile: ServerProfile
    /// Snapshot seam (default on): the switch itself is UIKit-backed and the
    /// renderer draws it as a placeholder, so a recorded picture leaves it out;
    /// its on/off logic is pinned by CodexSpeedTests.
    var showsSwitch = true
    @ObservedObject private var menu = ModelMenuStore.shared

    var body: some View {
        if let tier = CodexSpeed.tier(model: profile.codexModel, menu: menu.codex, defaultModel: menu.codexDefaultModel) {
            let label = VStack(alignment: .leading, spacing: 2) {
                Text(tier.name).foregroundStyle(.primary)
                Text(tier.description.isEmpty ? "Codex's faster service tier" : tier.description)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showsSwitch {
                Toggle(isOn: Binding(
                    get: { CodexSpeed.isFast(profile, macTier: menu.codexServiceTier) },
                    set: { profile.codexServiceTier = $0 ? tier.id : "default" })) { label }
                .accessibilityIdentifier("codex-fast")
            } else {
                HStack { label; Spacer(); Text(CodexSpeed.isFast(profile, macTier: menu.codexServiceTier) ? "ON" : "OFF").font(.caption.weight(.semibold)).foregroundStyle(.tint) }
            }
            Text("Codex's own speed tier for this model, as its table describes it. Starts from your Mac's codex config (\(menu.codexServiceTier.isEmpty || menu.codexServiceTier == "default" ? "standard" : "Fast")); the switch sets it for this conversation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
