import SwiftUI

/// The entry page's "personal workbench" pieces — greeting header, the composer
/// (the page's primary action), today's publications (any workflow that declares
/// `display.archiveDir`), and the recent conversations. RootView stays thin: it
/// lays these out and keeps the servers footer; everything visual lives here.
///
/// Redesign (final) — conversation-led layout with a QUIET composer: an
/// underline-style ask box on top (hairline, no heavy border — the app is at
/// heart a line to Claude on your server), capsule chips for the three quick
/// entries, the publications as compact digest strips, then recent threads.
/// Server management moved behind a one-line footer (see ServersListView).
///
/// Every user-visible word here goes through `L`, so the whole page follows the
/// one app-language toggle — before the redesign this was English-only chrome.
///
/// An EMPTY `archives list` still renders nothing (no publications is a normal
/// state, not a problem) — but a load that THROWS now shows one quiet
/// unreachable line instead of silently hiding the block: a newsstand that
/// looks empty because the server is down used to be indistinguishable from
/// one that has nothing to say.

// MARK: - Greeting header

/// Block 1: the otter identity + time-of-day greeting + today's date.
/// Transparent row, no separator — it reads as page chrome, not list content.
struct HomeGreetingHeader: View {
    /// The clock the greeting reads. A parameter (not `Date()` inline) so the
    /// snapshot suite can pin a fixed hour and date; the app always gets the
    /// default, i.e. now on the phone's own calendar.
    var now: Date = Date()
    var calendar: Calendar = .current

    var body: some View {
        HStack(spacing: 14) {
            otterAvatar
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting).font(.title2.bold())
                Text(now, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.caption).foregroundStyle(.secondary)
                    .environment(\.locale, L.locale())
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// The mascot (2026-09-01, user's call): the greeting now wears the APP
    /// ICON itself — the front-facing otter — so the page and the home screen
    /// share one face. The art carries its own cream card, so no backing color;
    /// the rounded clip is what makes 44×44 read as a shape.
    private var otterAvatar: some View {
        Image("otter-face")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var greeting: String {
        switch calendar.component(.hour, from: now) {
        case 5..<11:  return L.greetingMorning()
        case 11..<18: return L.greetingAfternoon()
        case 18..<23: return L.greetingEvening()
        default:      return L.greetingLate()
        }
    }
}

// MARK: - Today's publications

/// Loads the home page's publications over a one-shot connection (the market's
/// refresh idiom): one `archives list`, then one 2 KB `head` per publication
/// for the card teaser. Owned by RootView so the `.task` hangs off the List
/// itself (always alive) rather than a row that may not render.
@MainActor
final class HomePublicationsModel: ObservableObject {
    struct Item: Identifiable {
        let publication: ArchivePublication
        let preview: String
        var id: String { publication.id }
        /// Recomputed on every render (not frozen at load) so cards that sit
        /// on screen across midnight don't keep yesterday's verdict.
        var state: CardState { HomePublicationsModel.cardState(publication) }
    }

    /// The card's three states (C7). Judged in the PHONE's calendar — "today"
    /// is a UI question, and a phone travelling across the server's day
    /// boundary self-corrects on the next render/refresh.
    enum CardState {
        /// The joined schedule fired today and that run failed — one tap
        /// reprints (fires the schedule again; doesn't consume the period).
        case missedToday
        /// The latest issue is dated today (and it didn't fail) — fresh off
        /// the press.
        case freshToday
        case normal
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var loading = false
    /// Non-nil after a REPRINT that failed — one quiet line under the cards.
    /// (A read that failed is the page's own line, MacProblemRow.) Cleared by
    /// the next good read.
    @Published private(set) var errorText: String?
    /// Publication ids with a reprint in flight (button shows a spinner).
    @Published private(set) var reprinting: Set<String> = []

    /// The newest read's answer is the page's (see `LoadTicket`).
    private var ticket = LoadTicket()

    /// One read. The outcome tells `PageRefresher` whether trying again can help.
    @discardableResult
    func load(profile: ServerProfile, secret: String) async -> PageRefresher.Outcome {
        let mine = ticket.take()
        loading = true
        defer { if ticket.isLatest(mine) { loading = false } }
        let ssh = SSHService()
        var outcome = PageRefresher.Outcome.reached
        do {
            try await ssh.connect(profile: profile, secret: secret)
            let pubs = try await ssh.listArchives(profile: profile)
            var built: [Item] = []
            for pub in pubs {
                var preview = ""
                if let latest = pub.files.first {
                    let head = (try? await ssh.readArchiveFile(
                        profile: profile, dir: pub.dir, file: latest.file,
                        limitBytes: 2048)) ?? ""
                    preview = Self.previewLine(head)
                }
                built.append(Item(publication: pub, preview: preview))
            }
            if ticket.isLatest(mine) {
                items = built
                errorText = nil
            }
        } catch {
            // Keep whatever loaded last time (stale beats blank) and say why —
            // an unreachable server no longer masquerades as "no publications".
            // (Said by the page's own line: MacProblemRow, from this outcome.)
            outcome = PageRefresher.Outcome.of(error, L.homeUnreachable())
        }
        await ssh.disconnect()
        return outcome
    }

    /// Fire the publication's schedule again — the missed-issue card's one-tap
    /// reprint. One-shot connection like load(); on success the reload sees the
    /// fresh run as lastStatus "running", which naturally clears the missed
    /// state (no local bookkeeping to invent).
    func reprint(profile: ServerProfile, secret: String, publication: ArchivePublication) async {
        guard let sid = publication.scheduleId, !sid.isEmpty,
              !reprinting.contains(publication.id) else { return }
        reprinting.insert(publication.id)
        defer { reprinting.remove(publication.id) }
        let ssh = SSHService()
        do {
            try await ssh.connect(profile: profile, secret: secret)
            _ = try await ssh.fireSchedule(profile: profile, id: sid)
            await ssh.disconnect()
            Haptics.tick()
        } catch {
            await ssh.disconnect()
            errorText = pervioErrorText(error, L.homeReprintFailed())
            return
        }
        await load(profile: profile, secret: secret)
    }

    /// C7's three-way verdict for one publication. Missed wins over fresh:
    /// a failed reprint attempt AFTER a good morning issue still deserves the
    /// warning (the schedule tried today and lost). Pure — nonisolated like
    /// SSHService.templateSlug so Item.state can call it from any context.
    nonisolated static func cardState(_ pub: ArchivePublication, now: Date = Date()) -> CardState {
        if let sid = pub.scheduleId, !sid.isEmpty,
           pub.scheduleEnabled == true,
           pub.lastStatus == "failed",
           let fired = pub.lastFiredDate,
           Calendar.current.isDate(fired, inSameDayAs: now) {
            return .missedToday
        }
        if let latest = pub.files.first {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            if issueTitle(latest.file) == f.string(from: now) { return .freshToday }
        }
        return .normal
    }

    /// The card teaser: the issue's first `>` quote line (minus its
    /// "今日一句:" label), else the first non-heading, non-empty line.
    static func previewLine(_ head: String) -> String {
        var fallback: String?
        for raw in head.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix(">") {
                var t = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                for label in ["今日一句:", "今日一句:"] where t.hasPrefix(label) {
                    t = String(t.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
                }
                if !t.isEmpty { return t }
            } else if fallback == nil, !line.hasPrefix("#"),
                      // A horizontal rule is layout, not content — an issue
                      // opening with --- must not become the card teaser.
                      !line.allSatisfy({ "-*_".contains($0) }) {
                fallback = line
            }
        }
        return fallback ?? ""
    }
}

/// Block 3: one digest strip per publication (skeleton while loading; an EMPTY
/// list still renders nothing, but a load error shows one unreachable line).
struct HomePublicationRows: View {
    let profile: ServerProfile
    let secret: String
    @ObservedObject var model: HomePublicationsModel
    /// True while the first-connect pave is landing scripts — errors in this
    /// window are the race, not the truth, so they dress as progress.
    var paving = false
    /// What the page's read says is wrong, if anything (PageRefresher).
    var problem: PageRefresher.Outcome? = nil
    var retrying = false
    /// Read the page again — the checkup or the settings closing.
    var reread: () -> Void = {}

    var body: some View {
        if model.loading && model.items.isEmpty && problem == nil {
            HomePublicationCardShell(
                name: L.publicationBadge(), badge: "0000-00-00",
                preview: L.publicationLoadingTeaser())
                .redacted(reason: .placeholder)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        if problem != nil, paving {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L.homePaving()).font(.caption).foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else if problem != nil {
            MacProblemRow(problem: problem, retrying: retrying, profile: profile, secret: secret, reread: reread)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        if let err = model.errorText {
            Label(err, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange).lineLimit(2)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        ForEach(model.items) { item in
            HomePublicationCard(profile: profile, secret: secret,
                                item: item, model: model)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }
}

/// One publication card; the whole card navigates to its reader (hidden-link
/// idiom so no chevron spoils the card edge). A missed-today card carries the
/// reprint button — its action fires here, where profile/secret/model live.
struct HomePublicationCard: View {
    let profile: ServerProfile
    let secret: String
    let item: HomePublicationsModel.Item
    @ObservedObject var model: HomePublicationsModel

    var body: some View {
        ZStack {
            NavigationLink {
                ArchiveReaderView(profile: profile, secret: secret,
                                  publication: item.publication)
            } label: { EmptyView() }
            .opacity(0)
            HomePublicationCardShell(
                name: item.publication.name.isEmpty ? L.publicationBadge() : item.publication.name,
                badge: item.publication.files.first.map { issueTitle($0.file) },
                preview: item.preview,
                state: item.state,
                lastError: item.publication.lastError ?? "",
                reprinting: model.reprinting.contains(item.id),
                onReprint: {
                    Task {
                        await model.reprint(profile: profile, secret: secret,
                                            publication: item.publication)
                    }
                })
        }
    }
}

/// The digest-strip visual, shared by the live strip and the loading skeleton.
/// Redesign: a COMPACT strip, not a hero card — surface fill only (the accent
/// gradient stroke is gone), the latest-issue date as plain quiet text instead
/// of a filled capsule, teaser trimmed to two lines. The three C7 states still
/// dress it: NEW capsule (fresh today), or a missed-issue row with the reprint
/// button. The morning issue stays first in the page order; it just no longer
/// shouts over the composer.
struct HomePublicationCardShell: View {
    let name: String
    var badge: String?
    var preview: String = ""
    var state: HomePublicationsModel.CardState = .normal
    var lastError: String = ""
    var reprinting: Bool = false
    var onReprint: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).font(.headline)
                if state == .freshToday {
                    Text("NEW")
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.accentDeep, in: Capsule())
                }
                Spacer()
                if let badge {
                    // The issue date, quiet: a plain monospaced-digit caption.
                    // As a filled accent capsule it out-shouted the composer.
                    Text(badge)
                        .font(.caption2).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if !preview.isEmpty {
                Text(preview)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if state == .missedToday {
                missedRow
            }
            Text(L.readCue()).font(.caption).foregroundStyle(Palette.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    /// "Today's issue didn't print" + the one-tap reprint. Bordered mini button
    /// (the Copy-button idiom) so it stays its own tap target inside a row that
    /// is otherwise one big hidden NavigationLink.
    private var missedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(L.missedIssue(), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Spacer(minLength: 8)
                Button { onReprint?() } label: {
                    if reprinting {
                        HStack(spacing: 5) {
                            ProgressView()
                            Text(L.reprinting()).font(.caption)
                        }
                    } else {
                        Label(L.reprint(), systemImage: "printer").font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(reprinting || onReprint == nil)
            }
            if !lastError.isEmpty {
                Text(lastError)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// "2026-07-30.md" → "2026-07-30" (shared with the reader's date bar).
func issueTitle(_ file: String) -> String {
    file.hasSuffix(".md") ? String(file.dropLast(3)) : file
}

// MARK: - Quick destinations

/// Where the composer / chips / footer go. Value routing so RootView can
/// register ONE destination at stack level — navigationDestination must not
/// live inside the lazy List. `compose` carries the home composer's draft (it
/// rides the same "new chat" route as `.chat`, with the first message
/// prefilled — ChatView never auto-sends an initialInput).
enum HomeQuickDest: Hashable {
    case chat, workflows, build
    /// New chat in a directory picked first (New chat long-press → 选目录).
    case chatIn(String)
    case compose(String)
    /// Revise an existing workflow template: the reviser prompt rides as a 🧩 chip.
    case reviseWorkflow(name: String, file: String)
    case servers
    /// Notification-tap landings (RootView pushes these when a push is tapped):
    /// a finished workflow's monitor, and a finished run's own conversation
    /// (dir + session resolved from the Mac's run list at tap time).
    case monitor(String)
    /// `origin` = the server entry (profile id) that started the run; the view
    /// reopens that entry when it still exists on this phone.
    case conversation(dir: String, session: String?, origin: String?)
}

/// Destination builder for the home pushes (RootView registers it).
struct HomeQuickDestView: View {
    let dest: HomeQuickDest
    let profile: ServerProfile
    let secret: String
    @EnvironmentObject private var appStore: AppStore

    /// The server entry a finished run should reopen under: the one that
    /// started it when it is still on this phone; else the one on the same Mac
    /// whose working directory contains the run's (the most specific); else the
    /// home entry. A `~/a` entry's run must come back to `~/a`, not to `~`
    /// (2026-10-15).
    private func landingProfile(dir: String, origin: String?) -> (ServerProfile, String) {
        if let o = origin, let p = appStore.profiles.first(where: { $0.id.uuidString == o }) {
            return (p, appStore.secret(for: p) ?? secret)
        }
        let sameMac = appStore.profiles.filter { $0.host == profile.host && $0.username == profile.username }
        if let p = sameMac.filter({ $0.scopeContains(dir) })
            .max(by: { $0.scopeDir.count < $1.scopeDir.count }) {
            return (p, appStore.secret(for: p) ?? secret)
        }
        return (profile, secret)
    }

    var body: some View {
        switch dest {
        case .chat:
            ChatView(profile: profile, secret: secret)
        case .chatIn(let d):
            ChatView(profile: profile, secret: secret, dir: d)
        case .compose(let draft):
            ChatView(profile: profile, secret: secret, initialInput: draft)
        case .workflows:
            WorkflowsView(profile: profile, secret: secret)
        case .build:
            ChatView(profile: profile, secret: secret,
                     pervioContext: true,   // wf-born: workflows context on by birth
                     initialAttachments: [.workflowBuilder()])
        case .reviseWorkflow(let name, let file):
            ChatView(profile: profile, secret: secret,
                     pervioContext: true,
                     initialAttachments: [.workflowRevise(name: name, file: file)])
        case .servers:
            ServersListView()
        case .monitor(let wfId):
            WorkflowMonitorView(profile: profile, secret: secret, wfId: wfId)
        case .conversation(let dir, let session, let origin):
            // Same shape as a RunListView row's tap: ChatView reloads the session's
            // history and reattaches if the run is somehow still going.
            let (target, targetSecret) = landingProfile(dir: dir, origin: origin)
            ChatView(profile: target, secret: targetSecret, dir: dir, resumeSessionId: session)
        }
    }
}

// MARK: - Composer

/// Block 2: the home composer — the page's primary action, styled QUIET: no
/// boxed field, no capsule bulk. A short underline-style row (plain TextField
/// over a hairline rule) with a restrained send arrow, plus the three quick
/// entries as the app's standard capsule chips. Sending routes the draft into
/// a fresh ChatView via `HomeQuickDest.compose` (prefilled, not auto-sent); an
/// empty send is just "new chat".
struct HomeComposerRow: View {
    let profile: ServerProfile
    let secret: String
    /// Buttons + an explicit path, NOT NavigationLinks: sibling links inside
    /// ONE List row collapse into a single link and the LAST one wins the whole
    /// row — measured 2026-08-07, when tapping "New chat" opened Build's seeded
    /// composer. Every chip must push its own destination, so the row drives
    /// RootView's NavigationPath directly.
    @Binding var path: NavigationPath
    /// Snapshot seam (additive, default-off): draw the field as its placeholder
    /// in static text instead of a live TextField. `ImageRenderer` cannot
    /// rasterize a UIKit-backed TextField — it emits a yellow "no entry" box,
    /// the same class of trap as a ScrollView rendering empty — so the entry-page
    /// snapshot would pin noise instead of this row. Everything else in the row
    /// (font, hairline, spacing, the send arrow) is the real thing either way,
    /// and the placeholder still comes from the same `L` call, so a string that
    /// fails to switch languages still turns the baseline red.
    var staticFieldForRender = false
    @State private var draft = ""
    @State private var showBuildPicker = false
    @State private var showDirPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if staticFieldForRender {
                    Text(L.homeComposerPlaceholder())
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(L.homeComposerPlaceholder(), text: $draft)
                        .font(.subheadline)
                        .submitLabel(.send)
                        .onSubmit(send)
                }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle")
                        .font(.title3)
                        .foregroundStyle(trimmed.isEmpty ? Color.secondary : Palette.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            HStack(spacing: 8) {
                chip(L.homeChipNewChat(), .chat)
                    // Long-press: choose the directory first, then the chat.
                    .contextMenu {
                        Button { showDirPicker = true } label: { Label(L.homeChipNewChatIn(), systemImage: "folder") }
                    }
                chip(L.homeChipWorkflows(), .workflows)
                // Build opens a picker first (2026-08-31): scratch OR an
                // existing template to revise — no more blind prompt dump.
                Button { showBuildPicker = true } label: {
                    HomeChipLabel(L.homeChipBuild())
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .sheet(isPresented: $showDirPicker) {
            DirectoryPickerSheet(profile: profile, secret: secret, startPath: profile.projectDir) { d in
                showDirPicker = false
                path.append(HomeQuickDest.chatIn(d))
            }
        }
        .sheet(isPresented: $showBuildPicker) {
            BuildPickerSheet(profile: profile, secret: secret) { dest in
                showBuildPicker = false
                path.append(dest)
            }
        }
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An empty send is not a no-op: it is the plain "new chat" the user was
    /// reaching for anyway, so the arrow never feels dead.
    private func send() {
        let text = trimmed
        draft = ""
        path.append(text.isEmpty ? HomeQuickDest.chat : HomeQuickDest.compose(text))
    }

    private func chip(_ label: String, _ dest: HomeQuickDest) -> some View {
        Button { path.append(dest) } label: {
            HomeChipLabel(label)
        }
        .buttonStyle(.plain)
    }
}

/// One capsule chip's visual, factored out so the snapshot suite can render the
/// chip row without a NavigationPath.
struct HomeChipLabel: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(.secondary)
            .background(Palette.surface2, in: Capsule())
    }
}

// MARK: - Build picker

/// The build chip's picker (2026-08-31): scratch, or one of the server's
/// existing workflow templates to revise. Selection only PREFILLS a chat —
/// the user reads and sends themselves, same safety posture as playbooks.
struct BuildPickerSheet: View {
    let profile: ServerProfile
    let secret: String
    let onPick: (HomeQuickDest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [ServerTemplate] = []
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onPick(.build)
                    } label: {
                        Label(L.buildPickScratch(), systemImage: "plus.circle")
                    }
                }
                Section {
                    if loading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(L.buildPickLoading()).foregroundStyle(.secondary)
                        }
                    } else if failed {
                        Text(L.buildPickError())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(templates) { t in
                        Button {
                            onPick(.reviseWorkflow(name: t.name.isEmpty ? t.file : t.name,
                                                                         file: t.file))
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.name.isEmpty ? t.file : t.name)
                                    .font(.subheadline.weight(.semibold))
                                if let sum = t.summary, !sum.isEmpty {
                                    Text(sum).font(.caption)
                                        .foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        .disabled(!t.ok)
                        .opacity(t.ok ? 1 : 0.4)
                    }
                } header: {
                    Text(L.buildPickExisting())
                }
            }
            .pervioBar(L.buildPickTitle(), back: false)
            .toolbar {
                BarItem(.topBarTrailing) { BarWord(text: L.done(), weight: .semibold) { dismiss() } }
            }
            .task {
                let ssh = SSHService()
                defer { Task { await ssh.disconnect() } }
                do {
                    try await ssh.connect(profile: profile, secret: secret)
                    let all = try await ssh.listTemplates(profile: profile)
                    templates = all.filter { $0.kind != "playbook" }
                    failed = false
                } catch {
                    failed = true
                }
                loading = false
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Recent conversations

/// Loads the home page's two blocks over a one-shot connection (`pervio-sessions
/// home`, 2026-10-17): the folders worked in most recently, each with its
/// newest conversations, and the default folder's own conversations — the
/// chats started from the home page without a project. Quiet like the
/// publications block: a load failure renders nothing (the publications row
/// already voices an unreachable server; two error lines for one outage would nag).
@MainActor
final class HomeRecentModel: ObservableObject {
    struct Item: Identifiable {
        let dir: String
        let session: SessionSummary
        var id: String { session.id }
    }
    /// A group (双开) is ONE row here; its member conversations hide behind it
    /// (they are filtered out of `items`), so leaving the group never leaves
    /// the user with the pieces instead of the whole.
    struct GroupItem: Identifiable {
        let dir: String
        let group: ChatGroup
        var id: String { group.id }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var groups: [GroupItem] = []
    /// The folders block: newest-active first, the default folder excluded.
    @Published private(set) var projects: [HomeProject] = []
    /// Conversations deleted from this page since its load (the folders'
    /// rows are the server's rows, so a deleted one is hidden, not rebuilt).
    @Published private(set) var removed: Set<String> = []
    /// The row whose delete is being confirmed (the question is asked on the
    /// home list itself, RootView, which always exists; these rows may not).
    @Published var pendingDelete: SessionSummary? = nil
    var pendingDir = ""

    func remove(sessionId: String) {
        removed.insert(sessionId)
        items.removeAll { $0.session.id == sessionId }
    }

    /// Confirmed: off the page at once, the Mac's record next (its own agent
    /// named, so a Codex thread is really deleted), the saved knobs with it.
    func delete(_ session: SessionSummary, dir: String, profile: ServerProfile, secret: String, appStore: AppStore) {
        remove(sessionId: session.id)
        appStore.removeParams(for: session.id, on: profile)
        Task {
            let svc = SessionService(profile: profile, secret: secret)
            _ = try? await svc.delete(dir: dir, session: session.id, backend: session.agent)
            await svc.disconnect()
        }
    }

    /// Snapshot seam (additive, default-off): a model pre-seeded with rows, so
    /// the recent block can be rendered without SSH. The app always uses the
    /// no-argument init and loads over the wire.
    init() {}
    init(previewItems: [Item]) { items = previewItems }

    /// The newest read's answer is the page's (see `LoadTicket`).
    private var ticket = LoadTicket()

    @discardableResult
    func load(profile: ServerProfile, secret: String, pins: PinStore? = nil) async -> PageRefresher.Outcome {
        let mine = ticket.take()
        let svc = SessionService(profile: profile, secret: secret)
        var outcome = PageRefresher.Outcome.reached
        do {
            let feed = try await svc.home()
            guard ticket.isLatest(mine) else { await svc.disconnect(); return .reached }
            // The default folder as the Mac spells it: the same key the
            // project's own history page uses, so a pin made in either shows
            // in both. Same pin sync as SessionsView.load.
            let dir = feed.dir.isEmpty ? profile.scopeDir : feed.dir
            if let pins {
                let plan = pins.flushPlan(profileId: profile.id, dir: dir)
                do {
                    if !plan.isEmpty { try await svc.replayPins(dir: dir, plan: plan) }
                    pins.markFlushed(profileId: profile.id, dir: dir)
                } catch {
                    NSLog("[Pervio] pin replay deferred: %@", String(describing: error))
                }
                pins.absorb(feed.recent, profileId: profile.id, dir: dir)
            }
            // The server hands back the newest rows plus every pinned one; the
            // view shows pins first and the newest besides (visibleRows).
            items = feed.recent.filter { $0.group == nil }
                .sorted { $0.modified > $1.modified }
                .map { Item(dir: dir, session: $0) }
            groups = ((try? await svc.groupList(dir: dir)) ?? [])
                .map { GroupItem(dir: dir, group: $0) }
                .sorted { $0.group.createdAt > $1.group.createdAt }
            projects = feed.projects
        } catch {
            outcome = PageRefresher.Outcome.of(error, L.homeUnreachable())
        }
        await svc.disconnect()
        return outcome
    }
}

/// Block 4: the folders worked in most recently — collapsed to name, count
/// and last activity; a tap opens one to its newest three conversations and a
/// "see all" row into its whole history, and the phone remembers which folders
/// are open per server (the person's ask, 2026-10-17: three chats under every
/// folder crowded the page). Then the default folder's own recent
/// conversations. Rows are bare (no card chrome) — agent icon, title, relative
/// time — matching the page's quiet frame. Resuming mirrors SessionsView: the
/// pushed ChatView gets the session's own agent as backend. Everything pushes
/// onto the home stack, so back always lands home.
struct HomeRecentRows: View {
    let profile: ServerProfile
    let secret: String
    @ObservedObject var model: HomeRecentModel
    /// Shared with a project's SessionsView: a pin made in either list shows in
    /// the other. Observed so a leading swipe re-sorts and re-marks these rows.
    @ObservedObject var pins: PinStore
    /// The folders open right now; nil until the first tap, when the phone's
    /// memory for this server answers instead.
    @State private var openFolders: Set<String>? = nil

    private var expanded: Set<String> { openFolders ?? HomeFolderMemory.expanded(for: profile.id) }

    private func toggle(_ path: String) {
        var set = expanded
        if set.contains(path) { set.remove(path) } else { set.insert(path) }
        openFolders = set
        HomeFolderMemory.set(set, for: profile.id)
    }

    var body: some View {
        if !model.projects.isEmpty {
            Section {
                ForEach(model.projects) { p in
                    let open = expanded.contains(p.path)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { toggle(p.path) }
                    } label: {
                        HomeProjectRowLabel(project: p, expanded: open)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-folder")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    if open {
                        ForEach(p.recent.filter { $0.group == nil && !model.removed.contains($0.id) }) { s in
                            NavigationLink {
                                ChatView(profile: resumeProfile(s), secret: secret,
                                         dir: p.path, resumeSessionId: s.id)
                            } label: {
                                HomeRecentRowLabel(item: .init(dir: p.path, session: s), showsFolder: false)
                                    .padding(.leading, 32)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) { deleteSwipe(.init(dir: p.path, session: s)) }
                        }
                        NavigationLink {
                            SessionsView(profile: profile, secret: secret, dir: p.path, pins: pins)
                        } label: { HomeSeeAllRowLabel(count: p.sessions) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            } header: {
                Text(L.homeProjectsHeader()).font(.caption).foregroundStyle(.secondary)
            }
        }
        if !model.items.isEmpty || !model.groups.isEmpty {
            Section {
                ForEach(model.groups) { gi in
                    NavigationLink {
                        GroupView(profile: profile, secret: secret, group: gi.group)
                    } label: { GroupRowLabel(group: gi.group) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                ForEach(sortedItems) { item in
                    NavigationLink {
                        ChatView(profile: resumeProfile(item.session), secret: secret,
                                 dir: item.dir, resumeSessionId: item.session.id)
                    } label: {
                        HomeRecentRowLabel(item: item, pinned: pins.isPinned(pinKey(item)), showsFolder: false)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    // Leading swipe = pin/unpin (green, like Workflows' "Run now").
                    .swipeActions(edge: .leading) {
                        Button { pins.togglePin(pinKey(item)) } label: {
                            Label(pins.isPinned(pinKey(item)) ? L.unpin() : L.pin(),
                                  systemImage: pins.isPinned(pinKey(item)) ? "pin.slash.fill" : "pin.fill")
                        }
                        .tint(.green)
                    }
                    // Trailing swipe = delete, the same as the project's list (2026-10-21).
                    .swipeActions(edge: .trailing) { deleteSwipe(item) }
                }
            } header: {
                Text(L.recentHeader()).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The red swipe: asks first; a pinned conversation keeps no trash (the Mac
    /// refuses it anyway — unpin first), the same rule the project's list has.
    @ViewBuilder
    private func deleteSwipe(_ item: HomeRecentModel.Item) -> some View {
        if !pins.isPinned(pinKey(item)) {
            // Plain + red, not role .destructive: the row stays until the question
            // is answered (see SessionsView).
            Button { model.pendingDir = item.dir; model.pendingDelete = item.session } label: {
                Label(L.delete(), systemImage: "trash")
            }
            .tint(.red)
            .accessibilityIdentifier("delete-conversation")
        }
    }

    /// Pinned rows always make the page (that is what pinning MEANS), the
    /// newest besides them below. See `visibleRows`.
    private var sortedItems: [HomeRecentModel.Item] {
        Self.visibleRows(model.items,
                         pinnedFirst: { pins.sortedPinnedFirst($0, keyFor: pinKey) },
                         isPinned: { pins.isPinned(pinKey($0)) })
    }

    /// The home block's composition rule. Pinning used to reorder only WITHIN
    /// the three newest, so a pinned conversation that fell out of the top
    /// three vanished from home — pinning it had done nothing exactly where it
    /// was supposed to matter. Now:
    ///   * every shown pin comes first (most-recently pinned on top), capped at
    ///     three so a pin spree can't take the whole page;
    ///   * then the newest UNPINNED rows, ten at most (2026-10-17: the block is
    ///     now the default folder's own chats, worth a longer list than the
    ///     three the cross-project block used to show).
    /// Thirteen rows worst case, between the folders block and the servers footer.
    static func visibleRows(_ items: [HomeRecentModel.Item],
                            pinnedFirst: ([HomeRecentModel.Item]) -> [HomeRecentModel.Item],
                            isPinned: (HomeRecentModel.Item) -> Bool,
                            newest: Int = 10) -> [HomeRecentModel.Item] {
        let pinned = pinnedFirst(items.filter(isPinned)).prefix(3)
        let recent = items.filter { !isPinned($0) }.prefix(newest)
        return Array(pinned) + Array(recent)
    }

    /// The conversation's pin key — identical to the one SessionsView builds, so
    /// the two lists share one pin per conversation.
    private func pinKey(_ item: HomeRecentModel.Item) -> String {
        PinStore.key(profileId: profile.id, dir: item.dir, sessionId: item.session.id)
    }

    /// Same as SessionsView.resumeProfile: resume with the session's own agent.
    private func resumeProfile(_ session: SessionSummary) -> ServerProfile {
        var p = profile
        p.backend = session.agent
        return p
    }
}

/// One recent row's visual. Factored out of the NavigationLink so the snapshot
/// suite can render it outside a List.
struct HomeRecentRowLabel: View {
    let item: HomeRecentModel.Item
    /// Whether this row is pinned — draws a small, quiet pin at the trailing edge.
    /// Defaults off so the snapshot fixtures (which render an unpinned row) are
    /// byte-for-byte unchanged; the live list passes the pin state.
    var pinned: Bool = false
    /// The "· folder" caption. Off under a folder header and in the default
    /// folder's own block, where every row shares the folder anyway.
    var showsFolder: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            Image(item.session.agent.iconAsset)
                .resizable().scaledToFit()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.session.title)
                    .font(.subheadline).lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.session.modifiedDate,
                         format: .relative(presentation: .named))
                    if showsFolder {
                        Text("·")
                        Text((item.dir as NSString).lastPathComponent)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                .environment(\.locale, L.locale())
            }
            // Quiet pin marker: tertiary, so it reads as "kept handy" without
            // competing with the agent icon or the title.
            if pinned {
                Spacer(minLength: 4)
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// A folder row on the home page: the folder's name, how many conversations it
/// holds and when it was last touched; the chevron says whether it is open.
struct HomeProjectRowLabel: View {
    let project: HomeProject
    var expanded: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.body)
                .foregroundStyle(Palette.accent)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(L.homeProjectCount(project.sessions))
                    Text("·")
                    Text(project.modifiedDate, format: .relative(presentation: .named))
                }
                .font(.caption2).foregroundStyle(.secondary)
                .environment(\.locale, L.locale())
            }
            Spacer(minLength: 8)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The last row under an opened folder: into its whole history.
struct HomeSeeAllRowLabel: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(L.homeSeeAll(count))
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
        }
        .font(.caption)
        .foregroundStyle(Palette.accent)
        .padding(.leading, 32)
    }
}

/// Which folders the person opened on a server's home page, kept on the phone
/// so the page comes back the way it was left. Collapsed is the default.
enum HomeFolderMemory {
    static func key(_ profileId: UUID) -> String { "pervio.home.expanded.\(profileId.uuidString)" }

    static func expanded(for profileId: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(profileId)) ?? [])
    }

    static func set(_ paths: Set<String>, for profileId: UUID) {
        if paths.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(profileId))
        } else {
            UserDefaults.standard.set(Array(paths).sorted(), forKey: key(profileId))
        }
    }
}

// MARK: - Running indicator

/// The running-indicator row: the otter mascot + "N 个在跑", tapping through to
/// the SAME running-tasks list the pill opens (`RunListView`). Hidden entirely
/// when nothing is running. Sits between the publications strip and Recent.
///
/// Why a `RunMonitor` here, not the one-shot count this used to keep. The count
/// mixes two kinds of work — running workflows AND running detached runs (the
/// background sessions `pervio-run` keeps alive) — but the row used to open
/// `WorkflowsView`, which lists workflows ONLY. So a detached run that pushed the
/// count to "1 个在跑" led, on tap, to an empty Workflows list: the run was
/// counted but unreachable (user: "从运行中点进去 好像永远只是 wf 页面"). The fix
/// is to open the pill's own `RunListView`, which lists running workflows and
/// detached conversations side by side — but that view is driven by a live
/// `RunMonitor`, not a frozen number. So the home page now holds a real monitor
/// (see RootView), started while the page is on screen and stopped when it
/// leaves, exactly like `AppStore.activateRuns`/`deactivateRuns` does for a
/// server's screens.
///
/// The trade this makes on purpose: the entry page was "one-shot connect, fail
/// silently" (like the publications/recent blocks); a `RunMonitor` is a STANDING
/// poll instead. That costs one more resident connection while the home page is
/// visible — but it's the only way the tap target can contain what the count
/// counted (a workflow monitor can't show a detached run), and it puts the home
/// page on the same footing as every server screen, which already runs this
/// exact poll behind the pill. The monitor still fails quietly: a poll it can't
/// complete just leaves `running`/`runningWorkflows` empty, so the row hides —
/// the same resting state the old one-shot had.
struct HomeRunningRow: View {
    let secret: String
    @ObservedObject var monitor: RunMonitor
    /// The running-tasks list, opened on tap. A `.sheet` (not a NavigationLink)
    /// exactly like `RunPillContainer`'s: `RunListView` brings its own
    /// NavigationStack, and it's the same sheet the pill raises elsewhere, so a
    /// run reached from here reattaches identically to one reached from the pill.
    @State private var showRunList = false

    /// The count the label shows: running detached runs + running workflows —
    /// the pill's own tally (`monitor.running.count + monitor.runningWorkflows.count`).
    private var count: Int { monitor.runningUnits + monitor.runningWorkflows.count }

    var body: some View {
        if count > 0 {
            Button { showRunList = true } label: {
                HomeRunningRowLabel(count: count)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .sheet(isPresented: $showRunList) {
                RunListView(monitor: monitor, secret: secret)
            }
        }
    }
}

/// The row's visual, factored out of the NavigationLink so the snapshot suite
/// can render it outside a List. The otter is `otter0`, the resting pose of the
/// runner mascot (the animated frames need a live render loop ImageRenderer
/// doesn't give a snapshot); on the cream card it reads as the same otter the
/// running pill trots.
struct HomeRunningRowLabel: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image("otter0")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .padding(.horizontal, 3)
                .frame(width: 28, height: 28)
                .background(Color(hex: 0xF9F4F0), in: RoundedRectangle(cornerRadius: 7))
            Text(L.runningCount(count))
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Servers footer

/// Block 5: the servers line at the foot of the entry page, split into TWO tap
/// zones. The left (status dot + the home server's identity, so "which machine
/// am I talking to" never needs a tap) drops straight into that server's
/// ProjectsView — the one it leads with. Only the trailing "Servers" word opens
/// the management list. Two Buttons over the shared NavigationPath, NOT sibling
/// NavigationLinks, which would collapse into one activation (the whole reason
/// HomeComposerRow drives the path directly).
struct HomeServersLine: View {
    let profile: ServerProfile
    @Binding var path: NavigationPath

    var body: some View {
        HStack(spacing: 8) {
            // Left zone: dive into the home server's projects. Appending the
            // profile hits RootView's stack-level ProjectsView destination.
            // The Spacer lives INSIDE this button so the whole body of the line —
            // not just the glyphs — is the "walk into my Mac" target; otherwise
            // the gap between the host and the trailing word swallowed taps and
            // the row felt dead in its middle.
            Button { path.append(profile) } label: {
                HStack(spacing: 8) {
                    Circle().fill(Palette.accent).frame(width: 7, height: 7)
                    Text("\(profile.name) · \(profile.username)@\(profile.host)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Right zone: the management list. Its own tap target, so the two
            // never blur into "I tapped the name and got the admin page".
            Button { path.append(HomeQuickDest.servers) } label: {
                Text(L.serversTitle()).font(.caption).foregroundStyle(Palette.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// The label-only footer, kept for the snapshot suite (which renders the row
/// bare, without a NavigationPath). Same two-zone LOOK the live `HomeServersLine`
/// draws — identity on the left, the accent "Servers" word on the right.
struct HomeServersLineLabel: View {
    let profile: ServerProfile

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.accent).frame(width: 7, height: 7)
            Text("\(profile.name) · \(profile.username)@\(profile.host)")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(L.serversTitle()).font(.caption).foregroundStyle(Palette.accent)
        }
    }
}
