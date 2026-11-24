import SwiftUI
import UIKit

/// Hashable wrapper so navigationDestination(item:) can push a monitor for a
/// spec launched from the lightweight run sheet (same idiom as WorkflowsView's
/// RerunSeed); a fresh UUID per launch means running twice still navigates.
private struct MarketRunSeed: Hashable, Identifiable {
    let id = UUID()
    let spec: WorkflowSpec
    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Same idiom for a playbook's 在对话中用: the seed carries the finished load
/// text (fixed prefix + body), and a fresh UUID per tap means loading the same
/// playbook twice still navigates to a fresh chat.
struct PlaybookChatSeed: Hashable, Identifiable {
    let id = UUID()
    let loadText: String
    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

private extension WorkflowMarketItem {
    /// The schedule name a one-tap 订阅 creates, and the name 已订阅 looks up.
    /// It is `WorkflowSpec.scheduleName` — the SAME rule the editor's Save runs,
    /// by calling it rather than by resembling it — so a subscription made on
    /// either path is recognized on both.
    ///
    /// This used to fall back to the item `title` for a nameless spec, with a
    /// comment claiming it mirrored the editor "exactly" and three lines that did
    /// not. The title is market-side metadata: it never reaches the server and
    /// the editor has never seen it, so a nameless workflow scheduled in the
    /// editor was invisible here — 订阅 stayed lit, the pre-add re-list asked
    /// about the wrong name too, and the tap armed a SECOND daily schedule that
    /// ran and billed twice every morning. Two nameless rows now land on one
    /// name, which `subscriptionState` already handles honestly (名字冲突 +
    /// "give it a name"), instead of silently double-charging.
    var scheduleName: String { spec.scheduleName }
    /// The library filename an installed copy uses. Slugged from the stable
    /// catalog id, NOT spec.name: bundled names are mostly Chinese, which
    /// templateSlug collapses to "workflow" — every install would collide.
    var templateFile: String { SSHService.templateSlug(id) + ".json" }
}

// MARK: - Server-side market state

/// The market's live view of ONE server: its schedules (drives 已订阅) and its
/// template library (drives 已安装 + the My-template rows merged into the
/// shelves). One object is shared by the shelf list and every detail page
/// pushed from it, so subscribing on a detail page grays the shelf row's
/// button on the way back. All loads and mutations are one-shot connections —
/// the market holds no channel of its own (same idiom as the editor).
@MainActor
final class WorkflowMarketServerState: ObservableObject {
    let profile: ServerProfile?
    let secret: String

    @Published var templates: [ServerTemplate] = []
    @Published var schedules: [WorkflowSchedule] = []
    @Published var loading = false
    @Published var loadError: String?
    /// Item ids with a subscribe/install in flight — their buttons disable.
    @Published var busy: Set<String> = []
    /// Failure line for subscribe/install (actionFeedback's alert half).
    @Published var actionError: String?
    /// Truth fallbacks: when the post-action re-list fails, the action itself
    /// DID succeed — these keep 已订阅/已安装 honest until the next refresh.
    /// Subscriptions are remembered by ITEM ID (filename-namespaced), never by
    /// schedule name: a name can be shared by two different templates, and
    /// remembering "论文晨报 is subscribed" would hand one row's subscription to
    /// the other one for free.
    private var knownSubscribed: Set<String> = []
    private var knownInstalled: Set<String> = []
    /// Counts subscribe/install completions. A refresh reads the server at the
    /// moment it asks, not at the moment it returns — so it compares this to
    /// what it saw when it started, and only calls itself the whole truth if
    /// nothing changed the server behind its back (see `refresh()`).
    private var mutations = 0

    /// Every load and mutation opens its OWN one-shot connection, so the seam is
    /// the factory rather than a held client (see SSHServiceProtocol.swift). The
    /// default mints the real thing — call sites are unchanged.
    private let makeSSH: () -> any MarketSSHProtocol

    /// What the Mac has installed, from the connect-time probe (EngineStore).
    /// Nil = nothing known yet, which never blocks. Tests set it directly.
    @Published var engines: EngineProbe?

    init(profile: ServerProfile?, secret: String,
         makeSSH: @escaping () -> any MarketSSHProtocol = { SSHService() }) {
        self.profile = profile
        self.secret = secret
        self.makeSSH = makeSSH
        self.engines = EngineStore.shared.probe(for: profile)
    }

    /// The first engine this workflow needs that the Mac does not have — nil
    /// when every step's engine is installed, or when nothing is known.
    func missingEngine(_ item: WorkflowMarketItem) -> AgentBackend? {
        guard let engines else { return nil }
        return item.backends.first { !engines.has($0) }
    }

    /// One pull refreshes both halves (shelf classification, 已订阅, 已安装)
    /// over a single connection.
    func refresh() async {
        guard let profile else { return }
        loading = true
        defer { loading = false }
        let ssh = makeSSH()
        let mutationsWhenAsked = mutations
        do {
            try await ssh.connect(profile: profile, secret: secret)
            templates = try await ssh.listTemplates(profile: profile)
            schedules = try await ssh.listSchedules(profile: profile)
            // A successful pull IS the truth — the fallbacks only exist to
            // bridge a failed post-action re-list. Keeping them past this
            // point would pin 已订阅/已安装 on items deleted elsewhere.
            //
            // Unless the user tapped 安装/订阅 while this pull was still in
            // flight: then these rows were read BEFORE that tap and are simply
            // older than it. Dropping the fallbacks here published "not
            // installed / not subscribed" over something that IS on the server
            // now — and the next tap mints a second daily schedule that
            // double-runs every morning. The rows are still worth keeping (they
            // are the rest of the shelf), so only the fallbacks stay: they
            // expire on the first pull that overlaps nothing.
            if mutations == mutationsWhenAsked {
                knownSubscribed.removeAll()
                knownInstalled.removeAll()
            }
            loadError = nil
        } catch {
            loadError = pervioErrorText(error, "Couldn't load your templates.")
        }
        await ssh.disconnect()
    }

    /// What the market can honestly say about ONE row's subscription.
    ///
    /// `已订阅` used to be a single question — "does `schedule list` have this
    /// name" — and a schedule name is not an identity: `marketItem` namespaces
    /// row ids by FILENAME precisely because two templates may carry the same
    /// workflow name. With papers-a.json and papers-b.json both named 论文晨报,
    /// subscribing A answered "yes" for B too, so B's 订阅 button grayed out for
    /// good with nothing on the row to explain it.
    enum SubscriptionState: Equatable {
        /// Nothing on the server runs under this row's schedule name.
        case none
        /// This row IS that subscription — we made it here, or it is the only
        /// row that could have.
        case subscribed
        /// A daily schedule runs under this name, but `sharedBy` rows want that
        /// same name, so it cannot be attributed to this one. Subscribing would
        /// add a second, indistinguishable daily schedule (the pre-add check in
        /// `subscribe()` refuses it anyway, with a line that would be a lie).
        case nameTaken(sharedBy: Int)
        /// This row's spec carries no name, so its schedule name is the shared
        /// `Scheduled workflow` bucket — which any nameless workflow saved from
        /// the EDITOR also lands in. A match there proves nothing about this row,
        /// and the rival count above cannot see those schedules at all: it only
        /// counts market rows. Converging the two paths onto one name fixed the
        /// duplicate-schedule bug and created this one, so the bucket gets its
        /// own state rather than being allowed to masquerade as `.subscribed`.
        case unnamedBucket
    }

    /// Every row that can subscribe right now — the bundled 刊物 plus the user's
    /// own publishing templates. A bundled item the user has INSTALLED shows up
    /// on both lists; it is one workflow, not two claimants, so the bundled
    /// original drops out when its installed file is listed.
    private var subscribableItems: [WorkflowMarketItem] {
        let mine = templates.filter { $0.isPublication }
        let files = Set(mine.map(\.file))
        return WorkflowMarketItem.featured.filter { $0.isPublication
                                                    && !files.contains($0.templateFile) }
            + mine.compactMap(\.marketItem)
    }

    func subscriptionState(_ item: WorkflowMarketItem) -> SubscriptionState {
        // We armed this one on this screen: no inference needed, and this is
        // also the fallback that survives a failed post-action re-list.
        if knownSubscribed.contains(item.id) { return .subscribed }
        guard schedules.contains(where: { $0.name == item.scheduleName }) else { return .none }
        // A nameless spec has no name to be recognized BY. Its schedule name is
        // the shared bucket, so the match above may belong to some unrelated
        // workflow the user saved from the editor — and the rival scan below
        // would not see it, because it only walks market rows.
        if item.spec.name.trimmingCharacters(in: .whitespaces).isEmpty { return .unnamedBucket }
        let rivals = subscribableItems.filter {
            $0.scheduleName == item.scheduleName && $0.id != item.id
        }
        return rivals.isEmpty ? .subscribed : .nameTaken(sharedBy: rivals.count + 1)
    }

    /// True only when this row really is the subscription.
    func isSubscribed(_ item: WorkflowMarketItem) -> Bool {
        subscriptionState(item) == .subscribed
    }

    /// The line the row prints instead of a silent gray button: which name is
    /// taken, why the app can't tell whose it is, and the one thing that fixes
    /// it. Nil in every other state.
    func subscriptionNote(_ item: WorkflowMarketItem) -> String? {
        switch subscriptionState(item) {
        case .nameTaken(let n):
            return L.subscriptionNoteNameTaken(item.scheduleName, n)
        case .unnamedBucket:
            return L.subscriptionNoteUnnamed(item.scheduleName)
        case .none, .subscribed:
            // Said under a live row too: a subscription on a Mac that lost its
            // engine schedules failures, not reports.
            if let b = missingEngine(item) { return L.subscriptionNoteEngineMissing(b) }
            return nil
        }
    }

    /// What the button says when it is off and this row is NOT the subscription.
    /// Nil means the button is live. Two different dead ends deserve two
    /// different words: 名字冲突 sends you to rename one of several rivals,
    /// 先起个名字 sends you to name the only one there is.
    func blockedLabel(_ item: WorkflowMarketItem) -> String? {
        switch subscriptionState(item) {
        case .nameTaken:     return L.blockedNameConflict()
        case .unnamedBucket: return L.blockedNameFirst()
        case .none, .subscribed:
            if let b = missingEngine(item) { return L.blockedEngineMissing(b) }
            return nil
        }
    }

    func isInstalled(_ item: WorkflowMarketItem) -> Bool {
        knownInstalled.contains(item.templateFile)
            || templates.contains { $0.file == item.templateFile }
    }

    /// One-tap 订阅: scheduleAdd at the suggested time, then the SHARED C10
    /// first-issue policy — the same `ScheduleFirstIssue` call the editor's
    /// Save runs, so the two paths can never drift. No editor anywhere.
    /// Returns the toast line, or nil on failure (actionError is set).
    func subscribe(_ item: WorkflowMarketItem) async -> String? {
        guard let profile, !busy.contains(item.id) else { return nil }
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        // Same placeholder swap the editor's init makes: a template's "~" means
        // "the user's project dir on this server".
        var spec = item.spec
        if spec.dir.isEmpty || spec.dir == "~" { spec.dir = profile.projectDir }
        // The one number the row/detail copy promises (item.subscribeTime) IS
        // the one that gets armed — read from the same property, never a second
        // literal that can drift from what the button said.
        let time = item.subscribeTime
        if spec.name.isEmpty { spec.name = item.scheduleName }
        let ssh = makeSSH()
        do {
            try await ssh.connect(profile: profile, secret: secret)
            // Server-side truth check on the SAME connection before adding:
            // the server never dedupes schedule names, so a tap that lands
            // during the first refresh (or after a failed one) must not mint
            // a second daily schedule that silently double-runs and
            // double-spends. Old servers support `schedule list`, so this is
            // compatibility-free.
            if let fresh = try? await ssh.listSchedules(profile: profile) {
                schedules = fresh
                if fresh.contains(where: { $0.name == item.scheduleName }) {
                    await ssh.disconnect()
                    return L.toastAlreadySubscribed()
                }
            }
            _ = try await ScheduleCreate.add(ssh: ssh, profile: profile, spec: spec,
                                             time: time, keepRuns: 7)
            mutations += 1     // the server changed — any pull older than this line is stale
            let line = await ScheduleFirstIssue.settle(ssh: ssh, time: time)
            knownSubscribed.insert(item.id)
            schedules = (try? await ssh.listSchedules(profile: profile)) ?? schedules
            await ssh.disconnect()
            Haptics.tick()
            return line
        } catch {
            await ssh.disconnect()
            actionError = pervioErrorText(error, "Couldn't subscribe.")
            return nil
        }
    }

    /// Delete one of the person's own template files (the Mine shelf, 2026-10-20).
    /// Returns the error line, or nil when the row is gone.
    func deleteTemplate(_ t: ServerTemplate) async -> String? {
        guard let profile else { return nil }
        let ssh = makeSSH()
        do {
            try await ssh.connect(profile: profile, secret: secret)
            try await ssh.deleteTemplate(profile: profile, file: t.file)
            mutations += 1
            templates.removeAll { $0.file == t.file }
            await ssh.disconnect()
            Haptics.tick()
            return nil
        } catch {
            await ssh.disconnect()
            actionError = pervioErrorText(error, "Couldn't delete the template.")
            return actionError
        }
    }

    /// The explicit 来一期: fire one issue of an already-subscribed publication
    /// NOW. The only manual trigger since subscribing stopped auto-running
    /// (2026-09-01) — and it doubles as "reprint the issue whose slot got
    /// missed today". Returns the toast line, or nil on failure.
    func runIssueNow(_ item: WorkflowMarketItem) async -> String? {
        guard let profile, !busy.contains(item.id),
              // The button only renders on a subscribed row, so the schedule is
              // there; if a refresh raced it away, a quiet no-op beats firing
              // some other workflow's schedule.
              let sched = schedules.first(where: { $0.name == item.scheduleName })
        else { return nil }
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        let ssh = makeSSH()
        do {
            try await ssh.connect(profile: profile, secret: secret)
            _ = try await ssh.fireSchedule(profile: profile, id: sched.id)
            await ssh.disconnect()
            Haptics.tick()
            return L.issuePrinting()
        } catch {
            await ssh.disconnect()
            actionError = pervioErrorText(error, "Couldn't start the issue.")
            return nil
        }
    }

    /// Install a capability: the editor's exact save-template path — the
    /// wrapper shape {name, summary, spec} into ~/.pervio/templates — nothing
    /// new server-side. Returns the toast line, or nil on failure.
    func install(_ item: WorkflowMarketItem) async -> String? {
        guard let profile, !busy.contains(item.id) else { return nil }
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        struct Payload: Encodable {
            let name: String; let summary: String; let spec: WorkflowSpec
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(Payload(name: item.spec.name,
                                                 summary: item.summary, spec: item.spec)),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let ssh = makeSSH()
        do {
            try await ssh.connect(profile: profile, secret: secret)
            try await ssh.saveTemplate(profile: profile, filename: item.templateFile, json: json)
            mutations += 1     // the server changed — any pull older than this line is stale
            knownInstalled.insert(item.templateFile)
            templates = (try? await ssh.listTemplates(profile: profile)) ?? templates
            await ssh.disconnect()
            Haptics.tick()
            return L.toastInstalled()
        } catch {
            await ssh.disconnect()
            actionError = pervioErrorText(error, "Couldn't install the template.")
            return nil
        }
    }
}

// MARK: - Market (two shelves)

/// Browse ready-made workflows on TWO shelves — 刊物 (subscribe once, printed
/// daily onto the home screen) and 能力 (install to the server, or run in one
/// tap) — with the user's own server templates classified onto the same
/// shelves by the same rule. The editor is no longer the funnel: subscribing
/// and running happen right here; "自定义…" on a detail page still opens it
/// prefilled for people who want to change steps first. "Import JSON" accepts
/// a shared item/spec and routes it through the SAME detail page, so the
/// locally-computed warnings are unskippable for foreign content too.
struct WorkflowMarketView: View {
    let profile: ServerProfile?
    let secret: String

    @StateObject private var server: WorkflowMarketServerState
    @State private var showImport = false
    @State private var importedItem: WorkflowMarketItem?
    @State private var toast: String?
    /// The lightweight run sheet's target capability.
    @State private var runItem: WorkflowMarketItem?
    /// A run started from the sheet — pushes its monitor.
    @State private var runSeed: MarketRunSeed?
    /// A playbook's 在对话中用 — pushes a chat with the load text prefilled.
    @State private var playbookSeed: PlaybookChatSeed?
    /// One of my templates staged for deletion (two-step, like a schedule's).
    @State private var pendingTemplateDelete: ServerTemplate?

    init(profile: ServerProfile? = nil, secret: String = "") {
        self.profile = profile
        self.secret = secret
        _server = StateObject(wrappedValue:
            WorkflowMarketServerState(profile: profile, secret: secret))
    }

    /// Test-only seam (unused by the app): inject a pre-seeded server state so a
    /// snapshot can render a real market row in each of its states without any
    /// SSH. The `.task { refresh() }` in `body` never runs under ImageRenderer,
    /// so the seeded `schedules`/`busy` stand exactly as set.
    init(previewProfile: ServerProfile, secret: String, server: WorkflowMarketServerState) {
        self.profile = previewProfile
        self.secret = secret
        _server = StateObject(wrappedValue: server)
    }

    /// Test-only: ONE real market row (identity, pitch, facts, and the live
    /// action row) built by the exact same private `itemRow` the shelves use —
    /// so a snapshot pins what actually renders, not a reimplementation of it.
    @ViewBuilder
    func previewRow(_ item: WorkflowMarketItem) -> some View {
        itemRow(item)
            .padding(12)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    var body: some View {
        // With a profile the server state loads on appear and reloads on
        // pull-to-refresh (one gesture refreshes shelves, 已订阅 and 已安装
        // alike). Without one the shelves show the bundled catalog only and
        // actions live behind the detail page's per-server 自定义 links.
        if profile != nil {
            marketList
                .task { await server.refresh() }
                .refreshable { await server.refresh() }
        } else {
            marketList
        }
    }

    private var marketList: some View {
        List {
            Section {
                Text(L.marketIntro())
                    .font(.caption).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            if let profile {
                buildWithClaudeSection(profile)
            }
            if server.loadError != nil || (server.loading && server.templates.isEmpty) {
                serverStateSection
            }
            shelfSection(entries: publicationEntries,
                         title: L.shelfPublications(), icon: "sunrise.fill",
                         footer: publicationFooter)
            shelfSection(entries: capabilityEntries,
                         title: L.shelfCapabilities(), icon: "wand.and.stars",
                         footer: capabilityFooter)
        }
        .pervioBackground()
        .confirmationDialog(L.deleteTemplateConfirm(pendingTemplateDelete?.name ?? ""),
                            isPresented: Binding(get: { pendingTemplateDelete != nil },
                                                 set: { if !$0 { pendingTemplateDelete = nil } }),
                            titleVisibility: .visible) {
            Button(L.deleteTemplate(), role: .destructive) {
                if let t = pendingTemplateDelete {
                    Task { if let line = await server.deleteTemplate(t) { toast = line } }
                }
                pendingTemplateDelete = nil
            }
        }
        .pervioBar("Workflow Market")
        .toolbar {
            BarItem(.navigationBarTrailing) {
                BarGlyph(systemImage: "square.and.arrow.down.on.square", tint: Palette.accent, label: "Import JSON") { showImport = true }
            }
        }
        .sheet(isPresented: $showImport) {
            WorkflowImportSheet { item in
                importedItem = item
                showImport = false
            }
        }
        .sheet(item: $runItem) { item in
            if let profile {
                CapabilityRunSheet(item: item, profile: profile) { spec in
                    runItem = nil
                    runSeed = MarketRunSeed(spec: spec)
                }
            }
        }
        .navigationDestination(item: $importedItem) { item in
            WorkflowMarketDetailView(item: item, profile: profile, secret: secret,
                                     server: server)
        }
        .navigationDestination(item: $runSeed) { seed in
            if let profile {
                WorkflowMonitorView(profile: profile, secret: secret, spec: seed.spec)
            }
        }
        // 在对话中用 (a playbook row's button): open a chat with the load text
        // prefilled in the composer — never auto-sent, and pervioContext stays
        // OFF (a playbook is backend-/chip-agnostic pure text; the code below
        // used to contradict this comment and force the chip on).
        .navigationDestination(item: $playbookSeed) { seed in
            if let profile {
                // Chip OFF: a playbook is pure text. The chip used to be forced
                // on here for the background-dir grant that rode it — that grant
                // is gone, so forcing it would hand a text playbook the whole
                // Pervio tool surface for nothing.
                ChatView(profile: profile, secret: secret, initialInput: seed.loadText)
            }
        }
        .actionFeedback(toast: $toast, error: $server.actionError)
    }

    // MARK: shelves

    /// One row on a shelf: a bundled catalog item, or one of the user's server
    /// templates classified by the same rule.
    private enum ShelfEntry: Identifiable {
        case bundled(WorkflowMarketItem)
        case template(ServerTemplate)
        var id: String {
            switch self {
            case .bundled(let i): return "item-" + i.id
            case .template(let t): return "tpl-" + t.file
            }
        }
    }

    /// Shelf and badge read the SAME judgment (`isPublication`) on both kinds of
    /// row — a row can never sit on the 刊物 shelf without the 刊物 chip, or
    /// wear the chip from the capability shelf.
    private var publicationEntries: [ShelfEntry] {
        WorkflowMarketItem.featured.filter { $0.isPublication }.map(ShelfEntry.bundled)
            + server.templates.filter { $0.isPublication }.map(ShelfEntry.template)
    }

    /// Everything that isn't a publication — including broken template files,
    /// which stay VISIBLE here (grayed, with their parse error) so they can be
    /// fixed rather than silently ignored.
    private var capabilityEntries: [ShelfEntry] {
        WorkflowMarketItem.featured.filter { !$0.isPublication }.map(ShelfEntry.bundled)
            + server.templates.filter { !$0.isPublication }.map(ShelfEntry.template)
    }

    private var publicationFooter: String {
        profile == nil ? L.publicationFooterNoProfile() : L.publicationFooterProfiled()
    }

    private var capabilityFooter: String {
        if profile == nil { return L.capabilityFooterNoProfile() }
        return server.templates.isEmpty
            ? L.capabilityFooterEmpty()
            : L.capabilityFooterMixed()
    }

    private func shelfSection(entries: [ShelfEntry], title: String, icon: String,
                              footer: String) -> some View {
        Section {
            ForEach(entries) { entry in
                switch entry {
                case .bundled(let item): bundledRow(item)
                case .template(let t): templateEntryRow(t)
                }
            }
        } header: {
            Label(title, systemImage: icon)
        } footer: {
            Text(footer)
        }
    }

    @ViewBuilder private var serverStateSection: some View {
        Section {
            if let err = server.loadError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .listRowBackground(Palette.surface)
            } else {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                    .listRowBackground(Palette.surface)
            }
        }
    }

    // MARK: rows

    private func bundledRow(_ item: WorkflowMarketItem) -> some View {
        NavigationLink {
            WorkflowMarketDetailView(item: item, profile: profile, secret: secret,
                                     server: server)
        } label: {
            itemRow(item)
        }
        .listRowBackground(Palette.surface)
    }

    /// Three tiers: identity (icons + title), the pitch, the caption facts —
    /// then, on a profiled market, the one-tap action row (订阅, or 安装+运行).
    /// Items that demand a risk acknowledgement get NO row shortcut: their
    /// actions live on the detail page, behind the toggle.
    private func itemRow(_ item: WorkflowMarketItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(item.backends) { b in
                    Image(b.iconAsset).resizable().scaledToFit().frame(width: 18, height: 18)
                        .opacity(server.engines?.has(b) == false ? 0.3 : 1)
                }
                Text(item.title).font(.headline)
                // The row says out loud what shelf it's on — the same word the
                // editor's block and the Workflows list use for a home card.
                if item.isPublication { PublicationChip() }
            }
            Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Text("\(item.spec.steps.count) steps").foregroundStyle(.tint)
                if item.isReadOnly {
                    Label("read-only", systemImage: "lock.shield")
                        .foregroundStyle(.green)
                } else {
                    Label("writes files / shell", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                // A publication always shows the hour it would be printed at —
                // including the default it falls back to when the template
                // suggests none, which is exactly the hour 订阅 arms.
                if item.isPublication {
                    Label(item.subscribeTime, systemImage: "clock")
                        .foregroundStyle(.secondary)
                } else if let t = item.suggestedTime {
                    Label(t, systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)
            if profile != nil && !item.needsAcknowledgement {
                rowActions(item)
                    .padding(.top, 2)
                // A grayed button with no sentence under it is the bug this
                // says out loud: the name is taken by a same-named workflow.
                if let note = server.subscriptionNote(item) {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func rowActions(_ item: WorkflowMarketItem) -> some View {
        let busy = server.busy.contains(item.id)
        HStack(spacing: 8) {
            if item.isPublication {
                let state = server.subscriptionState(item)
                let subscribed = state == .subscribed
                // Name taken by a same-named workflow: the button must stay off
                // (subscribing mints a second daily schedule nobody can tell
                // apart) but must NOT claim this row is the one subscribed.
                let blocked = server.blockedLabel(item)
                let taken = blocked != nil
                Button(subscribed ? L.subscribed()
                       : blocked ?? (busy ? L.subscribing() : L.subscribe())) {
                    Task {
                        if let line = await server.subscribe(item) {
                            withAnimation(.easeOut(duration: 0.2)) { toast = line }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(subscribed || taken || busy)
                if subscribed {
                    Button(L.runIssueNow()) {
                        Task {
                            if let line = await server.runIssueNow(item) {
                                withAnimation(.easeOut(duration: 0.2)) { toast = line }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }
            } else {
                let installed = server.isInstalled(item)
                Button(installed ? L.installed() : (busy ? L.installing() : L.install())) {
                    Task {
                        if let line = await server.install(item) {
                            withAnimation(.easeOut(duration: 0.2)) { toast = line }
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(installed || busy)
                Button(L.run()) { runItem = item }
                    .buttonStyle(.borderedProminent)
            }
        }
        .font(.caption.weight(.semibold))
        .controlSize(.small)
        .buttonBorderShape(.capsule)
    }

    /// One of the user's server templates, mixed into the shelf. An ok workflow
    /// row opens the editor seeded with the spec (same as WorkflowsView's re-run
    /// seed) — tweak, run once, or save as a daily schedule. A playbook row
    /// opens the playbook detail (read the methodology, then 在对话中用) — its
    /// only verb is loading into a conversation, never the editor. A broken
    /// file stays visible with its parse error.
    @ViewBuilder private func templateEntryRow(_ t: ServerTemplate) -> some View {
        if let profile, t.isUsablePlaybook {
            NavigationLink {
                PlaybookDetailView(template: t, profile: profile, secret: secret)
            } label: {
                templateRow(t)
            }
            .listRowBackground(Palette.surface)
        } else if let profile, t.ok, !t.isPlaybook, let spec = t.spec {
            NavigationLink {
                WorkflowEditorView(profile: profile, secret: secret, seed: spec)
            } label: {
                templateRow(t)
            }
            .listRowBackground(Palette.surface)
            .swipeActions(allowsFullSwipe: false) { deleteTemplateButton(t) }
            .contextMenu { deleteTemplateButton(t) }
        } else {
            templateRow(t)
                .listRowBackground(Palette.surface)
                .swipeActions(allowsFullSwipe: false) { deleteTemplateButton(t) }
                .contextMenu { deleteTemplateButton(t) }
        }
    }

    /// A template of mine can go (2026-10-20): swipe or long-press, then a
    /// confirmation — the file on the Mac is the only copy.
    private func deleteTemplateButton(_ t: ServerTemplate) -> some View {
        Button(role: .destructive) { pendingTemplateDelete = t } label: {
            Label(L.deleteTemplate(), systemImage: "trash")
        }
    }

    private func templateRow(_ t: ServerTemplate) -> some View {
        // A playbook is judged on its body (it has no spec by design); a
        // workflow template on its spec — same "broken stays visible" rule.
        let broken = t.isPlaybook ? !t.isUsablePlaybook : !(t.ok && t.spec != nil)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(t.name.isEmpty ? t.file : t.name)
                    .font(.headline)
                    .foregroundStyle(broken ? .secondary : .primary)
                Text(L.chipMine())
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Palette.surface2, in: Capsule())
                    .foregroundStyle(.tint)
                if t.isPlaybook {
                    Text(L.chipPlaybook())
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Palette.surface2, in: Capsule())
                        .foregroundStyle(.tint)
                }
                if t.isPublication { PublicationChip() }
            }
            if broken {
                Text(t.error ?? "Unreadable template file.")
                    .font(.caption).foregroundStyle(.red).lineLimit(2)
            } else {
                if let s = t.summary, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if t.isPlaybook {
                        if let n = t.body?.count { Text(L.charCount(n)).foregroundStyle(.tint) }
                    } else if let n = t.steps {
                        Text("\(n) steps").foregroundStyle(.tint)
                    }
                    if let d = t.mtimeDate {
                        Text(d, format: .relative(presentation: .named))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                // The playbook's one-tap verb, right on the shelf (mirrors the
                // bundled rows' action row): load into a fresh conversation.
                if profile != nil, let text = t.playbookLoadText {
                    Button(L.useInChat()) { playbookSeed = PlaybookChatSeed(loadText: text) }
                        .buttonStyle(.borderedProminent)
                        .font(.caption.weight(.semibold))
                        .controlSize(.small)
                        .buttonBorderShape(.capsule)
                        .padding(.top, 2)
                }
                // …and the publication's: the user's OWN 热点日报 had no verb at
                // all on its row — it could be neither subscribed nor seen to be
                // subscribed already, which is the whole bug. Same button, same
                // state, same one-tap path as a bundled 刊物.
                if profile != nil, let item = t.marketItem, item.isPublication {
                    templateSubscribeButton(item)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 订阅 for one of the user's own publishing templates. Deliberately the
    /// same shape and the same state as `rowActions`' publication half — it
    /// waits while the first pull is in flight (subscribing blind risks a second
    /// daily schedule) and says the hour it will arm.
    @ViewBuilder private func templateSubscribeButton(_ item: WorkflowMarketItem) -> some View {
        let state = server.subscriptionState(item)
        let subscribed = state == .subscribed
        let note = server.subscriptionNote(item)
        let busy = server.busy.contains(item.id)
        let unjudged = server.loading || server.loadError != nil
        VStack(alignment: .leading, spacing: 2) {
            Button(subscribed ? L.subscribed()
                   : server.blockedLabel(item)
                     ?? (busy ? L.subscribing() : L.subscribeDaily(item.subscribeTime))) {
                Task {
                    if let line = await server.subscribe(item) {
                        withAnimation(.easeOut(duration: 0.2)) { toast = line }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(subscribed || busy || unjudged || note != nil)
            .font(.caption.weight(.semibold))
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            // Two templates with one workflow name: say which name, and what to
            // do — the row used to show a gray 已订阅 for a subscription that
            // belongs to the OTHER file.
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    // MARK: Build with Claude

    /// Entry to a chat prefilled with the builder prompt: Claude writes the
    /// template file server-side, so a NEW workflow never needs an app release —
    /// come back here and pull to refresh.
    private func buildWithClaudeSection(_ profile: ServerProfile) -> some View {
        Section {
            NavigationLink {
                ChatView(profile: profile, secret: secret,
                         pervioContext: true,   // wf-born: workflows context on by birth
                         initialAttachments: [.workflowBuilder()])
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "hammer.circle.fill")
                        .font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.buildWithClaudeTitle()).font(.headline)
                        Text(L.buildWithClaudeSubtitle())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(Palette.surface)
        }
    }
}

/// Hashable so navigationDestination(item:) can present an imported item.
extension WorkflowMarketItem: Hashable {
    static func == (l: WorkflowMarketItem, r: WorkflowMarketItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - Import sheet

/// Paste-a-JSON importer. Validation here is structural only; the security story
/// is that the RESULT goes through WorkflowMarketDetailView, where the warnings
/// engine runs on the actual spec — same rules as bundled items.
struct WorkflowImportSheet: View {
    let onImport: (WorkflowMarketItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste a workflow JSON someone shared with you (a market item or a bare spec). You'll see its steps and safety warnings before anything reaches the editor — and nothing ever runs automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                if let err = errorText {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
                Button {
                    text = UIPasteboard.general.string ?? text
                } label: {
                    Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                        .font(.callout)
                }
            }
            .padding(16)
            .pervioBackground()
            .pervioBar("Import workflow", back: false)
            .toolbar {
                BarItem(.cancellationAction) {
                    BarWord(text: L.cancel()) { dismiss() }
                }
                BarItem(.confirmationAction) {
                    BarWord(text: "Review", weight: .semibold) {
                        switch WorkflowMarketItem.decodeImport(text) {
                        case .success(let item):
                            errorText = nil
                            onImport(item)
                        case .failure(let why):
                            errorText = why.message
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Detail

/// Full preview of a market workflow: what each step does, the safety warnings,
/// and the actions — 订阅 for a publication, 安装/运行 for a capability, and the
/// demoted "自定义…" editor entry (prefilled as always) for people who want to
/// change steps or time first.
struct WorkflowMarketDetailView: View {
    let item: WorkflowMarketItem
    var profile: ServerProfile?
    var secret: String
    @ObservedObject var server: WorkflowMarketServerState
    @EnvironmentObject private var appStore: AppStore
    /// Items that can run arbitrary shell without asking (bypass / full-access)
    /// require an explicit "I've read every step" before ANY action unlocks.
    @State private var riskAcknowledged = false
    @State private var toast: String?
    @State private var showRunSheet = false
    @State private var runSeed: MarketRunSeed?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                safetyCard
                shapeSection
                presentationSection
                stepsSection
                actionSection
            }
            .padding(16)
        }
        .background(Palette.bg.ignoresSafeArea())
        .pervioBar(item.title)
        .toolbar {
            BarItem(.navigationBarTrailing) {
                BarGlyph(systemImage: "doc.on.doc", tint: Palette.accent, label: "Copy JSON") {
                    UIPasteboard.general.string = item.exportJSON()
                    Haptics.tick()
                }
            }
        }
        .sheet(isPresented: $showRunSheet) {
            if let p = profile {
                CapabilityRunSheet(item: item, profile: p) { spec in
                    showRunSheet = false
                    runSeed = MarketRunSeed(spec: spec)
                }
            }
        }
        .navigationDestination(item: $runSeed) { seed in
            if let p = profile {
                WorkflowMonitorView(profile: p, secret: secret, spec: seed.spec)
            }
        }
        .actionFeedback(toast: $toast, error: $server.actionError)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(item.backends) { b in
                    HStack(spacing: 4) {
                        Image(b.iconAsset).resizable().scaledToFit().frame(width: 16, height: 16)
                        Text(b.tag).font(.caption).foregroundStyle(.secondary)
                    }
                    .opacity(server.engines?.has(b) == false ? 0.3 : 1)
                }
                Spacer()
                Text("by \(item.author)").font(.caption2).foregroundStyle(.secondary)
            }
            Text(item.summary).font(.subheadline).foregroundStyle(.primary)
            if !item.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Palette.surface2, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: safety

    private var safetyCard: some View {
        let warnings = item.warnings
        return VStack(alignment: .leading, spacing: 6) {
            if warnings.isEmpty {
                Label("Read-only — explores and plans, doesn't change anything.",
                      systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Label("Before you run this", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                ForEach(warnings, id: \.self) { w in
                    Text("• \(w)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if item.needsAcknowledgement {
                Toggle(isOn: $riskAcknowledged) {
                    Text("I've read every step — this can run anything on my server.")
                        .font(.caption.weight(.semibold))
                }
                .tint(.orange)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background((warnings.isEmpty ? Color.green : Color.orange).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: flow diagram

    @ViewBuilder private var shapeSection: some View {
        if item.spec.steps.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Flow").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                WorkflowGraphView(
                    nodes: item.spec.steps.map {
                        WorkflowGraphNode(id: $0.id, backend: $0.backend, status: "",
                                          dependsOn: $0.dependsOn,
                                          inputs: workflowOutputRefs(in: $0.prompt))
                    },
                    scrolls: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .background(Palette.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: presentation contract

    /// One line of chips summarizing the spec's presentation contract — the
    /// publication (a step's `publish` or the legacy display.archiveDir; home
    /// card + back-issue reader), legacy folded sections, long-press actions.
    /// Absent entirely for specs that declare none, so plain items look as before.
    @ViewBuilder private var presentationSection: some View {
        let chips = presentationChips
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Presentation").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { chip in
                            Text(chip)
                                .font(.caption2)
                                .lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Palette.surface2, in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var presentationChips: [String] {
        var out: [String] = []
        // Publication chip, from either source: a step-level `publish` (the
        // current mechanism) wins; the legacy display.archiveDir still shows so
        // old templates keep advertising their home card. It names the REAL
        // directory — "默认" told the user nothing they could go and look at.
        if let n = item.spec.publicationNotice {
            out.append(L.chipPublish(n.archiveDir))
        }
        // Folding is authored in the report content now — this chip only
        // surfaces the legacy collapseSections hint.
        if let secs = item.spec.display?.collapseSections, !secs.isEmpty {
            out.append(L.chipFold(secs.joined(separator: L.listSeparator())))
        }
        if let n = item.spec.actions?.count, n > 0 {
            out.append(L.chipActions(n))
        }
        return out
    }

    // MARK: steps preview

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Steps").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(item.spec.steps.enumerated()), id: \.element.id) { idx, step in
                stepCard(idx + 1, step)
            }
        }
    }

    private func stepCard(_ n: Int, _ step: WorkflowStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if step.isCommand {
                    Image(systemName: "terminal.fill")
                        .font(.body).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                } else {
                    Image(step.backend.iconAsset).resizable().scaledToFit().frame(width: 18, height: 18)
                }
                Text("\(n). \(step.id)").font(.subheadline.weight(.semibold))
                Spacer()
                Text(modeLabel(step)).font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.surface2, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if !step.dependsOn.isEmpty {
                Text("needs: " + step.dependsOn.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.tint)
            }
            if let d = step.dir, !d.isEmpty {
                // Surface the working-directory override — for an imported workflow
                // this is where the step reads/writes, and it must not be a blind
                // spot (e.g. a step pointed at a state or secrets dir).
                Label("runs in: \(d)", systemImage: "folder")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let cmd = step.command, !cmd.isEmpty {
                Text("$ " + cmd)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(step.prompt)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let v = step.verify, !v.trimmingCharacters(in: .whitespaces).isEmpty {
                Label("verify: \(v)", systemImage: "checkmark.shield")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func modeLabel(_ step: WorkflowStep) -> String {
        if step.isCommand { return "shell" }
        if step.backend == .codex { return step.sandbox ?? "workspace-write" }
        return step.perm ?? "default"
    }

    // MARK: actions (订阅 / 安装+运行 / 自定义)

    @ViewBuilder private var actionSection: some View {
        let locked = item.needsAcknowledgement && !riskAcknowledged
        VStack(alignment: .leading, spacing: 8) {
            if let p = profile {
                if item.isPublication {
                    subscribeButton(locked: locked)
                    if !locked, server.isSubscribed(item) {
                        Button(L.runIssueNow()) {
                            Task {
                                if let line = await server.runIssueNow(item) {
                                    withAnimation(.easeOut(duration: 0.2)) { toast = line }
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(server.busy.contains(item.id))
                    }
                    Text(locked ? "Acknowledge the risk above to continue."
                                : server.subscriptionNote(item)
                                  ?? L.subscribeDetailNote(item.subscribeTime))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    installButton(locked: locked)
                    runButton(locked: locked)
                    Text(locked ? "Acknowledge the risk above to continue."
                                : L.installDetailNote())
                        .font(.caption2).foregroundStyle(.secondary)
                }
                customizeLink(for: p, secret: secret, label: L.customize(), locked: locked)
                Text(L.customizeNote())
                    .font(.caption2).foregroundStyle(.secondary)
            } else if appStore.profiles.isEmpty {
                Label("Add a server first to use this workflow.", systemImage: "server.rack")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                // Browsing without a server context: one-tap subscribe/install
                // needs a live profile (schedule + template state), so the
                // classic editor path stands in — pick a server, review, run.
                Text(L.customizeTo()).font(.caption).foregroundStyle(.secondary)
                ForEach(appStore.profiles) { p in
                    customizeLink(for: p, secret: appStore.secret(for: p) ?? "",
                                  label: p.name, system: "server.rack", locked: locked)
                }
                if locked {
                    Text("Acknowledge the risk above to continue.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }

    private func subscribeButton(locked: Bool) -> some View {
        let state = server.subscriptionState(item)
        let subscribed = state == .subscribed
        // A schedule under this name that belongs to some same-named workflow:
        // off, but never labelled 已订阅 (the sentence under the button says
        // which name is taken and how to get out of it).
        let taken = server.blockedLabel(item) != nil
        let busy = server.busy.contains(item.id)
        // 已订阅 can't be judged until the first schedule pull lands (or after
        // it failed) — subscribing blind risks a duplicate daily schedule, so
        // the button waits. subscribe() re-checks server-side as the backstop.
        let unjudged = server.loading || server.loadError != nil
        let dimmed = locked || subscribed || taken || unjudged
        return Button {
            Task {
                if let line = await server.subscribe(item) {
                    withAnimation(.easeOut(duration: 0.2)) { toast = line }
                }
            }
        } label: {
            Label(subscribed ? L.subscribed()
                  : taken ? L.blockedNameConflict() : (busy ? L.subscribing() : L.subscribe()),
                  systemImage: subscribed ? "checkmark.circle.fill"
                               : taken ? "exclamationmark.triangle.fill" : "sunrise.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Palette.accent.opacity(dimmed ? 0.06 : 0.18),
                            in: RoundedRectangle(cornerRadius: 12))
                .opacity(dimmed ? 0.4 : 1)
        }
        .disabled(locked || subscribed || busy || unjudged)
    }

    private func installButton(locked: Bool) -> some View {
        let installed = server.isInstalled(item)
        let busy = server.busy.contains(item.id)
        let dimmed = locked || installed
        return Button {
            Task {
                if let line = await server.install(item) {
                    withAnimation(.easeOut(duration: 0.2)) { toast = line }
                }
            }
        } label: {
            Label(installed ? L.installed() : (busy ? L.installing() : L.install()),
                  systemImage: installed ? "checkmark.circle.fill" : "tray.and.arrow.down")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Palette.accent.opacity(dimmed ? 0.06 : 0.18),
                            in: RoundedRectangle(cornerRadius: 12))
                .opacity(dimmed ? 0.4 : 1)
        }
        .disabled(locked || installed || busy)
    }

    private func runButton(locked: Bool) -> some View {
        Button { showRunSheet = true } label: {
            Label(L.run(), systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Palette.accent.opacity(locked ? 0.06 : 0.18),
                            in: RoundedRectangle(cornerRadius: 12))
                .opacity(locked ? 0.4 : 1)
        }
        .disabled(locked)
    }

    /// The editor, demoted to the secondary entrance — prefilled exactly as
    /// before (spec seed + suggested time) for changing steps before use.
    private func customizeLink(for p: ServerProfile, secret: String, label: String,
                               system: String = "slider.horizontal.3", locked: Bool) -> some View {
        NavigationLink {
            WorkflowEditorView(profile: p, secret: secret, seed: item.spec,
                               suggestedTime: item.suggestedTime)
        } label: {
            Label(label, systemImage: system)
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .opacity(locked ? 0.4 : 1)
        }
        .disabled(locked)
    }
}

// MARK: - Lightweight run sheet

/// The anti-editor: ONE decision — which directory — then run. The field
/// prefills the target server's project dir, and the menu offers every
/// profile's project dir (existing AppStore data) for quick switching; the run
/// itself always happens on `profile`. An empty dir refuses — the workflow
/// would otherwise land wherever the server's shell wakes up.
struct CapabilityRunSheet: View {
    let item: WorkflowMarketItem
    let profile: ServerProfile
    /// Called with the final spec (dir filled in); the presenter pushes the
    /// monitor — WorkflowMonitorView's .start mode does the startWorkflow.
    let onRun: (WorkflowSpec) -> Void
    @EnvironmentObject private var appStore: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var dir: String

    init(item: WorkflowMarketItem, profile: ServerProfile,
         onRun: @escaping (WorkflowSpec) -> Void) {
        self.item = item
        self.profile = profile
        self.onRun = onRun
        // Same prefill rule as the editor: a concrete template dir survives;
        // the "~" placeholder means "my project dir on this server".
        let sd = item.spec.dir
        _dir = State(initialValue: (sd.isEmpty || sd == "~") ? profile.projectDir : sd)
    }

    private var trimmedDir: String { dir.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Every distinct project dir across profiles, this server's first.
    private var dirChoices: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for p in [profile] + appStore.profiles {
            let d = p.projectDir.trimmingCharacters(in: .whitespacesAndNewlines)
            if !d.isEmpty && seen.insert(d).inserted { out.append(d) }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Working directory", text: $dir)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    if dirChoices.count > 1 {
                        Menu(L.changeProjectDir()) {
                            ForEach(dirChoices, id: \.self) { d in
                                Button(d) { dir = d }
                            }
                        }
                        .font(.callout)
                    }
                } header: {
                    Text("Run in directory")
                } footer: {
                    Text(trimmedDir.isEmpty
                         ? L.runSheetEmptyDirFooter()
                         : L.runSheetReadyFooter(profile.name))
                }
                .listRowBackground(Palette.surface)
            }
            .pervioBackground()
            .pervioBar(item.title, back: false)
            .toolbar {
                BarItem(.cancellationAction) {
                    BarWord(text: L.cancel()) { dismiss() }
                }
                BarItem(.confirmationAction) {
                    BarWord(text: L.runNow(), weight: .semibold) {
                        var spec = item.spec
                        spec.dir = trimmedDir
                        Haptics.tick()
                        onRun(spec)
                    }
                    .disabled(trimmedDir.isEmpty)
                }
            }
        }
    }
}
