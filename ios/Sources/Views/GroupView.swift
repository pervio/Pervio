import SwiftUI

/// 双开 — a project's "group": one PRIMARY conversation plus partners (another
/// model family, usually) that take the same message in parallel; the primary
/// synthesises each round (disagreements first), and the conclusion rides into
/// the partners' NEXT round. The Mac owns the round (pervio-group); this page
/// sends `say` and polls `tick`, so a round finishes whether or not the phone
/// stays awake, and ONE lock-screen push arrives when the synthesis lands.
///
/// Layout: a chip bar names every member (the primary filled in accent, the
/// partners outlined) and switches the pane; swipe does the same; "split"
/// shows two panes at once. ONE input strip at the bottom, with a target chip:
/// everyone (a round) or one member (a private word, no synthesis). Panes are
/// real conversations (live stream, approvals) without composers of their own.

// MARK: - Environment: the group tells its panes to re-sync

struct GroupRefreshKey: EnvironmentKey { static let defaultValue: Int = 0 }
extension EnvironmentValues {
    var groupRefresh: Int {
        get { self[GroupRefreshKey.self] }
        set { self[GroupRefreshKey.self] = newValue }
    }
}

// MARK: - Store

@MainActor
final class GroupStore: ObservableObject {
    @Published private(set) var group: ChatGroup
    @Published private(set) var errorText: String?
    @Published private(set) var sending = false
    /// Bumped whenever the Mac's `rev` moves (a round opened, an answer landed,
    /// the synthesis, a private word) so every pane reattaches / reloads.
    @Published private(set) var refreshToken = 0

    private let profile: ServerProfile
    private let secret: String
    private let ssh: any SSHServiceProtocol
    private var connected = false
    private var pollTask: Task<Void, Never>?
    private var lastRev = -1
    private let liveActivity = RunLiveActivityController()
    private var activityRound = 0

    /// `ssh` is injectable (FakeSSH in tests), like ChatStore.
    init(profile: ServerProfile, secret: String, group: ChatGroup,
         ssh: any SSHServiceProtocol = SSHService()) {
        self.profile = profile
        self.secret = secret
        self.group = group
        self.ssh = ssh
        lastRev = group.rev ?? 0
    }

    private func ensureConnected() async throws {
        guard !connected else { return }
        try await ssh.connect(profile: profile, secret: secret)
        connected = true
    }

    var isBusy: Bool { group.round.isBusy || sending || group.task?.isBusy == true || group.duoActive }

    /// Rounds per task in watch mode (the Mac's ROUNDS_CAP).
    static let roundsCap = 3

    /// One line for the strip and the list row, by task state.
    static func watchStatus(_ g: ChatGroup) -> String {
        guard let t = g.task else { return L.groupModeWatch() + " · " + L.groupWatchNoTask() }
        let head = L.groupTaskN(t.n) + " · "
        switch t.state {
        case "working": return head + L.groupWatchRounds(t.round, roundsCap) + " · " + L.groupWatchWorking()
        case "reviewing": return head + L.groupWatchRounds(t.round, roundsCap) + " · " + L.groupWatchReviewing()
        case "passed": return head + L.groupWatchPassed(t.rounds.count)
        case "waiting": return head + L.groupWatchWaiting()
        case "capped": return head + L.groupWatchCapped(roundsCap)
        case "failed": return head + L.groupWatchFailed()
        case "stopped": return head + L.groupWatchStopped(t.round)
        default: return head + t.state
        }
    }

    /// Duo: each window's state in one line — "主在答 · 伙伴空闲".
    static func duoStatus(_ g: ChatGroup) -> String {
        g.keyedMembers.enumerated().map { i, m in
            let who = L.groupPartnerN(i + 1)
            return g.isLive(m.key) ? L.groupDuoAnswering(who) : L.groupDuoIdle(who)
        }.joined(separator: " · ")
    }

    var statusLine: String {
        if group.isWatch { return Self.watchStatus(group) }
        if group.isDuo { return Self.duoStatus(group) }
        let r = group.round
        switch r.state {
        case "answering":
            return L.groupRound(r.n) + " · " + L.groupStateAnswering(r.answers.count, group.keyedMembers.count)
        case "synthesizing": return L.groupRound(r.n) + " · " + L.groupStateSynth()
        case "done": return L.groupRound(r.n) + " · " + L.groupStateDone()
        default: return L.groupStateIdle()
        }
    }

    /// Everyone (a round) or one member (a private word): `to` is a member key.
    /// `pervioContext` is the strip's lit fork key — every run of the message
    /// then carries the workflows pointer, as a chat turn would.
    func say(_ text: String, to: String = "all", pervioContext: Bool = false) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        if to == "all", group.round.isBusy { errorText = L.groupRoundBusy(); return }
        // Watch mode mid-loop: nothing goes to anyone (the Mac refuses too) — only
        // 停. The user's call (2026-10-13): stop and resend rather than interleave.
        if group.isWatch, group.task?.isBusy == true { errorText = L.groupLoopRunning(); return }
        // Duo: a window still answering takes no second word (one process per
        // conversation); the other window is free meanwhile.
        if group.isDuo, to == "all" ? group.duoActive : group.isLive(to) { errorText = L.groupMemberBusy(); return }
        sending = true
        defer { sending = false }
        do {
            try await ensureConnected()
            apply(try await ssh.groupSay(profile: profile, id: group.id, text: t, to: to, pervioContext: pervioContext))
            errorText = nil
            startPolling()
        } catch {
            // The real reason when there is one; a neutral line otherwise. (The
            // old fallback said "this round is still running" for ANY failure —
            // a dropped SSH read looked like a refusal.)
            errorText = pervioErrorText(error, L.groupSendFailed())
        }
    }

    /// Duo: hand window `by` the other window's LAST reply with a request to
    /// judge it — the one push in a mode that otherwise pulls. The person's
    /// own note (`extra`) rides along; empty is fine.
    func critique(by: String, of: String, extra: String = "") async {
        guard group.isDuo, !sending else { return }
        if group.isLive(by) { errorText = L.groupMemberBusy(); return }
        if !group.hasReply(of) { errorText = L.groupNothingToCritique(); return }
        sending = true
        defer { sending = false }
        do {
            try await ensureConnected()
            apply(try await ssh.groupCritique(profile: profile, id: group.id, by: by, of: of, extra: extra))
            errorText = nil
            startPolling()
        } catch {
            errorText = pervioErrorText(error, L.groupSendFailed())
        }
    }

    /// One member's knobs (model / effort / perm / sandbox; "" clears) — the
    /// Mac applies them from that member's next run on.
    func setMember(_ key: String, _ fields: [String: String]) async {
        do {
            try await ensureConnected()
            let data = try JSONSerialization.data(withJSONObject: fields)
            apply(try await ssh.groupSet(profile: profile, id: group.id, to: key, payload: data))
            errorText = nil
        } catch { errorText = pervioErrorText(error, "") }
    }

    func refresh() async {
        do {
            try await ensureConnected()
            apply(try await ssh.groupTick(profile: profile, id: group.id))
        } catch { errorText = pervioErrorText(error, "") }
    }

    /// Watch mode: the person stops the loop — the Mac kills the run it waits
    /// on. Duo: cuts the windows' live runs short.
    func stop() async {
        guard (group.isWatch && group.task?.isBusy == true) || group.duoActive else { return }
        do {
            try await ensureConnected()
            apply(try await ssh.groupStop(profile: profile, id: group.id))
            errorText = nil
        } catch { errorText = pervioErrorText(error, "") }
    }

    /// Poll `tick` while a round is in flight; the Mac advances the round on
    /// its own, polling only keeps the strip, the panes and the island current.
    func startPolling() {
        pollTask?.cancel()
        guard group.isActive else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.group.isActive {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if Task.isCancelled { break }
                await self.refresh()
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    func disband() async {
        stopPolling()
        liveActivity.end(finalStatus: "Ended")
        try? await ensureConnected()
        try? await ssh.groupDelete(profile: profile, id: group.id)
    }

    func disconnect() async { stopPolling(); connected = false; await ssh.disconnect() }

    /// Adopt the Mac's view; a moved `rev` means the panes must look again,
    /// and the island (ONE card for the whole round) follows the round state.
    private func apply(_ g: ChatGroup) {
        group = g
        errorText = nil                   // a fresh word from the Mac retires a stale complaint
        if (g.rev ?? 0) != lastRev {
            lastRev = g.rev ?? 0
            refreshToken += 1
        }
        let r = g.round
        let project = (g.dir as NSString).lastPathComponent
        if g.isWatch { return }           // the worker run carries its own island
        if r.isBusy {
            if activityRound != r.n {
                activityRound = r.n
                liveActivity.start(project: project, preview: String(r.text.prefix(60)),
                                   status: statusLine, runId: "group-\(g.id)-\(r.n)")
            } else {
                liveActivity.update(status: statusLine, detail: "")
            }
        } else if activityRound != 0 {
            activityRound = 0
            liveActivity.end(finalStatus: "Done")
        }
    }
}

// MARK: - The page

struct GroupView: View {
    let profile: ServerProfile
    let secret: String
    @StateObject private var store: GroupStore
    /// The strip's attachment pipeline — uploads, Mac files, 背景 transcripts
    /// and the workflows-context flag — is a ChatStore with no conversation of
    /// its own; what it collects is folded into the message pervio-group sends.
    @StateObject private var composer: ChatStore
    /// The connection handed in (a test's fake), kept so the panes' own
    /// conversations ride it too. nil in the app: each pane dials its own.
    private let paneSSH: (any SSHServiceProtocol)?
    @State private var text = ""
    @State private var split: Bool
    @State private var page: Int
    @State private var target = "all"
    @State private var confirmDisband = false
    @State private var showWf = false
    @State private var wfTemplates: [ServerTemplate] = []
    @State private var wfLoaded = false
    /// The member whose knobs are open in the settings sheet.
    @State private var configMember: MemberConfig?
    @State private var memberProfile = ServerProfile()
    @State private var memberProfileBefore = ServerProfile()
    /// `.sheet(item:)` clears the item BEFORE onDismiss runs; keep the key.
    @State private var lastConfigKey: String?
    /// The ended task whose banner the person dismissed (phone-local).
    @State private var dismissedTask = 0
    @State private var bannerExpanded = false
    /// Brainstorm: the round whose conclusion card the person dismissed, the
    /// card's expanded state, and the push into the primary's own conversation.
    @State private var dismissedSynthRound = 0
    @State private var synthExpanded = false
    @State private var openPrimary = false
    /// Phone landscape: the strip must stay short or the two panes get no room.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private struct MemberConfig: Identifiable { let key: String; var id: String { key } }

    /// `focusMember` opens the page on that member's pane (回到组 from a
    /// partner's conversation lands on the partner). `ssh` is injectable
    /// (FakeSSH in tests), like ChatStore.
    init(profile: ServerProfile, secret: String, group: ChatGroup, focusMember: String? = nil,
         ssh: (any SSHServiceProtocol)? = nil) {
        self.profile = profile
        self.secret = secret
        paneSSH = ssh
        // Two stores, two connections (a shared SSHService would be dropped by
        // whichever store disconnects first); a test's fake serves both.
        _store = StateObject(wrappedValue: GroupStore(profile: profile, secret: secret, group: group,
                                                      ssh: ssh ?? SSHService()))
        var p = profile
        p.backend = group.primary.agent
        _composer = StateObject(wrappedValue: ChatStore(profile: p, secret: secret, dir: group.dir,
                                                        ssh: ssh ?? SSHService()))
        _page = State(initialValue: group.keyedMembers.firstIndex { $0.key == focusMember } ?? 0)
        _target = State(initialValue: group.isWatch ? "p" : "all")   // watch mode has no "everyone"
        _split = State(initialValue: !group.isWatch)   // brainstorm and duo: both answers in view at once
    }

    private var members: [(key: String, member: ChatGroup.Member)] { store.group.keyedMembers }

    var body: some View {
        VStack(spacing: 0) {
            chipBar
            if split { splitPanes } else { pager }
            strip
        }
        .environment(\.groupRefresh, store.refreshToken)
        .background(Palette.bg.ignoresSafeArea())
        .pervioBar(L.groupTitle())
        .toolbar {
            BarItem(.navigationBarTrailing) {
                Menu {
                    Button { split.toggle() } label: {
                        Label(split ? L.groupPager() : L.groupSplit(),
                              systemImage: split ? "rectangle.portrait" : "rectangle.split.1x2")
                    }
                    Divider()
                    ForEach(Array(members.enumerated()), id: \.offset) { _, m in
                        Button { openConfig(m.key) } label: {
                            Label(L.groupMemberSettings(roleName(m.key) + " " + m.member.backend),
                                  systemImage: "slider.horizontal.3")
                        }
                    }
                    Divider()
                    Button(role: .destructive) { confirmDisband = true } label: {
                        Label(L.groupClose(), systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.body.weight(.medium))
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .alert(L.groupClose(), isPresented: $confirmDisband) {
            Button(L.groupClose(), role: .destructive) { Task { await store.disband(); dismiss() } }
            Button(L.cancel(), role: .cancel) {}
        } message: { Text(L.groupCloseConfirm()) }
        .sheet(item: $configMember, onDismiss: commitConfig) { _ in
            ChatConfigView(profile: $memberProfile, backendLocked: true, memberMode: true)
        }
        // 交给主去做: the primary's own conversation with its own permissions —
        // the one writer, once the brainstorm (everyone read-only) has concluded.
        .navigationDestination(isPresented: $openPrimary) {
            ChatView(profile: primaryProfile, secret: secret, dir: store.group.dir,
                     resumeSessionId: store.group.primary.session, pillEnabled: false)
        }
        .task {
            await store.refresh()
            store.startPolling()
            await composer.connect()        // so an attachment can upload right away
        }
        .onDisappear { Task { await store.disconnect(); await composer.disconnect() } }
    }

    /// 双窗 has no primary: its windows are 伙伴 1 and 伙伴 2 (the user, 2026-10-14).
    private func roleName(_ key: String) -> String {
        if store.group.isDuo, let i = members.firstIndex(where: { $0.key == key }) { return L.groupPartnerN(i + 1) }
        return key == "p" ? L.groupPrimary() : (store.group.isWatch ? L.groupWatcher() : L.groupPartner())
    }

    private var primaryProfile: ServerProfile {
        var p = profile
        p.backend = store.group.primary.agent
        return p
    }

    // MARK: members

    /// Who is in the group and which pane you are looking at. The chip you are
    /// ON is filled (the primary in accent, a partner in the text colour); the
    /// others are outlines — role by colour, position by fill, so a swipe
    /// visibly moves the highlight. Tapping the chip you are already on opens
    /// that member's settings (the small sliders glyph says so).
    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(members.enumerated()), id: \.offset) { i, m in
                    memberChip(m.key, m.member, selected: page == i) {
                        if page == i { openConfig(m.key) } else { withAnimation(.snappy(duration: 0.2)) { page = i } }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Palette.surface)
    }

    private func memberChip(_ key: String, _ m: ChatGroup.Member, selected: Bool, action: @escaping () -> Void) -> some View {
        let primary = key == "p"
        let role: Color = primary ? Palette.accent : Color.primary
        let fill: Color = selected ? role : Color.clear
        let ink: Color = selected ? (primary ? Color.white : Palette.bg) : (primary ? Palette.accent : Color.secondary)
        return Button(action: action) {
            HStack(spacing: 6) {
                Image(m.agent.iconAsset).resizable().frame(width: 14, height: 14)
                    .opacity(selected ? 1 : 0.7)
                Text(roleName(key)).font(.caption.weight(.semibold))
                Text(m.backend).font(.caption)
                if store.group.round.state == "answering" {
                    Image(systemName: store.group.round.answers[key] != nil ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.caption2)
                } else if store.group.isLive(key) {
                    ProgressView().controlSize(.mini)
                } else if selected {
                    Image(systemName: "slider.horizontal.3").font(.caption2).opacity(0.8)
                }
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(fill, in: Capsule())
            .overlay(Capsule().stroke(selected ? role : (primary ? Palette.accent.opacity(0.6) : Palette.hairline),
                                      lineWidth: selected ? 0 : 1))
        }
        .buttonStyle(.plain)
    }

    private var pager: some View {
        TabView(selection: $page) {
            ForEach(Array(members.enumerated()), id: \.offset) { i, m in
                pane(m.key, m.member).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// Split: both answers at once — the primary and the selected partner (or
    /// the first) stacked in portrait, side by side when the page is wider
    /// than tall (landscape, iPad).
    private var splitPanes: some View {
        let partnerIndex = page == 0 ? min(1, members.count - 1) : page
        return GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            let layout = wide ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
            layout {
                pane(members[0].key, members[0].member).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                if members.count > 1 {
                    pane(members[partnerIndex].key, members[partnerIndex].member)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                }
            }
        }
    }

    /// One member, live: a real ChatView (stream, approvals) with no composer of
    /// its own, under a hairline header naming it. Re-created when the member's
    /// conversation comes into being (its session id arrives with the first run).
    private func pane(_ key: String, _ m: ChatGroup.Member) -> some View {
        var p = profile
        p.backend = m.agent
        return VStack(spacing: 0) {
            if split {
                HStack(spacing: 6) {
                    Circle().fill(key == "p" ? Palette.accent : Color.secondary).frame(width: 6, height: 6)
                    Text(roleName(key) + " · " + m.backend)
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    if store.group.isLive(key) {
                        ProgressView().controlSize(.mini)
                        Text(L.groupDuoAnsweringWord()).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
            if m.session.isEmpty {
                // No conversation yet. A NEW partner gets its session id when
                // its first run finishes, so mid-round this pane is honest
                // about what is happening: answering, not waiting for you.
                let answering = (store.group.round.isBusy && store.group.round.runs[key] != nil)
                    || (key != "p" && store.group.task?.state == "reviewing")
                    || (key == "p" && store.group.task?.state == "working")
                    || store.group.isLive(key)
                VStack(spacing: 8) {
                    Spacer()
                    if answering {
                        ProgressView().controlSize(.large)
                        Text(L.groupPaneAnswering()).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(.tertiary)
                        Text(L.groupStateIdle()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ChatView(profile: p, secret: secret, dir: store.group.dir,
                         resumeSessionId: m.session, pillEnabled: false, embedded: true,
                         store: paneSSH.map { ChatStore(profile: p, secret: secret, dir: store.group.dir,
                                                        resumeSessionId: m.session, ssh: $0) })
                    .id(m.session)
            }
        }
    }

    // MARK: member settings

    /// The member's knobs as a ServerProfile, so the chat's own settings sheet
    /// edits them; what changed goes back to the Mac as that member's fields.
    private func openConfig(_ key: String) {
        guard let m = members.first(where: { $0.key == key })?.member else { return }
        var p = profile
        p.backend = m.agent
        if m.agent == .codex {
            p.codexModel = m.model ?? ""
            p.codexEffort = m.effort ?? ""
            p.codexSandbox = m.sandbox ?? "workspace-write"
        } else {
            p.model = m.model ?? ""
            p.effort = m.effort ?? ""
            p.permissionMode = m.perm ?? "auto"
        }
        memberProfile = p
        memberProfileBefore = p
        lastConfigKey = key
        configMember = MemberConfig(key: key)
    }

    private func commitConfig() {
        guard let key = lastConfigKey else { return }
        lastConfigKey = nil
        let p = memberProfile, before = memberProfileBefore
        var fields: [String: String] = [:]
        if p.backend == .codex {
            if p.codexModel != before.codexModel { fields["model"] = p.codexModel }
            if p.codexEffort != before.codexEffort { fields["effort"] = p.codexEffort }
            if p.codexSandbox != before.codexSandbox { fields["sandbox"] = p.codexSandbox }
        } else {
            if p.model != before.model { fields["model"] = p.model }
            if p.effort != before.effort { fields["effort"] = p.effort }
            if p.permissionMode != before.permissionMode { fields["perm"] = p.permissionMode }
        }
        guard !fields.isEmpty else { return }
        Task { await store.setMember(key, fields) }
    }

    // MARK: the one input

    private var targetLabel: String {
        if target == "all" { return store.group.isDuo ? L.groupToBoth() : L.groupToAll() }
        if let m = members.first(where: { $0.key == target }) { return roleName(m.key) }
        return L.groupToAll()
    }

    /// Watch mode mid-loop: the field is closed, only 停 works.
    private var loopBusy: Bool { store.group.isWatch && store.group.task?.isBusy == true }

    private var fieldPrompt: String {
        if loopBusy { return L.groupLoopRunning() }
        if store.group.isDuo {
            if target == "all" { return L.groupAskBoth() }
            if store.group.isLive(target) { return L.groupMemberBusy() }
            return L.groupToOne(targetLabel) + "…"
        }
        if target == "all" { return L.groupAskAll() }
        if store.group.isWatch && target == "p" {
            return store.group.task?.state == "waiting" ? L.groupAnswerIt() : L.groupAskWorker()
        }
        return L.groupToOne(targetLabel) + "…"
    }

    private var canSend: Bool {
        !(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && composer.attachments.isEmpty)
            && !composer.isUploading && !store.sending && !loopBusy
            && !(target == "all" && store.group.round.isBusy)
            && !(store.group.isDuo && (target == "all" ? store.group.duoActive : store.group.isLive(target)))
    }

    /// How a task ended, pinned above the rail until dismissed: the question
    /// (需要你), the summary (通过), the last feedback with 再来 3 轮 (3 轮未通过),
    /// or the error. Mid-loop nothing shows here; the rail says where it is.
    @ViewBuilder private var taskBanner: some View {
        if store.group.isWatch, let t = store.group.task, t.isEnded, t.n != dismissedTask, t.state != "stopped" {
            let waiting = t.state == "waiting"
            let passed = t.state == "passed"
            let tint: Color = waiting || t.state == "failed" ? Palette.accent : passed ? .green : .secondary
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: waiting ? "questionmark.circle.fill" : passed ? "checkmark.circle.fill"
                          : t.state == "failed" ? "exclamationmark.triangle.fill" : "minus.circle.fill")
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(waiting ? L.groupNeedsYou() : passed ? L.groupPassedTitle()
                             : t.state == "failed" ? L.groupWatchFailed() : L.groupCappedTitle(GroupStore.roundsCap))
                            .font(.caption.weight(.bold)).foregroundStyle(tint)
                        Text(waiting ? t.question : passed ? t.summary : t.state == "failed" ? t.error
                             : L.groupCappedLast() + ":" + (t.rounds.last?.text ?? ""))
                            .font(.caption).foregroundStyle(.primary)
                            .lineLimit(bannerExpanded ? nil : 4)
                            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { bannerExpanded.toggle() } }
                    }
                    Spacer(minLength: 4)
                    if !waiting {
                        Button { dismissedTask = t.n } label: { Image(systemName: "xmark").font(.caption2) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                if t.state == "capped" {
                    HStack(spacing: 8) {
                        Button(L.groupAgain(GroupStore.roundsCap)) {
                            dismissedTask = t.n
                            Task { await store.say(L.groupAgainText(), to: "p") }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.mini).tint(Palette.accent)
                        Button(L.groupDismiss()) { dismissedTask = t.n }
                            .buttonStyle(.bordered).controlSize(.mini)
                    }
                }
            }
            .padding(10)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.6), lineWidth: 1))
        }
    }

    // MARK: brainstorm: the conclusion, and the moment it is being written

    /// While the primary sums the round up: one line that visibly breathes, so
    /// "nothing is happening" never reads as "it is done".
    @ViewBuilder private var synthBar: some View {
        if store.group.isBrainstorm, store.group.round.state == "synthesizing" {
            SynthPulseBar(text: L.groupSynthRunning())
        }
    }

    /// The round's conclusion in its own box — what the brainstorm was for —
    /// with the way to act on it: the primary's own conversation.
    @ViewBuilder private var synthCard: some View {
        let r = store.group.round
        // Phone landscape (compact height): one line and the button in the
        // header, or the card alone would eat the two panes' room.
        let compact = verticalSizeClass == .compact
        if store.group.isBrainstorm, r.state == "done", !r.synth.isEmpty, r.n != dismissedSynthRound {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "text.badge.checkmark").foregroundStyle(Palette.accent)
                    Text(L.groupSynthTitle(r.n)).font(.caption.weight(.bold)).foregroundStyle(Palette.accent)
                    Spacer(minLength: 4)
                    if compact, !store.group.primary.session.isEmpty {
                        Button(L.groupHandToPrimary()) { openPrimary = true }
                            .buttonStyle(.borderedProminent).controlSize(.mini).tint(Palette.accent)
                    }
                    Button { withAnimation(.snappy(duration: 0.2)) { synthExpanded.toggle() } } label: {
                        Image(systemName: synthExpanded ? "chevron.up" : "chevron.down").font(.caption2)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    Button { dismissedSynthRound = r.n } label: { Image(systemName: "xmark").font(.caption2) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Text(r.synth).font(.caption).foregroundStyle(.primary)
                    .lineLimit(synthExpanded ? nil : (compact ? 1 : 6))
                    .textSelection(.enabled)
                    .onTapGesture { withAnimation(.snappy(duration: 0.2)) { synthExpanded.toggle() } }
                if !compact, !store.group.primary.session.isEmpty {
                    Button(L.groupHandToPrimary()) { openPrimary = true }
                        .buttonStyle(.borderedProminent).controlSize(.mini).tint(Palette.accent)
                }
            }
            .padding(10)
            .background(Palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.accent.opacity(0.5), lineWidth: 1))
        }
    }

    /// Two or more members can edit the same directory at once: say so, do
    /// not stop it (the person's call, 2026-10-14 — "不用封了这样自由一些").
    @ViewBuilder private var writersWarn: some View {
        if store.group.writers.count >= 2 {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.caption2)
                Text(L.groupWritableWarn()).font(.caption2)
            }
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: duo: the one push — a critique of the other window's last reply

    @ViewBuilder private var critiqueRow: some View {
        if store.group.isDuo, members.count > 1 {
            HStack(spacing: 8) {
                critiqueButton(by: "p", of: members[1].key)
                critiqueButton(by: members[1].key, of: "p")
                Spacer()
            }
        }
    }

    /// Enabled once the other side has replied and this side is free. Whatever
    /// is typed goes along as the person's note.
    private func critiqueButton(by: String, of: String) -> some View {
        let enabled = store.group.hasReply(of) && !store.group.isLive(by) && !store.sending
        return Button {
            let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            Haptics.tick()
            Task { await store.critique(by: by, of: of, extra: note) }
        } label: {
            Label(L.groupCritique(roleName(by), roleName(of)), systemImage: "text.bubble")
                .font(.caption2.weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .buttonStyle(.bordered).controlSize(.mini)
        .disabled(!enabled)
    }

    private var strip: some View {
        VStack(spacing: 6) {
            taskBanner
            synthCard
            synthBar
            writersWarn
            // The rail is the first thing to go when height is short (phone
            // landscape): the status line below says the same in words.
            if verticalSizeClass != .compact { RoundRail(group: store.group) }
            HStack(spacing: 8) {
                if store.isBusy { ProgressView().controlSize(.small) }
                Text(store.statusLine).font(.caption)
                    .foregroundStyle(store.group.task?.state == "waiting" ? Palette.accent : Color.secondary)
                    .lineLimit(1)
                Spacer()
                if store.group.isWatch || store.group.isDuo {
                    if store.group.task?.isBusy == true || store.group.duoActive {
                        // 停: the only thing the person can do mid-loop (watch);
                        // the way to cut a window short (duo).
                        Button(role: .destructive) { Task { await store.stop() } } label: {
                            Label(L.groupStop(), systemImage: "stop.fill").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered).controlSize(.mini).tint(.red)
                    }
                } else if store.group.autoSynth {
                    Text(L.groupAutoSynth()).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if let e = store.errorText {
                Text(e).font(.caption2).foregroundStyle(.orange)
            }
            ComposerAttachmentsBar(store: composer)
            if showWf {
                ComposerWfPanel(store: composer, templates: wfTemplates, loaded: wfLoaded,
                                onPick: { att in
                                    composer.attachments.removeAll { $0.inlinePrompt != nil }
                                    composer.attachments.append(att)
                                    withAnimation(.snappy(duration: 0.18)) { showWf = false }
                                })
            }
            critiqueRow
            HStack(alignment: .bottom, spacing: 6) {
                targetChip
                ComposerPlusMenu(store: composer, secret: secret, dir: store.group.dir, input: $text)
                ComposerWfKey(store: composer, open: $showWf) {
                    if !wfLoaded { loadWfTemplates() }
                }
                HStack(alignment: .bottom, spacing: 6) {
                    TextField(fieldPrompt, text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($inputFocused)
                        .disabled(loopBusy)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                            .foregroundStyle(canSend ? Palette.accent : Color.secondary)
                    }
                    .disabled(!canSend)
                }
                .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22)
                    .stroke(store.group.task?.state == "waiting" ? Palette.accent : Palette.hairline, lineWidth: 1))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Palette.bg)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    /// Everyone (a round) or one member (a private word). Short on purpose —
    /// the row also holds ＋, the fork key and the field.
    private var targetChip: some View {
        Menu {
            if !store.group.isWatch {
                Button { target = "all" } label: {
                    Label(store.group.isDuo ? L.groupToBoth() : L.groupToAll(), systemImage: "person.2")
                }
                Divider()
            }
            ForEach(Array(members.enumerated()), id: \.offset) { _, m in
                Button { target = m.key } label: {
                    Label(L.groupToOne(roleName(m.key) + " " + m.member.backend),
                          systemImage: m.key == "p" ? "star" : "person")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: target == "all" ? "person.2.fill" : "person.fill")
                Text(targetLabel).lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).frame(height: 34)
            .background(target == "all" ? Palette.accent : Palette.surface2, in: Capsule())
            .overlay(Capsule().stroke(target == "all" ? Palette.accent : Palette.hairline, lineWidth: 1))
            .foregroundStyle(target == "all" ? Color.white : Color.primary)
        }
    }

    /// The message as the members receive it: the text, prefixed with the
    /// attached files' paths (ChatStore's rule), carrying the wf-context flag.
    private func send() {
        let t = text
        text = ""
        let atts = composer.attachments
        composer.attachments = []
        let wire = ChatStore.wireText(t.trimmingCharacters(in: .whitespacesAndNewlines), attachments: atts)
        let to = target
        let ctx = composer.pervioContext
        Haptics.tick()
        Task { await store.say(wire, to: to, pervioContext: ctx) }
    }

    private func insertWfPrompt(_ prompt: String) {
        let tail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = prompt + tail
        withAnimation(.snappy(duration: 0.18)) { showWf = false }
        inputFocused = true
    }

    private func loadWfTemplates() {
        Task {
            if let all = await ComposerWfTemplates.load(profile: composer.profile, secret: secret) {
                wfTemplates = all
            }
            wfLoaded = true
        }
    }
}

// MARK: - Creating a group

struct GroupCreateSheet: View {
    let profile: ServerProfile
    let secret: String
    let dir: String
    let primarySession: String
    let onCreated: (ChatGroup) -> Void

    private enum PartnerChoice: Hashable { case newCodex, newClaude, newCursor, existing }
    @State private var partner: PartnerChoice = .newCodex
    @State private var existing: SessionSummary?
    @State private var sessions: [SessionSummary] = []
    @State private var mode = "parallel"
    @State private var autoSynth = true
    @State private var creating = false
    @State private var errorText: String?
    @StateObject private var service: SessionService
    @Environment(\.dismiss) private var dismiss

    init(profile: ServerProfile, secret: String, dir: String, primarySession: String,
         onCreated: @escaping (ChatGroup) -> Void) {
        self.profile = profile
        self.secret = secret
        self.dir = dir
        self.primarySession = primarySession
        self.onCreated = onCreated
        _partner = State(initialValue: profile.backend == .codex ? .newClaude : .newCodex)
        _service = StateObject(wrappedValue: SessionService(profile: profile, secret: secret))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("", selection: $mode) {
                        Text(L.groupModeParallel()).tag("parallel")
                        Text(L.groupModeWatch()).tag("watch")
                        Text(L.groupModeDuo()).tag("duo")
                    }
                    .pickerStyle(.segmented)
                    // The mode as a picture: who talks to whom, dots moving the way
                    // the words do. Worth more than the sentence under it.
                    GroupModeDiagram(mode: mode, primaryEngine: profile.backend.rawValue,
                                     partnerEngine: partnerEngineName)
                        .frame(height: 96)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                    HStack(spacing: 8) {
                        Image(profile.backend.iconAsset).resizable().frame(width: 18, height: 18)
                        Text((mode == "duo" ? L.groupPartnerN(1) : L.groupPrimary()) + " · " + profile.backend.rawValue)
                            .font(.callout.weight(.semibold))
                        Spacer()
                    }
                    if mode == "watch" {
                        Text(L.groupWatchHint()).font(.caption).foregroundStyle(.secondary)
                        if profile.backend == .claude && profile.permissionMode == "default" {
                            Text(L.groupPermWarn()).font(.caption).foregroundStyle(.orange)
                        }
                    } else if mode == "duo" {
                        Text(L.groupDuoHint()).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(L.groupBrainstormHint()).font(.caption).foregroundStyle(.secondary)
                        Toggle(L.groupAutoSynth(), isOn: $autoSynth)
                    }
                }
                Section(mode == "watch" ? L.groupWatcher() : mode == "duo" ? L.groupPartnerN(2) : L.groupPartner()) {
                    Picker(L.groupPartner(), selection: $partner) {
                        Text(L.groupPartnerNew("codex")).tag(PartnerChoice.newCodex)
                        Text(L.groupPartnerNew("claude")).tag(PartnerChoice.newClaude)
                        if EngineStore.shared.probe(for: profile)?.has(.cursor) == true {
                            Text(L.groupPartnerNew("cursor")).tag(PartnerChoice.newCursor)
                        }
                        Text(L.groupPartnerExisting()).tag(PartnerChoice.existing)
                    }
                    .pickerStyle(.inline).labelsHidden()
                    if partner == .existing {
                        ForEach(sessions.filter { $0.id != primarySession && $0.group == nil }) { s in
                            Button { existing = s } label: {
                                HStack {
                                    Image(s.agent.iconAsset).resizable().frame(width: 16, height: 16)
                                    Text(s.title).lineLimit(1)
                                    Spacer()
                                    if existing?.id == s.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if primarySession.isEmpty {
                    Text(L.groupPrimaryNeedsTurn()).font(.caption).foregroundStyle(.secondary)
                }
                if let errorText { Text(errorText).font(.caption).foregroundStyle(.orange) }
            }
            .pervioBar(L.groupOpen(), back: false)
            .toolbar {
                BarItem(.cancellationAction) { BarWord(text: L.cancel()) { dismiss() } }
                BarItem(.confirmationAction) {
                    BarWord(text: L.groupStart(), weight: .semibold) { Task { await create() } }
                        .disabled(creating || primarySession.isEmpty || (partner == .existing && existing == nil))
                }
            }
            .task { sessions = (try? await service.sessions(dir: dir)) ?? [] }
            .onDisappear { Task { await service.disconnect() } }
        }
    }

    /// The engine the diagram shows for the second window, from the picker.
    private var partnerEngineName: String {
        switch partner {
        case .newCodex: return "codex"
        case .newClaude: return "claude"
        case .newCursor: return "cursor"
        case .existing: return existing?.agent.rawValue ?? "codex"
        }
    }

    /// The payload pervio-group stores: the primary as this conversation is
    /// configured now; a NEW partner starts read-only (two writers on one tree
    /// collide — the rule from the design); an existing conversation as it is.
    static func payload(primarySession: String, profile: ServerProfile, autoSynth: Bool,
                        partnerBackend: AgentBackend, partnerSession: String,
                        mode: String = "parallel") -> [String: Any] {
        var primary: [String: Any] = ["session": primarySession, "backend": profile.backend.rawValue]
        if profile.backend == .codex {
            primary["sandbox"] = profile.codexSandbox
            if !profile.codexModel.isEmpty { primary["model"] = profile.codexModel }
        } else {
            // A watch task runs detached, and a detached run cannot ask: an
            // ask-tier primary starts as acceptEdits (the sheet says so).
            primary["perm"] = (mode == "watch" && profile.permissionMode == "default") ? "acceptEdits" : profile.permissionMode
            if !profile.model.isEmpty { primary["model"] = profile.model }
            if !profile.effort.isEmpty { primary["effort"] = profile.effort }
        }
        // 头脑风暴 is for thinking: everyone starts read-only, the primary too
        // (two writers on one tree collide); member settings can open one up.
        if mode == "parallel" {
            if profile.backend == .codex { primary["sandbox"] = "read-only" } else { primary["perm"] = "plan" }
        }
        var member: [String: Any] = ["session": partnerSession, "backend": partnerBackend.rawValue]
        if partnerSession.isEmpty {
            if partnerBackend == .codex { member["sandbox"] = "read-only" } else { member["perm"] = "plan" }
        }
        return ["mode": mode, "autoSynth": mode == "watch" ? false : autoSynth,
                "primary": primary, "members": [member],
                // The group's pushes go to this phone alone (2026-10-19).
                "device": PushTokenStore.currentDeviceId]
    }

    private func create() async {
        creating = true
        defer { creating = false }
        let backend: AgentBackend
        let session: String
        switch partner {
        case .newCodex: backend = .codex; session = ""
        case .newClaude: backend = .claude; session = ""
        case .newCursor: backend = .cursor; session = ""
        case .existing:
            guard let existing else { return }
            backend = existing.agent; session = existing.id
        }
        let payload = Self.payload(primarySession: primarySession, profile: profile, autoSynth: autoSynth,
                                   partnerBackend: backend, partnerSession: session, mode: mode)
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let g = try await service.groupCreate(dir: dir, payload: data)
            onCreated(g)
        } catch {
            errorText = pervioErrorText(error, "")
        }
    }
}

// MARK: - A group as one row in a conversation list

/// The row the lists show instead of the members: who is in it and where the
/// round stands. Tapping opens the group page.
struct GroupRowLabel: View {
    let group: ChatGroup

    private var subtitle: String {
        if group.isWatch {
            if group.task?.state == "waiting" { return L.groupNeedsYou() + " · " + (group.task?.question ?? "") }
            return GroupStore.watchStatus(group)
        }
        if group.isDuo { return GroupStore.duoStatus(group) }
        return group.round.text.isEmpty ? L.groupStateIdle() : L.groupRound(group.round.n) + " · " + group.round.text
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Palette.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(systemName: "person.2.fill").font(.caption).foregroundStyle(Palette.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text((group.isWatch ? L.groupModeWatch() : group.isDuo ? L.groupModeDuo() : L.groupModeParallel()) + " · "
                     + L.groupRowTitle(group.keyedMembers.map { $0.member.backend }.joined(separator: " × ")))
                    .lineLimit(1)
                Text(subtitle).font(.caption2)
                    .foregroundStyle(group.task?.state == "waiting" ? Palette.accent : Color.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if group.isActive { ProgressView().controlSize(.small) }
        }
    }
}

/// One line that visibly breathes while the primary writes the synthesis: a
/// spinner, the words, and a bar whose bright segment slides back and forth.
struct SynthPulseBar: View {
    let text: String
    @State private var on = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Palette.accent)
                Text(text).font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                Spacer()
            }
            GeometryReader { geo in
                Capsule().fill(Palette.accent.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Palette.accent)
                            .frame(width: geo.size.width * 0.3)
                            .offset(x: on ? geo.size.width * 0.7 : 0)
                    }
            }
            .frame(height: 3)
        }
        .padding(10)
        .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on = true } }
    }
}

// MARK: - The round rail

/// One cell per round. Watch mode: 3 cells (the cap), each with two segments —
/// the primary (accent) and the watcher (text colour) — and the verdict word
/// under them. Parallel mode: one cell for the current round — the primary,
/// each partner, then the synthesis. Filled = done, striped = running,
/// outline = not yet. The rail is what makes "where is it" visible at a glance.
struct RoundRail: View {
    let group: ChatGroup

    var body: some View {
        if group.isWatch {
            HStack(spacing: 4) {
                ForEach(1...GroupStore.roundsCap, id: \.self) { i in watchCell(i) }
            }
        } else if group.round.n > 0 {
            parallelCell
        }
    }

    private func watchCell(_ i: Int) -> some View {
        let t = group.task
        let r = t?.rounds.first { $0.round == i }
        let current = t?.isBusy == true && t?.round == i
        let pState: Seg.State = r == nil ? .pending : (t?.state == "working" && current) ? .running : .done
        let wState: Seg.State = r == nil || r?.w.isEmpty == true ? .pending
            : (t?.state == "reviewing" && current) ? .running : .done
        let verdict = r?.verdict ?? ""
        let word = current ? (t?.state == "working" ? L.groupWatchWorking() : L.groupWatchReviewing())
            : verdict == "通过" ? L.groupVerdictPass() : verdict == "继续" ? L.groupVerdictGo()
            : verdict == "需要你" ? L.groupVerdictAsk() : (t?.state == "failed" && r != nil && verdict.isEmpty ? L.groupWatchFailed() : " ")
        let wordColor: Color = verdict == "需要你" ? Palette.accent : verdict == "通过" ? .green : .secondary
        return VStack(alignment: .leading, spacing: 3) {
            Text(L.groupRound(i)).font(.system(size: 9.5)).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Seg(state: pState, color: Palette.accent)
                Seg(state: wState, color: Color.primary)
            }
            Text(word).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(wordColor).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(current ? Palette.accent : Color.clear, lineWidth: 1))
    }

    private var parallelCell: some View {
        let r = group.round
        return VStack(alignment: .leading, spacing: 3) {
            Text(L.groupRound(r.n)).font(.system(size: 9.5)).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(Array(group.keyedMembers.enumerated()), id: \.offset) { _, m in
                    let st: Seg.State = r.answers[m.key] != nil ? .done : (r.runs[m.key] ?? "").isEmpty ? .pending : .running
                    Seg(state: st, color: m.key == "p" ? Palette.accent : Color.primary)
                }
                if group.autoSynth {
                    let st: Seg.State = r.state == "done" && !r.synth.isEmpty ? .done : r.state == "synthesizing" ? .running : .pending
                    Seg(state: st, color: Palette.accent.opacity(0.6))
                }
            }
            Text(r.state == "answering" ? L.groupStateAnswering(r.answers.count, group.keyedMembers.count)
                 : r.state == "synthesizing" ? L.groupStateSynth() : r.state == "done" ? L.groupStateDone() : " ")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
    }

    /// One segment of a cell.
    struct Seg: View {
        enum State { case pending, running, done }
        let state: State
        let color: Color
        var body: some View {
            RoundedRectangle(cornerRadius: 3)
                .fill(state == .done ? color : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(state == .pending ? Palette.hairline : color, lineWidth: 1))
                .overlay {
                    if state == .running {
                        GeometryReader { geo in
                            HStack(spacing: 3) {
                                ForEach(0..<max(1, Int(geo.size.width / 6)), id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 3)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                .frame(height: 7)
        }
    }
}
