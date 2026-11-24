import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ChatView: View {
    @EnvironmentObject private var appStore: AppStore
    @Environment(\.openURL) private var openURL
    @StateObject private var store: ChatStore
    @StateObject private var history: SessionService
    /// The conversation's working directory. Free to change until the first
    /// message goes out (the CLI session is born in it, its record is filed by
    /// it); after that, switching = a new conversation (the ⌘-new menu).
    @State private var dir: String
    @State private var showDirPicker = false
    /// The new conversation a directory switch opens, carrying this one along.
    @State private var carryTarget: CarryOver?
    /// Set at birth by a directory switch: attach the previous conversation
    /// as 背景 once this one is up.
    private let carryOver: CarryOver?

    struct CarryOver: Identifiable, Hashable {
        let id = UUID()
        let dir: String
        let fromDir: String
        let session: SessionSummary?
    }
    private let pillEnabled: Bool
    private let embedded: Bool
    /// Bumped by the enclosing GroupView after each `say`: the pane re-syncs
    /// (reattaches the run the Mac started, pulls the new history).
    @Environment(\.groupRefresh) private var groupRefresh
    private let secret: String

    /// The composer's text lives in `ComposerInputBar`, not here: a keystroke
    /// then re-evaluates that bar alone, never this page with its transcript
    /// (2026-11-18). What this page puts INTO the composer — a bubble's words
    /// to restate, a message handed back — travels as a one-shot request.
    private let initialInput: String
    @State private var composerPrefill: ComposerPrefill?
    @State private var showConfig = false
    @Environment(\.dismiss) private var dismissChat
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmTakeover = false
    @State private var showHistory = false
    @State private var sessions: [SessionSummary] = []
    @State private var loadingSessions = false
    @State private var historySearch = ""
    /// A drawer row whose delete is being confirmed; and the pencil menu's
    /// "delete this conversation" asking (2026-10-21).
    @State private var pendingDelete: SessionSummary?
    @State private var confirmDeleteCurrent = false
    /// Where a tapped link goes — a Mac file to the preview sheet, a localhost
    /// page to the web preview (2026-11-06). One router for the page's life:
    /// its actions sit in the environment and must compare as unchanged from
    /// one body to the next, or every text view in the transcript re-renders
    /// on every keystroke (2026-11-18; see LinkRouter.swift).
    @StateObject private var links = LinkRouter()
    @State private var detailTool: ToolCall?
    @State private var monitorWorkflow: WorkflowChipTarget?
    @State private var showTerminal = false
    // 双叉键的候选条(2026-09-01,用户三顾:像 CC 打 / 那样列出 wf 再注入)。
    @State private var showWfSuggest = false
    @State private var wfTemplates: [ServerTemplate] = []
    @State private var wfLoaded = false
    @State private var showGroupCreate = false
    @State private var groupTarget: GroupTarget?
    /// The list of sub-agents and background tasks, opened from their one line.
    @State private var showTasks = false
    /// Stick-to-bottom. The transcript follows new content only while the
    /// reader is at the end; scrolled up to reread, nothing drags them down —
    /// a small pill offers the way back once more has arrived. (The user,
    /// 2026-10-14: every refresh mid-generation yanked the page away.)
    @State private var atBottom = true
    @State private var viewportHeight: CGFloat = 0
    @State private var lastContentHeight: CGFloat = 0
    /// The viewport height last seen by the end tracker (iOS 18+): a shrink
    /// with the content unchanged is the keyboard, not a finger.
    @State private var lastVisibleHeight: CGFloat = 0
    /// The transcript pins itself to the end once per conversation on screen;
    /// re-appearing (back from a sub-view) must not move a reader who was up.
    @State private var pinnedOnce = false
    @State private var unreadBelow = false
    @State private var historyLoadedOnce = false
    /// Why a word was not sent: this conversation's group is running it.
    @State private var groupGuardText: String?
    /// The group this conversation belongs to, when opened on its own (a
    /// member reached from the list/search) — shows the way back to the group.
    @State private var memberOfGroup: ChatGroup?
    /// A `pervio-file:` link tapped in a bubble — the Mac path to preview.
    @FocusState private var inputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    /// Hashable wrapper so navigationDestination(item:) can push the workflow
    /// monitor from a tapped wfId chip; a fresh UUID means tapping the same chip
    /// again still navigates.
    private struct WorkflowChipTarget: Identifiable, Hashable {
        let id = UUID()
        let wfId: String
    }
    private struct GroupTarget: Identifiable, Hashable {
        let id = UUID()
        let group: ChatGroup
        /// The member whose pane the group page opens on (nil = the primary).
        var focus: String? = nil
    }

    /// `initialInput` prefills the composer (e.g. the market's "Build with
    /// Claude" entry seeds the builder prompt). Never auto-sent — the user
    /// appends their own ask and taps send.
    /// `pervioContext: true` = a wf-born entry (Monitor/reader discuss, Build
    /// with Claude): the conversation starts with the workflows-context chip ON,
    /// so its turns carry `--pervio-context`. Default false = fully native chat.
    /// `embedded: true` = one pane of a GroupView: no toolbar, no history
    /// drawer, no pair-up entry (the group owns those), everything else — live
    /// stream, approvals, composer for a private word to this member — intact.
    init(profile: ServerProfile, secret: String, dir: String? = nil,
         resumeSessionId: String? = nil, pillEnabled: Bool = true,
         initialInput: String? = nil, pervioContext: Bool = false,
         initialAttachments: [Attachment] = [],
         embedded: Bool = false, carryOver: CarryOver? = nil,
         store: ChatStore? = nil) {
        let d = (dir?.isEmpty == false ? dir! : profile.projectDir)
        _dir = State(initialValue: d)
        self.carryOver = carryOver
        self.pillEnabled = pillEnabled
        self.embedded = embedded
        self.secret = secret
        self.initialInput = initialInput ?? ""
        // `store` is a test seam (default nil = a store on the real connection):
        // the typing/streaming probe hosts the REAL chat page over a store it
        // drives against a scripted Mac, so what it measures is the page the
        // person types into, not a model of it.
        _store = StateObject(wrappedValue: store ?? ChatStore(profile: profile, secret: secret,
                                                              dir: d, resumeSessionId: resumeSessionId,
                                                              pervioContext: pervioContext,
                                                              initialAttachments: initialAttachments))
        _history = StateObject(wrappedValue: SessionService(profile: profile, secret: secret))
    }

    /// Snapshot seam (additive, default-off in the app): the composer slice
    /// with the workflow panel OPEN and the given templates already loaded —
    /// so the fork key's lit state and the picker rows can be rendered
    /// deterministically without a simulator or a server.
    init(previewComposerProfile profile: ServerProfile, secret: String,
         templates: [ServerTemplate]) {
        _dir = State(initialValue: profile.projectDir)
        self.carryOver = nil
        self.pillEnabled = true
        self.embedded = false
        self.secret = secret
        self.initialInput = ""
        _showWfSuggest = State(initialValue: true)
        _wfTemplates = State(initialValue: templates)
        _wfLoaded = State(initialValue: true)
        _store = StateObject(wrappedValue: ChatStore(profile: profile, secret: secret))
        _history = StateObject(wrappedValue: SessionService(profile: profile, secret: secret))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            chatContent
            if showHistory {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showHistory = false } }
                historyDrawer
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!embedded)
        .toolbar {
            if !embedded {
                BarItem(.navigationBarLeading) {
                    HStack(spacing: 2) {
                        BarGlyph(systemImage: "chevron.left", label: "Back") { dismissChat() }
                            .accessibilityIdentifier("bar-back")
                        BarGlyph(systemImage: "sidebar.left", label: "History") { openHistory() }
                    }
                }
                BarItem(.principal) { modelHeader }
                BarItem(.navigationBarTrailing) {
                    // New conversation: here, or in another directory (picked
                    // on the Mac), optionally carrying this one as 背景. The
                    // directory is chosen where a conversation is born — not a
                    // chip by the input (the user: 太丑了, 2026-10-15).
                    Menu {
                        Section((dir as NSString).lastPathComponent) {
                            Button { store.reset() } label: {
                                Label(L.dirNewHere(), systemImage: "square.and.pencil")
                            }
                            Button { switchDir(carry: false) } label: {
                                Label(L.dirNewElsewhere(), systemImage: "folder")
                            }
                            if !dirIsFree {
                                Button { switchDir(carry: true) } label: {
                                    Label(L.dirNewElsewhereCarry(), systemImage: "folder.badge.plus")
                                }
                            }
                        }
                        if store.sessionId != nil {
                            // The conversation on screen, gone — red, apart from the
                            // new-conversation rows, and never while it is working.
                            Section {
                                Button(role: .destructive) { confirmDeleteCurrent = true } label: {
                                    Label(L.deleteConversation(), systemImage: "trash")
                                }
                                .disabled(store.isBusy || store.activeRunId != nil)
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.body.weight(.medium)).frame(width: 30, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("new-chat-menu")
                }
            }
        }
        .onChange(of: groupRefresh) { _, _ in
            if embedded { Task { await store.resume() } }
        }
        .confirmDeleteConversation($pendingDelete) { deleteSession($0) }
        // A file picked on another computer is a link out of its folder: where
        // it leads, and whether that is the file wanted — before it is read.
        .alert(store.linkQuestion.map { L.remoteLinkTitle($0.name) } ?? "",
               isPresented: Binding(get: { store.linkQuestion != nil },
                                    set: { if !$0, store.linkQuestion != nil { store.answerLink(false) } }),
               presenting: store.linkQuestion) { _ in
            Button(L.remoteLinkBring()) { store.answerLink(true) }
            Button(L.remoteLinkSkip(), role: .cancel) { store.answerLink(false) }
        } message: { q in
            Text(L.remoteLinkBody(q.real, q.computer))
        }
        .alert(L.deleteConversationAsk(), isPresented: $confirmDeleteCurrent) {
            Button(L.delete(), role: .destructive) { deleteCurrent() }
            Button(L.cancel(), role: .cancel) {}
        } message: {
            Text(L.deleteConversationBody(currentTitle))
        }
        .alert(L.renameConversation(), isPresented: $showRename) {
            TextField(L.renamePrompt(), text: $renameText)
            Button(L.save()) {
                guard let sid = store.sessionId else { return }
                let t = renameText
                Task { try? await history.rename(session: sid, title: t) }
            }
            Button(L.cancel(), role: .cancel) {}
        } message: { Text(L.renamePrompt()) }
        .sheet(isPresented: $showTerminal, onDismiss: {
            // The terminal's custom keyboard can leave the chat's keyboard-avoidance
            // stale; drop focus + any keyboard so the composer re-anchors above the
            // keyboard when you next tap the input (else the keyboard covers it).
            inputFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }) {
            NavigationStack {
                TerminalScreen(profile: store.profile, secret: secret, dir: dir, pillEnabled: false)
                    .toolbar {
                        BarItem(.cancellationAction) {
                            BarWord(text: L.done(), weight: .semibold) {
                                // Drop the terminal's custom keyboard FIRST, then dismiss
                                // next runloop, so its input-view frame retracts before the
                                // sheet closes and doesn't linger over the chat composer.
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                DispatchQueue.main.async { showTerminal = false }
                            }
                        }
                    }
            }
            .environmentObject(appStore)
        }
        .sheet(isPresented: $showDirPicker) {
            DirectoryPickerSheet(profile: store.profile, secret: secret, startPath: dir) { d in
                showDirPicker = false
                guard d != dir else { return }
                if let (from, summary) = pendingCarry, !dirIsFree {
                    pendingCarry = nil
                    carryTarget = CarryOver(dir: d, fromDir: from, session: summary)
                } else {
                    // Nothing said yet: this conversation simply moves there.
                    pendingCarry = nil
                    dir = d
                    store.profile.projectDir = d
                }
            }
        }
        .sheet(isPresented: $showConfig) {
            ChatConfigView(profile: $store.profile, backendLocked: store.sessionId != nil)
        }
        // Absolute-path links in replies open as a QuickLook preview of the
        // file on the Mac — UITextView taps arrive via the environment handler,
        // SwiftUI Text links (table cells) via openURL.
        // The same three actions for the page's life (see `links`), never
        // closures built here: those are new values on every body.
        .environment(\.openServerFile, links.openServerFile)
        .environment(\.openLocalURL, links.openLocalURL)
        .environment(\.openURL, links.openURL)
        .sheet(item: $links.webPreview) { t in
            WebPreviewPage(profile: store.profile, secret: secret, port: t.port, path: t.path, store: store)
        }
        .sheet(item: $links.previewFile) { target in
            ServerFilePreview(profile: store.profile, secret: secret, path: target.path)
        }
        .sheet(item: $detailTool) { ToolDetailView(call: $0, fetch: { await store.fetchToolDetail($0) }) }
        .sheet(item: $store.pendingPlan) { approval in
            PlanApprovalSheet(plan: approval.plan,
                              onProceed: { store.approvePlan() },
                              onRefine: { store.refinePlan($0) },
                              onDismiss: { store.dismissPlan() })
        }
        .sheet(item: $store.pendingPermission) { pend in
            PermissionApprovalSheet(call: pend.call,
                                    onAllow: { store.allowTool() },
                                    onDeny: { store.denyTool(message: $0) })
        }
        // A tapped Workflow chip (wfId from pervio_start/pervio_rerun) attaches the
        // live monitor, same as opening the run from the Workflows list.
        .navigationDestination(item: $monitorWorkflow) { target in
            WorkflowMonitorView(profile: store.profile, secret: secret, wfId: target.wfId)
        }
        // 双开: this conversation becomes the primary of a group; the group
        // page shows every member live and takes the shared message.
        .navigationDestination(item: $groupTarget) { target in
            GroupView(profile: store.profile, secret: secret, group: target.group, focusMember: target.focus)
        }
        // A directory switch on a started conversation: a NEW conversation in
        // the chosen directory, this one attached as 背景 when asked.
        .navigationDestination(item: $carryTarget) { t in
            ChatView(profile: store.profile, secret: secret, dir: t.dir, carryOver: t)
        }
        .sheet(isPresented: $showTasks) { BackgroundTaskSheet(store: store) }
        // A sub-agent asking for Allow/Deny is blocked until answered, and one
        // sheet at a time can be up: the list gives way to the question.
        .onChange(of: store.pendingPermission != nil || store.pendingPlan != nil) { _, asking in
            if asking { showTasks = false }
        }
        .sheet(isPresented: $showGroupCreate) {
            GroupCreateSheet(profile: store.profile, secret: secret, dir: dir,
                             primarySession: store.sessionId ?? "",
                             onCreated: { g in showGroupCreate = false; groupTarget = GroupTarget(group: g) })
        }
        // Remember model / effort / run-mode / permission changes on the saved
        // server so they don't reset when you reopen a conversation.
        .onChange(of: store.profile) { _, p in
            // Pending attachments need no backend-switch handling: every one of
            // them is a path into ~/.pervio/uploads, which BOTH backends read.
            // Save ONLY to this conversation's own slot — never the shared server
            // profile, so changing one conversation's effort/model can't leak into
            // another. (New chats with no id yet get captured in onChange(sessionId).)
            if let sid = store.sessionId {
                appStore.saveParams(ConvParams(p), for: sid, on: p)
            }
        }
        .onChange(of: store.sessionId) { _, _ in
            appStore.chatDidChangeSession(store)
        }
        .task {
            await store.start()
            if let c = carryOver, let s = c.session {
                store.attachContextAsync(projectPath: c.fromDir, session: s)
            }
            if !embedded, let sid = store.sessionId,
               let groups = try? await history.groupList(dir: dir) {
                memberOfGroup = groups.first { g in g.keyedMembers.contains { $0.member.session == sid } }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            store.isForeground = (phase == .active)                 // gates watching vs. away pings
            switch phase {
            case .background: store.handleBackground()              // drop dead socket on suspend
            case .active: Task { await store.resume() }             // reconnect in place on return
            default: break
            }
        }
        .onDisappear {
            store.isOnScreen = false
            Task { await store.disconnect() }
            Task { await history.disconnect() }
        }
        .onAppear {
            store.isOnScreen = true
            appStore.activateRuns(for: store.profile, secret: secret)   // keep the runs pill alive here too
            // The engine roster (engines, providers, vendor presets) is probed at
            // launch for the HOME server only; a chat on another server, or a
            // roster cached by an older build, had an empty badge menu and an
            // "add provider" sheet with no vendors (a tester, 2026-10-15).
            if EngineStore.shared.probe(for: store.profile)?.presets.isEmpty ?? true, !secret.isEmpty {
                Task { _ = await EngineStore.shared.refresh(profile: store.profile, secret: secret) }
            }
            // Re-appearing (navigated back from a sub-view like the workflow monitor)
            // while a turn finished off-screen: silently pull its reply into the
            // transcript. Only when the store is already populated — a cold first
            // appear is `.task { start() }`'s job, and this guard keeps the two from
            // racing a double load. No-op if idle/nothing-new (silent + reconciled).
            if !store.messages.isEmpty {
                Task { await store.refreshHistoryIfIdle() }
            }
            // Restore THIS conversation's own knobs if it has saved any; otherwise
            // fall back to the server's configured default (set in the profile
            // editor — never another conversation's). dir/host stay as-is. One
            // routine with the drawer-switch path, so no knob (provider!) can be
            // restored by one and forgotten by the other.
            appStore.restoreKnobs(into: &store.profile, sessionId: store.sessionId)
        }
        .runPill(enabled: pillEnabled)
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            if let g = memberOfGroup, !embedded {
                Button {
                    let me = g.keyedMembers.first { $0.member.session == store.sessionId }?.key
                    groupTarget = GroupTarget(group: g, focus: me)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.fill").foregroundStyle(Palette.accent)
                        Text(L.groupBackTo()).font(.caption.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Palette.surface)
                }
                .buttonStyle(.plain)
            }
            if store.isLoadingHistory {
                ProgressView("Loading history…").padding(8)
            }
            if store.messages.isEmpty && !store.isLoadingHistory {
                // Empty / brand-new chat: keep the prompt near the top. It lives
                // OUTSIDE the transcript ScrollView so the bottom scroll anchor
                // (which opens existing chats at the newest message) can't push it
                // down to sit just above the composer.
                emptyState
                Spacer(minLength: 0)
            } else {
                transcript
            }
        }
        // Pin the composer (attachments + input) to the bottom as a safe-area
        // inset so it always sits above the keyboard — even when the attachments
        // bar appears/disappears (a plain VStack left the field stale under the
        // keyboard once a chip was added).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // A group pane has NO composer of its own: the group strip is the
            // one place to type, with a target chip for "everyone / this one".
            // Two stacked input boxes was the first thing the user called ugly.
            if !embedded {
                VStack(spacing: 0) {
                    ConversationDirsBar(store: store)
                    ComposerAttachmentsBar(store: store)
                    compactingBar
                    queuedBar
                    groupGuardBar
                    modeBar
                    if showWfSuggest { wfSuggestBar }
                    if store.takeoverOffer != nil { takeoverBar }
                    if store.cursorLoginOffer != nil { cursorLoginBar }
                    if !store.backgroundTasks.isEmpty {
                        BackgroundTaskBar(tasks: store.backgroundTasks) { showTasks = true }
                    }
                    inputBar
                }
                .background(Palette.bg)
            }
        }
        .background(Palette.bg.ignoresSafeArea())
    }

    // MARK: - Top bar

    /// Compact, Claude-app-style centered model selector + context ring, with the
    /// rolling-usage line tucked directly under the model name (a nav-bar subtitle)
    /// rather than as a separate band above the transcript.
    /// The engine badge: engine icon + model + provider, the same shape the
    /// design settled on (2026-10-14). Tapping opens a menu of ready-made
    /// combos — every installed engine × its providers, each at the provider's
    /// default model — so switching is one tap; "More settings…" is the full
    /// sheet. Once the conversation has started the engine is locked (its
    /// session id belongs to that CLI), so only the current engine's combos show.
    private var modelHeader: some View {
        Menu {
            let probe = EngineStore.shared.probe(for: store.profile)
            let locked = store.sessionId != nil
            let engines = AgentBackend.allCases.filter { b in
                if locked { return b == store.profile.backend }
                guard let probe else { return b == store.profile.backend }   // nothing probed yet
                return probe.has(b) || b == store.profile.backend
            }
            ForEach(engines) { b in
                Section(b.label) {
                    Button { pick(engine: b, provider: nil) } label: {
                        Label(b.tag + " · " + L.providerAccountDefault(), systemImage: "person.crop.circle")
                    }
                    ForEach(probe?.providers(for: b) ?? []) { p in
                        Button { pick(engine: b, provider: p) } label: {
                            Label(b.tag + " · " + p.label, systemImage: "network")
                        }
                    }
                }
            }
            if locked {
                Text(L.engineLockedNote())
            }
            Divider()
            Button { showConfig = true } label: { Label(L.engineMoreSettings(), systemImage: "slider.horizontal.3") }
            if store.sessionId != nil {
                Button { renameText = ""; showRename = true } label: { Label(L.renameConversation(), systemImage: "pencil.line") }
            }
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 6) {
                    Image(store.profile.backend.iconAsset)
                        .resizable().scaledToFit()
                        .frame(width: 16, height: 16)
                    if store.contextWindow > 0 {
                        ContextRingView(used: store.contextTokens, total: store.contextWindow)
                    }
                    Text(headerTitle)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    // The vendor behind the engine: its logo + name after the model,
                    // the engine's own icon staying in front — "Claude Code on GLM"
                    // reads at a glance (the person's layout, 2026-10-16).
                    if let ap = activeProviderInfo {
                        VendorMark(preset: ap.preset, label: ap.label, size: 14)
                        Text(ap.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if let pl = providerLabel {
                        Text("· " + pl).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if store.profile.backend == .cursor,
                              let v = CursorModelVendor.of(store.modelName.isEmpty ? store.profile.cursorModel : store.modelName) {
                        // Cursor runs many vendors' models under one roof: the
                        // mark follows the pick (the person's ask, 2026-10-18).
                        VendorMark(preset: v.preset, label: v.label, size: 14)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                usageLine
            }
        }
        // A fixed handle for the UI smoke test (SmokeTests: provider survives
        // re-entry); the label's text changes with the model and vendor.
        .accessibilityIdentifier("engine-badge")
    }

    /// One tap on a combo: the engine (when not locked), the provider, and the
    /// provider's default model so the first message runs on a model that
    /// vendor actually has. ChatView's onChange(of: store.profile) persists it.
    private func pick(engine: AgentBackend, provider: ProviderInfo?) {
        if store.sessionId == nil, store.profile.backend != engine {
            store.profile.backend = engine
            store.modelName = ""      // the badge names the NEW engine's model, not the old one's
            store.usage = nil
        }
        if engine.supportsProviders {
            store.profile.provider = provider?.name ?? ""
            let model = provider?.defaultModel ?? (engine == .codex ? "" : ModelOption.recommended)
            if engine == .codex { store.profile.codexModel = model } else { store.profile.model = model }
        } else {
            store.profile.provider = ""
        }
    }

    private var activeProviderInfo: ProviderInfo? {
        guard store.profile.backend.supportsProviders, !store.profile.provider.isEmpty else { return nil }
        return EngineStore.shared.probe(for: store.profile)?.provider(named: store.profile.provider)
    }

    private var providerLabel: String? {
        guard store.profile.backend.supportsProviders, !store.profile.provider.isEmpty else { return nil }
        return EngineStore.shared.probe(for: store.profile)?.provider(named: store.profile.provider)?.label
            ?? store.profile.provider
    }

    /// Header title: the resolved model name, or the engine's own name when
    /// the stream has not surfaced one (Codex; Cursor before its init).
    private var headerTitle: String {
        if !store.modelName.isEmpty { return store.modelName }
        let configured = store.profile.activeModel
        return configured.isEmpty ? store.profile.backend.tag : configured
    }

    /// Quiet usage subtitle under the model name (nil until loaded). Two shapes,
    /// one per backend — never mixed (ChatStore filters by backend before this
    /// point; see UsageInfo.pools): claude's 5h/7d/scoped pools, or codex's single
    /// weekly plan window read from its own rollout.
    @ViewBuilder private var usageLine: some View {
        if let u = store.usage, let five = u.fiveHour?.utilization {
            HStack(spacing: 4) {
                Text("5h \(Int(five.rounded()))%")
                if let reset = Self.shortTime(u.fiveHour?.resetsAt) {
                    Text("· resets \(reset)")
                }
                if let seven = u.sevenDay?.utilization {
                    Text("· 7d \(Int(seven.rounded()))%")
                }
                // Model-scoped pools (e.g. Fable's own weekly cap) move
                // independently of the overall windows — hiding them painted
                // a green picture over a nearly-spent Fable week. Critical
                // severity gets the one color this quiet line allows itself.
                ForEach(u.scoped ?? [], id: \.name) { pool in
                    if let pct = pool.percent {
                        Text("· \(pool.name) \(Int(pct.rounded()))%")
                            .foregroundStyle(pool.severity == "critical"
                                             ? AnyShapeStyle(.orange)
                                             : AnyShapeStyle(.secondary))
                    }
                }
                // The server fell back to an old cache — these are real numbers
                // on an old clock. Say so, instead of selling last week as now.
                if u.stale == true { Text("· 旧").foregroundStyle(.tertiary) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else if let u = store.usage, let weekly = u.weekly?.utilization {
            // Codex reports ONE window (its plan's week). Say "weekly" out loud —
            // an unlabelled percentage next to a codex icon would read as the same
            // 5h number claude shows, which is a different account entirely.
            HStack(spacing: 4) {
                Text("weekly \(Int(weekly.rounded()))%")
                if let reset = Self.shortReset(u.weekly?.resetsAt) {
                    Text("· resets \(reset)")
                }
                if u.stale == true { Text("· 旧").foregroundStyle(.tertiary) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    /// "2026-06-10T05:50:00.651364+00:00" → local "HH:mm" (or nil).
    static func shortTime(_ iso: String?) -> String? {
        guard let date = parseReset(iso) else { return nil }
        let df = DateFormatter(); df.dateFormat = "HH:mm"
        return df.string(from: date)
    }

    /// Same instant, but readable for a window that resets DAYS away: a weekly cap
    /// rendered as bare "09:00" reads as "in a few hours", which is the opposite of
    /// what it means. Within a day it stays "HH:mm".
    static func shortReset(_ iso: String?) -> String? {
        guard let date = parseReset(iso) else { return nil }
        let df = DateFormatter()
        df.dateFormat = date.timeIntervalSinceNow < 20 * 3600 ? "HH:mm" : "MMM d"
        return df.string(from: date)
    }

    private static func parseReset(_ iso: String?) -> Date? {
        guard var s = iso else { return nil }
        if let r = s.range(of: "\\.\\d+", options: .regularExpression) { s.removeSubrange(r) }
        return ISO8601DateFormatter().date(from: s)
    }

    // MARK: - History drawer

    private func openHistory() {
        historySearch = ""
        withAnimation(.easeOut(duration: 0.22)) { showHistory = true }
        Task { await loadSessions() }
    }

    private var historyDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversations").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Text((dir as NSString).lastPathComponent)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 8)
            Divider()

            if loadingSessions {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                    .padding(16)
                Spacer()
            } else if sessions.isEmpty {
                Text("No conversations here yet.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(16)
                Spacer()
            } else {
                searchField
                if filteredSessions.isEmpty {
                    Text("No matches.")
                        .font(.subheadline).foregroundStyle(.secondary).padding(16)
                    Spacer()
                } else {
                    List {
                        ForEach(filteredSessions) { session in
                            Button { switchTo(session) } label: { drawerRow(session) }
                                .listRowBackground(session.id == store.sessionId
                                                   ? Palette.accent.opacity(0.18) : Palette.bg)
                                .swipeActions(edge: .trailing) {
                                    // Plain + red, not role .destructive: the row stays until
                                    // the question is answered (see SessionsView).
                                    Button { pendingDelete = session } label: {
                                        Label(L.delete(), systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .frame(maxWidth: 310, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.bg)
        .shadow(color: .black.opacity(0.4), radius: 14, x: 4, y: 0)
        .ignoresSafeArea(edges: .bottom)
    }

    /// Persistent search box atop the conversation list (filters by title).
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.footnote).foregroundStyle(.secondary)
            TextField("Search conversations", text: $historySearch)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !historySearch.isEmpty {
                Button { historySearch = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline, lineWidth: 1))
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Conversations matching the search text (by title / first message).
    private var filteredSessions: [SessionSummary] {
        let q = historySearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter { $0.title.lowercased().contains(q) }
    }

    private func drawerRow(_ session: SessionSummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: session.id == store.sessionId
                  ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                .foregroundStyle(.tint).font(.callout).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).lineLimit(2).font(.subheadline)
                    .foregroundStyle(.primary)
                Text(session.modifiedDate, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func loadSessions() async {
        loadingSessions = true
        defer { loadingSessions = false }
        sessions = (try? await history.sessions(dir: dir)) ?? []
    }

    private func switchTo(_ session: SessionSummary) {
        withAnimation(.easeOut(duration: 0.2)) { showHistory = false }
        guard session.id != store.sessionId else { return }
        // Carry the row's own backend: the drawer merges claude + codex
        // conversations, and opening one must drive ITS agent (icon, transcript
        // store, next send) — same as SessionsView.resumeProfile on the list route.
        Task { await store.open(sessionId: session.id, backend: session.agent) }
    }

    private func deleteSession(_ session: SessionSummary) {
        sessions.removeAll { $0.id == session.id }   // optimistic
        appStore.removeParams(for: session.id, on: store.profile)       // drop this conversation's saved knobs
        let onScreen = store.sessionId == session.id
        Task {
            if onScreen { await store.forgetConversation() }   // its process first, or it writes the record back
            try? await history.delete(dir: dir, session: session.id, backend: session.agent)
        }
    }

    /// The pencil menu's red row: the conversation on screen, confirmed.
    private var currentTitle: String {
        if let sid = store.sessionId, let s = sessions.first(where: { $0.id == sid }) { return s.title }
        return store.messages.first(where: { $0.role == .user })?.text ?? ""
    }

    private func deleteCurrent() {
        guard let sid = store.sessionId else { return }
        let backend = store.profile.backend
        sessions.removeAll { $0.id == sid }
        appStore.removeParams(for: sid, on: store.profile)
        Task {
            await store.forgetConversation()
            try? await history.delete(dir: dir, session: sid, backend: backend)
        }
    }

    /// 长按用户气泡 → 「从这里重新说」: fork the conversation server-side BEFORE this
    /// message (all earlier history kept, this message and everything after
    /// dropped), switch to the branch, and prefill the composer with the bubble's
    /// text for rewording. The original conversation stays in the drawer intact.
    private func restate(from message: ChatMessage) {
        guard let uuid = message.serverUuid else { return }
        let original = message.text
        Task {
            if await store.restateFork(beforeUuid: uuid) {
                composerPrefill = ComposerPrefill(text: original)
                Haptics.success()
            }
            // Failure already surfaced through the standard ⚠️ system bubble.
        }
    }

    /// 「分支到新对话」(a tester's ask, 2026-10-16): fork the conversation THROUGH
    /// this message's turn into a new one and switch to it; the original stays
    /// in the drawer. Works from a reply (its turn) or from a typed message.
    private func branch(from message: ChatMessage) {
        guard let uuid = store.branchAnchorUuid(for: message) else { return }
        Task {
            if await store.branchFork(afterUuid: uuid) { Haptics.success() }
        }
    }

    // MARK: - Transcript

    /// Tool-chip tap. An ExitPlanMode chip reopens the plan-approval sheet — without
    /// this the plan is unreviewable after "Later" or a reattach (the sheet only
    /// auto-pops at the end of a live turn). A Workflow chip (a pervio_start /
    /// pervio_rerun that answered with a wfId) pushes the live workflow monitor.
    /// Every other chip opens the generic diff/detail view, as before.
    private func openTool(_ call: ToolCall) {
        if call.name == "ExitPlanMode" {
            store.reopenPlan(from: call)
        } else if let wfId = call.workflowChipId {
            monitorWorkflow = WorkflowChipTarget(wfId: wfId)
        } else {
            detailTool = call
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Plain VStack, NOT LazyVStack: it lays out and measures every row up
                // front, so the end position is exact. A LazyVStack reports off-screen
                // rows with ESTIMATED heights, so the trailing marker lands too high,
                // scrollTo stops short, and the un-realized tall rows below never get
                // scrolled into existence to correct it — the transcript jams partway
                // down (blank, or cut off mid-message). Transcripts are bounded, so
                // eager layout is the right trade for landing reliably at the bottom.
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(store.messages) { msg in
                        // 「从这里重新说」 rides the user bubble's long-press menu —
                        // Claude sessions only (codex rollouts use a different
                        // session store/format; not this batch), and only once the
                        // message's server-side uuid has been back-filled (the fork
                        // verb addresses messages by uuid; see refreshUserUuids).
                        MessageRow(message: msg, onTapTool: openTool,
                                   onRestate: msg.role == .user && msg.serverUuid != nil
                                       && store.profile.backend != .cursor
                                       ? restate(from:) : nil,
                                   onBranch: (msg.role == .user || msg.role == .assistant)
                                       && store.isTurnEnd(msg)
                                       && store.branchAnchorUuid(for: msg) != nil
                                       ? branch(from:) : nil)
                            // Closures compare as "changed" every time, so without
                            // this every row re-ran its body on every landed chunk —
                            // the whole transcript re-rendered ~16×/s while a reply
                            // streamed, and scrolling up through history stuttered
                            // ("向上滑动卡卡的", 2026-10-15). Equatable on the message
                            // (and whether the row offers restate) lets SwiftUI skip
                            // the rows that did not change.
                            .equatable()
                    }
                    if store.backgroundTasks.isEmpty && !store.backgroundDone.isEmpty {
                        // What ran beside the conversation has all ended: one line
                        // saying how it went (while anything runs, the line above
                        // the composer does the counting). The list is a tap away.
                        BackgroundTaskCard(done: store.backgroundDone) { showTasks = true }
                            .padding(.horizontal, 12).padding(.top, 4)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: BottomMarkerKey.self,
                                                   value: g.frame(in: .named("transcript")).minY)
                        })
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .coordinateSpace(name: "transcript")
            .background(GeometryReader { outer in
                Color.clear
                    .onAppear { viewportHeight = outer.size.height }
                    .onChange(of: outer.size.height) { _, h in viewportHeight = h }
            })
            // iOS 17 fallback. The observer must sit on the ScrollView ITSELF: a
            // preference flows up to ancestors, and the old `.background { …
            // .onPreferenceChange }` was a sibling branch that never received it
            // — so `atBottom` stayed at its initial `true` forever and every
            // landed chunk scrolled the reader to the end (measured 2026-10-15:
            // the probe's preference callback never fired at all). Even placed
            // right it is re-read on layout, not on a plain finger scroll; iOS 18+
            // uses the scroll geometry below instead.
            .onPreferenceChange(BottomMarkerKey.self) { y in
                if #available(iOS 18.0, *) { return }
                noteDistanceFromEnd(y - viewportHeight)
            }
            .modifier(TranscriptEndTracking(onDistance: { d, h, vh in noteDistanceFromEnd(d, contentHeight: h, visibleHeight: vh) }))
            .overlay(alignment: .bottom) {               // centered: easier to reach, reads as "below you"
                if unreadBelow && !atBottom {
                    Button {
                        unreadBelow = false
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Label(L.newBelow(), systemImage: "arrow.down")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Palette.surface2, in: Capsule())
                            .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Open existing chats already pinned to the newest message, and let
            // the SCROLL VIEW itself keep the reader's place as the transcript
            // grows: anchored to the end only while they are at the end (a
            // streaming reply is followed), to the top once they scrolled up
            // (new text never pushes them). This used to be a bare
            // defaultScrollAnchor(.bottom), which on iOS also re-pins the END on
            // every size change — so each streamed chunk yanked a reader back
            // down, and the animated scrollTo fired per chunk on top of it
            // (the "顶上去" + "卡" of 2026-10-15).
            .modifier(TranscriptAnchoring(atBottom: atBottom))
            .scrollDismissesKeyboard(.interactively)   // drag down on messages to hide the keyboard
            .onChange(of: store.messages.count) { _, _ in
                // A new ROW (your message, the reply's first row): at the end,
                // land on it; scrolled up, note it instead.
                guard !store.isLoadingHistory else { return }
                if atBottom {
                    proxy.scrollTo("bottom", anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { unreadBelow = true }
                }
            }
            .onChange(of: tailSignature) { _, _ in
                // Growth INSIDE the last row (a streaming reply): follow it only
                // while the reader is at the end — unanimated, and at most ~16
                // times a second (ChatStore coalesces the chunks). Scrolled up,
                // nothing moves; the "new below" pill shows instead (once).
                // Comparing a couple of ints per chunk, not whole message
                // arrays, is what keeps long transcripts smooth.
                guard !store.isLoadingHistory else { return }
                if atBottom {
                    proxy.scrollTo("bottom", anchor: .bottom)
                } else if !unreadBelow {
                    withAnimation(.easeOut(duration: 0.2)) { unreadBelow = true }
                }
            }
            .onChange(of: store.isLoadingHistory) { _, loading in
                guard !loading else { return }
                // History just landed: pin the FIRST load; a reload (a group pane
                // re-syncing each round) keeps the reader's place unless they
                // were at the end anyway.
                if !historyLoadedOnce || atBottom { scrollToEnd(proxy) }
                else { withAnimation(.easeOut(duration: 0.2)) { unreadBelow = true } }
                historyLoadedOnce = true
            }
            .onAppear {
                // Reopen / foreground-resume keeps messages in memory (no loading
                // flip) — pin here too. This is the path that worked on "refresh".
                // But only ONCE per conversation on screen, or while following:
                // coming back from a sub-view used to drop a reader who had
                // scrolled up straight to the end (Astra's review, 2026-10-15).
                if !pinnedOnce || atBottom { scrollToEnd(proxy) }
                pinnedOnce = true
            }
            .onChange(of: inputFocused) { _, focused in
                // When the keyboard opens, scroll the latest message into view
                // (after the keyboard animation settles) so it isn't covered.
                // Decided ONCE, as the keyboard starts up: the keyboard shrinks
                // the viewport, which reads as "the end moved away" and used to
                // flip `atBottom` before this delayed scroll ran, so the reply
                // stayed hidden under the keyboard (a tester, 2026-10-18).
                guard focused, atBottom else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    /// "At the end" = within a short reach of the end. Fed on every scroll and
    /// every content change (TranscriptEndTracking, iOS 18+), so reading
    /// history during a quiet stretch — a tool running, a Run-mode turn with
    /// nothing streaming — is seen as leaving the end. The marker preference
    /// alone was re-read only on layout, so a finger scroll left `atBottom`
    /// stale at true and the next reply snapped the reader to the end
    /// (measured 2026-10-15: row at y=175 → gone, view at the end, no pill).
    private func noteDistanceFromEnd(_ distance: CGFloat, contentHeight: CGFloat = 0, visibleHeight: CGFloat = 0) {
        let near = distance <= 120
        // Content growth (a chunk landed) or a shorter viewport (the keyboard
        // coming up) push the end away with the reader still at it: keep
        // following. Only a finger un-follows — see TranscriptEndFollow.
        let grew = contentHeight > lastContentHeight + 1
        let viewportShrank = visibleHeight > 0 && lastVisibleHeight > 0 && visibleHeight < lastVisibleHeight - 1
        defer {
            lastContentHeight = contentHeight
            if visibleHeight > 0 { lastVisibleHeight = visibleHeight }
        }
        if near, unreadBelow { unreadBelow = false }
        let now = TranscriptEndFollow.atEnd(near: near, wasAtEnd: atBottom, grew: grew, viewportShrank: viewportShrank)
        if now != atBottom { atBottom = now }
    }

    /// A cheap "the last row changed size" signal: its text, thinking and
    /// segment counts. Used instead of comparing the whole message array.
    private var tailSignature: Int {
        guard let m = store.messages.last else { return 0 }
        return m.text.count &* 31 &+ m.thinking.count &* 7 &+ m.segments.count
    }

    /// Where the trailing marker sits inside the transcript's own frame — the
    /// one number stick-to-bottom needs.
    private struct BottomMarkerKey: PreferenceKey {
        static var defaultValue: CGFloat = .infinity
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
    }

    /// Jump to the very end (the trailing 1pt marker = below the last row's spacing).
    /// Deferred to the next runloop so it runs after the layout that populated the
    /// rows commits; a backup pass covers the async `loadContext` settling.
    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard !store.messages.isEmpty else { return }
        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
        // The backup pass re-checks: a finger that moved in those 150ms wins.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.largeTitle).foregroundStyle(.tint)
            Text("Ask \(store.profile.backend.tag) anything")
                .font(.headline)
            Text(store.profile.projectDir)
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Composer

    /// A typed message, from the composer's Send. The SAME path queues it when a
    /// turn is already in flight, so a typed follow-up is never stranded or dropped.
    private func submitTyped(_ text: String) {
        atBottom = true          // your own words always come into view
        // A member of a group: while the group runs this conversation (a
        // round, a loop, a duo window), a word here would start a second
        // process on the same conversation — refuse, say why, hand the
        // text back. Nothing about permissions changes.
        if let g = memberOfGroup, !embedded {
            Task {
                if await groupIsRunning(g) {
                    groupGuardText = L.groupInGroupRunning()
                    composerPrefill = ComposerPrefill(text: text)
                    return
                }
                groupGuardText = nil
                store.submit(text)
            }
        } else {
            store.submit(text)
        }
    }

    /// Whether the directory can still change: nothing sent, nothing loaded.
    private var dirIsFree: Bool {
        // A connection error's system line is not a turn: the directory stays
        // free until the person has actually spoken (or a reply exists).
        store.sessionId == nil && !store.isBusy
            && !store.messages.contains { $0.role == .user || $0.role == .assistant }
    }

    /// Open the directory picker for a NEW conversation; the current one
    /// rides along as 背景 when asked (its transcript, exported on the Mac).
    private func switchDir(carry: Bool) {
        let from = dir
        let summary: SessionSummary? = carry ? store.sessionId.map {
            SessionSummary(id: $0, preview: store.messages.first { $0.role == .user }?.text ?? "",
                           modified: Int(Date().timeIntervalSince1970), bytes: 0,
                           backend: store.profile.backend, pinned: nil, pinnedAt: nil)
        } : nil
        pendingCarry = (from, summary)
        showDirPicker = true
    }
    @State private var pendingCarry: (String, SessionSummary?)?

    /// Fresh from the Mac, since the copy loaded at open may be minutes old. An
    /// unreachable Mac never blocks: the send then fails on its own terms.
    private func groupIsRunning(_ g: ChatGroup) async -> Bool {
        guard let groups = try? await history.groupList(dir: dir),
              let fresh = groups.first(where: { $0.id == g.id }) else { return false }
        memberOfGroup = fresh
        return fresh.isActive
    }

    @ViewBuilder private var groupGuardBar: some View {
        if let t = groupGuardText {
            HStack(spacing: 6) {
                Image(systemName: "person.2").font(.caption2)
                Text(t).font(.caption2)
            }
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 6)
        }
    }

    /// Hint shown while `/compact` is running: compaction emits no streamed text and
    /// can take a while on a long chat, so without this the spinner looks frozen.
    @ViewBuilder private var compactingBar: some View {
        if store.compacting {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Compacting context… (can take a while on a long chat)").font(.caption2)
            }
            .foregroundStyle(Palette.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 6)
        }
    }

    /// Hint shown above the input when follow-ups are waiting for the current turn.
    @ViewBuilder private var queuedBar: some View {
        if store.queuedCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "hourglass").font(.caption2)
                Text("\(store.queuedCount) queued · sends when ready").font(.caption2)
            }
            .foregroundStyle(Palette.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 6)
        }
    }

    /// Chat vs Run selector, sitting just above the input field.
    /// codex refused this turn — another client (VS Code) holds the thread. One
    /// tap ends that holder on the Mac and resends what was typed; the × just
    /// dismisses. Confirmation first: the other side's session is cut.
    private var takeoverBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            Text(L.takeoverHint()).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button(L.takeoverButton()) { confirmTakeover = true }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent).tint(.orange)
            Button { store.takeoverOffer = nil } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Palette.surface)
        .alert(L.takeoverConfirmTitle(), isPresented: $confirmTakeover) {
            Button(L.takeoverButton(), role: .destructive) { Task { await store.takeover() } }
            Button(L.cancel(), role: .cancel) {}
        } message: { Text(L.takeoverConfirmBody()) }
    }

    /// Cursor could not read its keychain login over SSH: one button logs the
    /// agent in to its file store (the link opens in the browser) and resends.
    private var cursorLoginBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.badge.key.fill").foregroundStyle(.orange)
            Text(store.cursorLoginBusy ? L.cursorLoginWaiting() : L.cursorLoginHint())
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button(L.cursorLoginButton()) { Task { await store.cursorLogin() } }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent).tint(.orange)
                .disabled(store.cursorLoginBusy)
                .accessibilityIdentifier("cursor-login")
            Button { store.cursorLoginOffer = nil } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(store.cursorLoginBusy)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Palette.surface)
        .onChange(of: store.cursorLoginURL) { _, url in
            if let url { openURL(url) }
        }
    }

    private var modeBar: some View {
        HStack(spacing: 8) {
            Button {
                Haptics.tick()
                withAnimation(.easeOut(duration: 0.18)) { store.profile.runMode.toggle() }
                appStore.setRunMode(store.profile.runMode, server: store.profile.id)   // the person's setting, kept per server
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: store.profile.runMode ? "moon.stars.fill" : "bubble.left.fill")
                        .font(.caption)
                    Text(store.profile.runMode ? "Run" : "Chat")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(store.profile.runMode ? Palette.accent : .secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(store.profile.runMode ? Palette.accent.opacity(0.15) : Palette.surface, in: Capsule())
                .overlay(Capsule().stroke(store.profile.runMode ? Palette.accent.opacity(0.55) : Palette.hairline,
                                          lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mode-chip")     // the UI smoke test flips Chat ↔ Run by it

            Text(store.profile.runMode ? "keeps running if you leave" : "live — stops if you leave")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Button { showTerminal = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "terminal").font(.caption)
                    Text("Terminal").font(.footnote.weight(.semibold))
                }
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Palette.surface, in: Capsule())
                .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 2)
    }

    /// The fork key's candidate strip — the CC-slash idiom: a compact list
    /// floating above the composer. Row 1 keeps the key's ORIGINAL function (the
    /// workflows-context toggle) so nothing is lost; then scratch + the server's
    /// own templates. Picking INSERTS a prompt; anything already typed becomes
    /// the request tail — type first, pick second, both orders work.
    private var wfSuggestBar: some View {
        ComposerWfPanel(store: store, preview: false, templates: wfTemplates, loaded: wfLoaded,
                        onPick: attachWf)
    }



    /// What the snapshot renders: the open panel over a composer-bar STAND-IN
    /// (the real bar's TextField cannot rasterize) — the fork key lit (panel
    /// open), rows loaded, same paddings and chrome as the real thing.
    var composerPreviewSlice: some View {
        VStack(spacing: 0) {
            ComposerWfPanel(store: store, preview: true, templates: wfTemplates, loaded: wfLoaded,
                            onPick: { _ in })
            HStack(alignment: .bottom, spacing: 6) {
                Image(systemName: "plus")
                    .font(.title3).foregroundStyle(Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(Palette.surface, in: Circle())
                    .overlay(Circle().stroke(Palette.hairline, lineWidth: 1))
                Image(systemName: "arrow.triangle.branch")
                    .font(.title3)
                    .foregroundStyle(Color.white)
                    .frame(width: 34, height: 34)
                    .background(Palette.accent, in: Circle())
                    .overlay(Circle().stroke(Palette.accent, lineWidth: 1))
                HStack(alignment: .bottom, spacing: 6) {
                    Text("Message \(store.profile.backend.tag)…")
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2).foregroundStyle(Palette.accent)
                }
                .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 10)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.hairline, lineWidth: 1))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }


    /// A workflow pick is a chip on the composer (the prompt rides the wire);
    /// the person types only their request.
    private func attachWf(_ att: Attachment) {
        store.attachments.removeAll { $0.inlinePrompt != nil }   // one builder at a time
        store.attachments.append(att)
        withAnimation(.snappy(duration: 0.18)) { showWfSuggest = false }
        inputFocused = true
    }

    private func loadWfTemplates() {
        Task {
            if let all = await ComposerWfTemplates.load(profile: store.profile, secret: secret) {
                wfTemplates = all
            }
            wfLoaded = true
        }
    }

    private var inputBar: some View {
        ComposerInputBar(store: store, secret: secret, dir: dir, initialInput: initialInput,
                         prefill: composerPrefill, focus: $inputFocused, showWfSuggest: $showWfSuggest,
                         onWfKey: { if !wfLoaded { loadWfTemplates() } },
                         onSend: submitTyped) {
            if !embedded {
                Divider()
                Button { showGroupCreate = true } label: {
                    Label(L.groupOpen(), systemImage: "rectangle.split.1x2")
                }
            }
        }
    }

    // MARK: - Attachments (upload from phone)




}

/// The composer's one key while a turn runs: Stop with nothing typed, Send
/// once there is something to say (2026-10-21, one button, not two).
enum ComposerKey: Equatable {
    case send, stop
    static func resolve(busy: Bool, hasText: Bool) -> ComposerKey {
        busy && !hasText ? .stop : .send
    }
}

/// A compact context-window usage gauge (green → orange → red).
struct ContextRingView: View {
    let used: Int
    let total: Int
    private var fraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
    private var color: Color { fraction < 0.6 ? .green : (fraction < 0.85 ? .orange : .red) }

    var body: some View {
        ZStack {
            Circle().stroke(Palette.hairline, lineWidth: 2.5)
            Circle().trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
    }
}

/// Collapsible "Thinking" reasoning, shown above an assistant answer.
private struct ThinkingView: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label("Thinking", systemImage: "brain")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }
}

/// What a user turn carried besides its words — files, images, a 背景
/// conversation, a handed-over directory — as chips on the bubble's side.
/// The wire text behind them (the list of paths, the reading guidance) is
/// the agent's business and is never shown (2026-10-15).
private struct AttachmentChipsRow: View {
    let chips: [String]
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, c in
                Text(c).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Palette.surface2, in: Capsule())
                    .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct MessageRow: View, Equatable {
    let message: ChatMessage
    var onTapTool: (ToolCall) -> Void = { _ in }
    /// Non-nil ⇒ the user bubble's long-press (edit) menu offers 「从这里重新说」.
    /// The caller gates it (Claude backend + a back-filled server uuid).
    var onRestate: ((ChatMessage) -> Void)? = nil
    /// Non-nil ⇒ 「分支到新对话」: in the user bubble's menu, and as a small
    /// button under a reply. The caller gates it (forkable engine + anchor).
    var onBranch: ((ChatMessage) -> Void)? = nil

    /// Only the content decides whether the row must re-render; the closures
    /// are the same actions every time (see `.equatable()` at the call site).
    static func == (a: MessageRow, b: MessageRow) -> Bool {
        a.message == b.message && (a.onRestate == nil) == (b.onRestate == nil)
            && (a.onBranch == nil) == (b.onBranch == nil)
    }

    private var menuItems: [SelectableText.EditMenuItem] {
        var items: [SelectableText.EditMenuItem] = []
        if let restate = onRestate {
            items.append(.init(title: L.restateFromHere()) { restate(message) })
        }
        if let branch = onBranch {
            items.append(.init(title: L.branchToNewChat(), systemImage: "arrow.triangle.branch") { branch(message) })
        }
        return items
    }

    /// The branch affordance under a finished reply: visible, so the feature is
    /// found; quiet, so it does not compete with the text.
    @ViewBuilder private var branchFooter: some View {
        if let branch = onBranch, !message.isStreaming {
            Button { branch(message) } label: {
                Label(L.branchToNewChat(), systemImage: "arrow.triangle.branch")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("branch-here")
        }
    }

    var body: some View {
        switch message.role {
        case .user:
            if GroupVia.isInjected(message.via) {
                // Composed by the group (a synthesis request, a review sheet, a
                // critique hand-off), not typed by the person: one quiet line,
                // the text behind a tap. As a bubble it read as something the
                // person had sent and could not remember (2026-10-14).
                GroupInjectedRow(message: message)
            } else {
            VStack(alignment: .trailing, spacing: 3) {
            if let via = message.via {
                // Delivered by a group, not typed here: say so, quietly.
                Text(GroupVia.label(via)).font(.caption2).foregroundStyle(.tertiary)
            }
            if let delivery = message.delivery {
                // Sent into a running turn and not part of it yet: on its way
                // to the Mac, or there and waiting for the engine.
                Text(delivery == .sending ? L.sendingTag() : L.awaitingTag())
                    .font(.caption2).foregroundStyle(.tertiary)
                    .accessibilityIdentifier("delivery-tag")
            } else if message.interjected {
                // Sent while the reply was being worked out: it went into that
                // turn, so the words after it are the rest of the same reply.
                Text(L.midTurnTag()).font(.caption2).foregroundStyle(.tertiary)
                    .accessibilityIdentifier("mid-turn-tag")
            }
            if !message.chips.isEmpty { AttachmentChipsRow(chips: message.chips) }
            if !message.text.isEmpty || message.chips.isEmpty {
            HStack {
                Spacer(minLength: 50)
                // UITextView-backed so selection actually starts inside the scroll
                // view (plain Text + .textSelection is unreliable here — same reason
                // assistant prose uses SelectableText). Long-press → drag handles /
                // Select All / Copy. `plain:` keeps the text verbatim. The rewind
                // entry joins that NATIVE menu (an EditMenuItem) instead of a
                // whole-message .contextMenu, which would break text selection.
                SelectableText(plain: message.text, menuItems: menuItems)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 18))
            }
            }
            }
            }
        case .assistant:
            // Likewise no whole-message .contextMenu — native text selection (per
            // paragraph/code block) is what lets you copy a single command or result.
            // Each code block also keeps its own Copy button (see RichMessageText).
            VStack(alignment: .leading, spacing: 6) {
                assistantBody
                branchFooter
            }
        case .tool:
            toolChip(message.text)
        case .system:
            Text(message.text).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.segments.isEmpty {
                // Render in execution order (thinking → text → tool → text …).
                ForEach(Array(message.segments.enumerated()), id: \.offset) { idx, seg in
                    segmentView(seg, isLast: idx == message.segments.count - 1)
                }
                // Keep a spinner visible the whole time the turn is working.
                if message.isStreaming {
                    ProgressView().scaleEffect(0.6)
                }
            } else if message.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("…").foregroundStyle(.secondary)
                }
            } else {
                // Fallback for older messages with no ordered segments.
                if !message.thinking.isEmpty { ThinkingView(text: message.thinking) }
                ForEach(message.tools, id: \.self) { toolChip($0) }
                if !message.text.isEmpty {
                    RichMessageText(text: message.text, streaming: false)
                        .foregroundStyle(message.isError ? .red : .primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func segmentView(_ seg: ChatMessage.Segment, isLast: Bool) -> some View {
        switch seg {
        case .thinking(let t):
            if !t.isEmpty { ThinkingView(text: t) }
        case .tool(let call):
            if call.canShowDetail {
                Button { onTapTool(call) } label: { toolChip(call.label) }
                    .buttonStyle(.plain)
            } else {
                toolChip(call.label)
            }
        case .text(let t):
            if !t.isEmpty {
                RichMessageText(text: t, streaming: isLast && message.isStreaming)
                    .foregroundStyle(message.isError ? .red : .primary)
            }
        }
    }

    /// Activity row: per-tool icon + bold action + the file/target it touched.
    private func toolChip(_ text: String) -> some View {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let name = parts.first.map(String.init) ?? text
        let detail = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return HStack(spacing: 7) {
            Image(systemName: toolIcon(name))
                .font(.caption2).foregroundStyle(.tint).frame(width: 15)
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(.primary)
            if !detail.isEmpty {
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline, lineWidth: 0.5))
    }

    private func toolIcon(_ name: String) -> String {
        switch name {
        case "Read": return "doc.text"
        case "Write": return "doc.badge.plus"
        case "Edit", "NotebookEdit": return "pencil"
        case "Bash": return "terminal"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task": return "sparkles"
        case "TodoWrite": return "checklist"
        case ToolCall.workflowChipName: return "arrow.triangle.branch"
        default: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Plan approval sheet

/// The plan Claude presented via ExitPlanMode, with the choices a phone can actually
/// act on: implement it now (auto-accepting edits — the phone can't answer per-edit
/// prompts) or keep planning with feedback.
/// `internal` (not `private`) only so a snapshot test can render it; unused
/// elsewhere and behaviourally unchanged.
struct PlanApprovalSheet: View {
    let plan: String
    let onProceed: () -> Void
    let onRefine: (String) -> Void
    let onDismiss: () -> Void

    @State private var refining = false
    @State private var feedback = ""
    @FocusState private var feedbackFocused: Bool

    private var feedbackEmpty: Bool {
        feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Plan ready for review", systemImage: "list.bullet.clipboard")
                        .font(.headline)
                    RichMessageText(text: plan, streaming: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if refining {
                        Divider()
                        Text("What should change?").font(.subheadline.weight(.semibold))
                        TextField("Feedback for Claude…", text: $feedback, axis: .vertical)
                            .lineLimit(2...6)
                            .textFieldStyle(.roundedBorder)
                            .focused($feedbackFocused)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Review plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later") { onDismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if refining {
                        Button { onRefine(feedback) } label: {
                            Text("Send feedback · keep planning").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(feedbackEmpty)
                        Button("Back") { withAnimation { refining = false } }
                            .font(.subheadline)
                    } else {
                        Button(action: onProceed) {
                            Label("Proceed · auto-accept edits", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Text("Claude Code's \u{201C}auto-accept edits\u{201D} — applies edits without asking.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button { withAnimation { refining = true } } label: {
                            Text("Keep planning…").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(16)
                .background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Permission approval sheet

/// Claude is BLOCKED mid-turn asking to run one tool (Edit/Write/Bash) under
/// "ask before edits". Show what it wants to do and Allow / Deny — the answer goes
/// back over the same connection and the turn continues in place. No swipe-to-dismiss:
/// Claude is stalled, so a decision is required.
///
/// `internal`, not `private`, ONLY so PervioTests can render it as a snapshot
/// with a synthetic `ToolCall`. Nothing else references it; the sheet's
/// behaviour is unchanged.
struct PermissionApprovalSheet: View {
    let call: ToolCall
    let onAllow: () -> Void
    let onDeny: (String?) -> Void

    @State private var denying = false
    @State private var reason = ""

    var body: some View {
        NavigationStack {
            approvalScroll
            .navigationTitle("Permission")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if denying {
                        Button(role: .destructive) { onDeny(reason) } label: {
                            Text("Deny").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Back") { withAnimation { denying = false } }.font(.subheadline)
                    } else {
                        Button(action: onAllow) {
                            Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        // What cannot be shown whole cannot be allowed.
                        .disabled(!canAllow)
                        .accessibilityIdentifier("permission-allow")
                        Button(role: .destructive) { withAnimation { denying = true } } label: {
                            Text("Deny…").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(16)
                .background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The sheet's scrolling body, factored out of `body` so a snapshot test can
    /// render it WITHOUT the enclosing `NavigationStack` — `ImageRenderer` can't
    /// rasterize a NavigationStack (it renders the "unavailable" placeholder).
    /// Behaviourally identical: `body` puts exactly this inside the stack.
    @ViewBuilder var approvalScroll: some View {
        ScrollView { approvalBody }
    }

    /// The inner VStack, split out of `approvalScroll` so a snapshot can render it
    /// directly. `ImageRenderer` rasterizes a `ScrollView` as EMPTY (its content
    /// is laid out lazily and never drawn), so the snapshot must pin THIS — the
    /// same content the real sheet scrolls — inside a fixed frame instead. `body`
    /// still wraps it in the ScrollView, so nothing the user sees changes.
    @ViewBuilder var approvalBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            if let fp = call.filePath {
                Text(fp).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if pervioVerb != nil { pervioDetail } else { detail }
            if denying {
                Divider()
                Text("Reason (optional — Claude sees this):")
                    .font(.subheadline.weight(.semibold))
                TextField("Why deny…", text: $reason, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder)
            }
        }
        .padding(16)
    }

    /// Show what will run: a Bash command, an Edit's replace→with, or a Write's content.
    @ViewBuilder private var detail: some View {
        if let cmd = call.command {
            codeBlock(cmd)
        } else if let new = call.newString {
            if let old = call.oldString, !old.isEmpty {
                Text("Replace").font(.caption).foregroundStyle(.secondary)
                codeBlock(old)
                Text("With").font(.caption).foregroundStyle(.secondary)
            }
            codeBlock(new)
        } else if let content = call.content {
            codeBlock(content)
        } else {
            Text(call.label).font(.callout)
        }
    }

    private func codeBlock(_ s: String) -> some View {
        Text(s)
            .font(.system(.footnote, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
    }

    private var icon: String {
        if let tool = pervioTool {
            switch tool {
            case "pervio_start":    return "play.circle"
            case "pervio_rerun":    return "arrow.clockwise"
            case "pervio_schedule": return "calendar.badge.clock"
            case "pervio_feedback": return "hand.thumbsup"
            default:                return "wrench.and.screwdriver"
            }
        }
        switch call.name {
        case "Edit", "NotebookEdit": return "pencil"
        case "Write":                return "doc.badge.plus"
        case "Bash":                 return "terminal"
        default:                     return "wrench.and.screwdriver"
        }
    }

    // MARK: Pervio calls in plain words (C8)

    /// "mcp__perviotools__pervio_start" → "pervio_start"; nil for non-pervio tools.
    private var pervioTool: String? {
        let prefix = "mcp__perviotools__"
        guard call.name.hasPrefix(prefix) else { return nil }
        return String(call.name.dropFirst(prefix.count))
    }

    /// The verb the sheet leads with. An unmapped (future) pervio tool falls back
    /// to the default raw-name rendering rather than guessing at a verb. Built
    /// per access so the Settings language switch reaches this safety-critical
    /// title live (like every other app-authored string).
    private static var verbs: [String: String] {
        [
            "pervio_start":    L.permStartWorkflow(),
            "pervio_rerun":    L.permRerunWorkflow(),
            "pervio_schedule": L.permEditSubscription(),
            "pervio_feedback": L.permRecordFeedback(),
        ]
    }
    private var pervioVerb: String? {
        // A template's own named tool (pervio_run_<slug>) starts a workflow too.
        pervioTool.flatMap { Self.verbs[$0] ?? ($0.hasPrefix("pervio_run_") ? L.permStartWorkflow() : nil) }
    }

    /// The workflow this call would run, read for the sheet: the Mac's resolved
    /// copy when it sent one, else the spec in the call's own arguments.
    private var digest: WorkflowSpecDigest.Digest? {
        (call.shownSpec ?? call.mcpInput?["spec_b64"]).map {
            WorkflowSpecDigest.read(b64: $0, own: call.mcpInput?["spec_b64"] != nil)
        }
    }
    /// Off when the workflow could not be shown in full (`internal` for the tests).
    var canAllow: Bool { digest?.readable ?? true }

    private var title: String { pervioVerb.map { "\($0)?" } ?? "Allow \(call.name)?" }

    /// start / rerun / schedule-create actually burn model quota — say so up front.
    private var spendsQuota: Bool {
        switch pervioTool {
        case "pervio_start", "pervio_rerun": return true
        case "pervio_schedule":              return call.mcpInput?["action"] == "create"
        case let t?:                         return t.hasPrefix("pervio_run_")
        default:                             return false
        }
    }

    /// The pervio call in plain words: one row per argument, plus the spend
    /// warning. Everything comes from the call's own input — no network requests,
    /// so the sheet pops instantly (Claude is stalled waiting on it).
    @ViewBuilder private var pervioDetail: some View {
        VStack(alignment: .leading, spacing: 7) {
            if pervioRows.isEmpty {
                Text(call.label).font(.callout)
            }
            // By POSITION, not by label: a step has several rows under one
            // label (what it may do, then each shell line it runs), and rows
            // identified by label all drew the first one's text — the sheet
            // showed "may change files" twice and the shell line not at all
            // (seen in a render, 2026-11-21).
            ForEach(Array(pervioRows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.0).font(.caption).foregroundStyle(.secondary)
                        .frame(minWidth: 52, alignment: .leading)
                    Text(row.1).font(.callout).textSelection(.enabled)
                }
            }
            if let problem = digest?.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium)).foregroundStyle(.red)
                    .padding(.top, 2)
                    .accessibilityIdentifier("permission-unreadable")
            }
            if spendsQuota {
                Label(L.permSpendsQuota(), systemImage: "bolt.fill")
                    .font(.footnote.weight(.medium)).foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Ordered summary rows from the call's raw input. Known keys get plain-words
    /// labels/values; anything left over still shows (clipped), so the user never
    /// approves arguments they couldn't see. spec_b64 is broken down into what
    /// the workflow would do (WorkflowSpecDigest), never dumped raw.
    private var pervioRows: [(String, String)] {
        var rest = call.mcpInput ?? [:]
        var rows: [(String, String)] = []
        func take(_ key: String, _ label: String, _ map: (String) -> String = { $0 }) {
            guard let v = rest.removeValue(forKey: key), !v.isEmpty else { return }
            rows.append((label, map(v)))
        }
        take("template", L.permLabelTemplate())
        take("dir", L.permLabelDir())
        take("runId", L.permLabelSourceRun())
        take("id", L.permLabelSubscription())
        take("action", L.permLabelAction()) { Self.actionNames[$0] ?? $0 }
        take("time", L.permLabelTime())
        take("days", L.permLabelDays()) { Self.weekdayList($0) }
        take("keepRuns", L.permLabelKeepRuns())
        take("enabled", L.permLabelStatus()) { $0 == "true" ? L.permStatusEnabled() : L.permStatusPaused() }
        take("arxiv_id", L.permLabelPaper())
        take("verdict", L.permLabelVerdict())
        take("note", L.permLabelNote())
        rest.removeValue(forKey: "spec_b64")
        // A named tool's own arguments (its parameters), before what they turn into.
        for key in rest.keys.sorted() {
            if let v = rest[key], !v.isEmpty { rows.append((key, String(v.prefix(200)))) }
        }
        // What the workflow would DO — its steps, the permission each holds,
        // where it runs and every shell line — not only the name the model, or
        // a template, gave it (security reviews #2).
        if let digest { rows.append(contentsOf: digest.rows) }
        return rows
    }

    private static var actionNames: [String: String] {
        [
            "update": L.permActionUpdate(), "pause": L.permActionPause(),
            "resume": L.permActionResume(), "delete": L.permActionDelete(),
            "create": L.permActionCreate(),
        ]
    }

    /// "1, 3, 5" (ISO weekdays) → "周一 周三 周五" (or "Mon Wed Fri" under
    /// English); anything unparseable stays raw.
    private static func weekdayList(_ s: String) -> String {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let mapped = parts.compactMap { Int($0).map { L.permWeekday($0) } }
        return (!mapped.isEmpty && mapped.count == parts.count)
            ? mapped.joined(separator: " ") : s
    }

}


/// A user turn the GROUP composed — a synthesis request, a review sheet, a
/// verdict nag, a critique hand-off: not the person's words. One centred line
/// naming what it was; the full text unfolds on a tap and folds back.
struct GroupInjectedRow: View {
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 6) {
            Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    // The gray dot: "a message in flight", the same mark the
                    // mode diagrams use (the legend, 2026-10-14).
                    Circle().fill(Color.secondary).frame(width: 6, height: 6)
                    Text(L.groupInjectedLine(GroupVia.label(message.via ?? ""))).font(.caption2)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Palette.surface, in: Capsule())
                .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            if expanded {
                Text(message.text).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity)
    }
}


// MARK: - The living run's background tasks (2026-10-20)

/// Elapsed time the way the card and the pill say it: 0:07, 3:12, 1:05:40.
enum BackgroundClock {
    static func elapsed(since start: Date, now: Date = Date()) -> String {
        format(max(0, now.timeIntervalSince(start)))
    }
    static func format(_ secs: TimeInterval) -> String {
        let s = Int(secs.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The line left in the conversation once everything the engine ran beside it
/// has ended: how it went, in one row, and the list behind a tap. It used to
/// be a card with two lines per task, growing under the reply — with sub-agents
/// counted as tasks it covered the conversation (2026-11-22). While anything
/// still runs the line above the composer says so instead, wherever the
/// transcript is scrolled.
struct BackgroundTaskCard: View {
    let done: [BackgroundTaskRecord]
    var open: () -> Void = {}

    var body: some View {
        let failed = done.filter { $0.status == "failed" }.count
        let stopped = done.filter { $0.status == "stopped" }.count
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: failed > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed > 0 ? Color.orange : Color.green)
                    .font(.caption)
                Text(L.bgEnded(completed: done.count - failed - stopped, failed: failed, stopped: stopped))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("background-card")
        .accessibilityHint(L.bgOpenList())
    }
}

/// The slim line above the composer while something runs beside the
/// conversation: how many sub-agents and background commands, for how long —
/// one line however many there are, and the whole list behind a tap.
struct BackgroundTaskBar: View {
    let tasks: [BackgroundTask]
    var open: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Button(action: open) {
                HStack(spacing: 8) {
                    BreathingDot(date: ctx.date)
                    Text(L.bgBar(BackgroundCount(tasks.map(\.kind)),
                                 BackgroundClock.elapsed(since: tasks.map(\.startedAt).min() ?? ctx.date, now: ctx.date)))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("background-bar")
            .accessibilityHint(L.bgOpenList())
        }
    }
}


/// The "still going" mark: an accent dot that breathes with the clock the card
/// already ticks on — drawn by SwiftUI, so it is there in a snapshot too.
struct BreathingDot: View {
    let date: Date
    var body: some View {
        // A symbol with the system's pulse: alive in the app, one still frame in
        // a snapshot (an opacity keyed to the clock's parity made the baseline flip).
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(Palette.accent)
            .symbolEffect(.pulse)
            .accessibilityHidden(true)
    }
}
