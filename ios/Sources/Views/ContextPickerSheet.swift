import SwiftUI

/// ＋ → 背景…: browse this server's past conversations (any project) and pick
/// one whose transcript becomes a context attachment on the current message.
///
/// Two layers: projects (pervio-sessions projects) → that project's sessions
/// (list --dir). A search box on top switches to a flat cross-project result
/// list (pervio-sessions search) on submit; clearing it returns to browsing.
/// Browsing and search share one connection for the sheet's lifetime
/// (SessionService — the same helper the history drawer uses), disconnected when
/// the sheet goes away; the transcript export + injection happens in ChatStore
/// AFTER the pick, on the chat's own connection.
///
/// With more than one computer saved (2026-11-22) a row on top says whose
/// conversations the page lists. Choosing another computer swaps the whole
/// pane for one connected to it; what is picked there is brought over through
/// the phone (`onPickRemote` → ChatStore.attachFromAsync).
struct ContextPickerSheet: View {
    let profile: ServerProfile
    let secret: String
    let currentDir: String
    let currentSessionId: String?
    /// The other saved computers; empty = no source row.
    var others: [ServerProfile] = []
    /// A saved computer's own credential (the Keychain, by its id).
    var secretFor: (ServerProfile) -> String = { Keychain.get($0.id.uuidString) ?? "" }
    /// Picked on ANOTHER computer: (which, project path, conversations, files).
    var onPickRemote: (RemoteSource, String, [SessionSummary], [String]) -> Void = { _, _, _, _ in }
    let onPick: (String, SessionSummary) -> Void
    var onPickMany: (String, [SessionSummary], [String]) -> Void = { _, _, _ in }
    let onPickServerFile: (String) -> Void
    let onHandoffDir: (String) -> Void

    /// The other computer chosen in the From row, with its credential — read
    /// once, when it is chosen (nil = this conversation's own).
    @State private var remote: RemoteSource?

    var body: some View {
        let from = remote?.profile ?? profile
        ContextPickerPane(
            profile: from, secret: remote?.secret ?? secret,
            // "This project" and "this conversation" are this computer's: a
            // folder of the same path on another one is another folder.
            currentDir: remote == nil ? currentDir : "",
            currentSessionId: remote == nil ? currentSessionId : nil,
            remoteTarget: remote == nil ? nil : profile.name,
            top: others.isEmpty ? nil : AnyView(
                SourceSwitcher(here: profile, others: others,
                               selected: Binding(get: { from.id }, set: { id in
                                   remote = others.first { $0.id == id }
                                       .map { RemoteSource(profile: $0, secret: secretFor($0)) }
                               }),
                               note: remote == nil ? nil : L.remoteContextNote(profile.name))),
            onPick: { path, session in
                if let remote { onPickRemote(remote, path, [session], []) } else { onPick(path, session) }
            },
            onPickMany: { path, sessions, docs in
                if let remote { onPickRemote(remote, path, sessions, docs) } else { onPickMany(path, sessions, docs) }
            },
            onPickServerFile: onPickServerFile, onHandoffDir: onHandoffDir)
            .id(from.id)        // another computer = another pane, with its own connection
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }
}

/// "来自 [name ⌄]": whose files or conversations the page lists, and — for
/// another computer — the one line saying how a pick gets here.
struct SourceSwitcher: View {
    let here: ServerProfile
    let others: [ServerProfile]
    @Binding var selected: UUID
    var note: String? = nil

    /// Two entries of one name are told apart by their address.
    private func title(_ p: ServerProfile) -> String {
        let twins = ([here] + others).filter { $0.name == p.name }.count > 1
        return twins ? "\(p.name) · \(p.host)" : p.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L.sourceLabel()).font(.footnote).foregroundStyle(.secondary)
                Menu {
                    Picker(L.sourceLabel(), selection: $selected) {
                        Text(L.sourceHere(title(here))).tag(here.id)
                        ForEach(others) { p in Text(title(p)).tag(p.id) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "desktopcomputer").font(.footnote)
                        Text(title(([here] + others).first { $0.id == selected } ?? here))
                            .font(.footnote.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Palette.surface, in: Capsule())
                    .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
                }
                .accessibilityIdentifier("source-switcher")
                Spacer(minLength: 0)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("source-note")
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One computer's conversations: the picker proper.
private struct ContextPickerPane: View {
    let profile: ServerProfile
    let secret: String
    /// The current conversation's project dir — pinned on top, tagged 「本项目」.
    let currentDir: String
    /// The current conversation's session id (nil for a brand-new chat). Shown
    /// but NOT selectable: exporting the conversation being typed into is
    /// self-reference, not background.
    let currentSessionId: String?
    /// Receives (projectPath, session); the presenter injects and dismisses.
    let onPick: (String, SessionSummary) -> Void
    /// Several at once (2026-10-17): (projectPath, conversations, document
    /// paths — CLAUDE.md / AGENTS.md / rules / memory files of that folder).
    let onPickMany: (String, [SessionSummary], [String]) -> Void
    /// F2: the server file browser picked a FILE (absolute path); the presenter
    /// attaches it (ChatStore.attachServerFileAsync — single uploads-path
    /// route, both backends) and dismisses.
    let onPickServerFile: (String) -> Void
    /// F3: 「把此目录交给对话」 on a browser directory layer (absolute path);
    /// the presenter inserts ChatStore.projectHandoffText into the composer —
    /// nothing is packed — and dismisses.
    let onHandoffDir: (String) -> Void
    /// Non-nil when this pane lists ANOTHER computer: the name of the
    /// conversation's own, where a pick is brought. The footers that describe
    /// a pick on this computer (the paging command, the 300 KB document) stay
    /// out — the row on top says what happens instead.
    let remoteTarget: String?
    /// The source row (SourceSwitcher), above the search box.
    let top: AnyView?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var service: SessionService
    @State private var projects: [ProjectInfo] = []
    @State private var loading = true
    @State private var loadError: String?

    // Search (pervio-sessions search): submit-time only — typing never fires a
    // scan; Return does. Non-nil `searchQuery` = search mode (flat results
    // replace the two-layer browse); clearing the field returns to browse.
    @State private var searchText = ""
    @State private var searchQuery: String?
    @State private var searching = false
    @State private var searchError: String?
    @State private var searchHits: [SessionSearchHit] = []
    @State private var searchTask: Task<Void, Never>?

    init(profile: ServerProfile, secret: String, currentDir: String,
         currentSessionId: String?, remoteTarget: String? = nil, top: AnyView? = nil,
         onPick: @escaping (String, SessionSummary) -> Void,
         onPickMany: @escaping (String, [SessionSummary], [String]) -> Void = { _, _, _ in },
         onPickServerFile: @escaping (String) -> Void,
         onHandoffDir: @escaping (String) -> Void) {
        self.profile = profile
        self.secret = secret
        self.currentDir = currentDir
        self.currentSessionId = currentSessionId
        self.remoteTarget = remoteTarget
        self.top = top
        self.onPick = onPick
        self.onPickMany = onPickMany
        self.onPickServerFile = onPickServerFile
        self.onHandoffDir = onHandoffDir
        _service = StateObject(wrappedValue: SessionService(profile: profile, secret: secret))
    }

    /// Is this server-reported project cwd the CURRENT conversation's dir?
    /// `currentDir` comes from the profile and may be tilde-form ("~/tail" —
    /// the default profile dir is even a bare "~"), while `projects` reports
    /// absolute cwds — so also match "~/tail" against ".../tail". A bare "~"
    /// stays unmatched (the server home isn't known client-side); the badge
    /// simply doesn't show then — picking still works, it uses the row's path.
    private func isCurrentProject(_ path: String) -> Bool {
        if path == currentDir { return true }
        if currentDir.hasPrefix("~/") {
            return path.hasSuffix("/" + currentDir.dropFirst(2))
        }
        return false
    }

    /// Current project first (「本项目」), the rest in the server's order
    /// (already most-recently-active first).
    private var orderedProjects: [ProjectInfo] {
        let mine = projects.filter { isCurrentProject($0.path) }
        return mine + projects.filter { !isCurrentProject($0.path) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let top { top }
                searchField
                if searchQuery != nil {
                    searchResults
                } else {
                    browseContent
                }
            }
            .pervioBackground()
            .pervioBar(L.contextTitle(), back: false)
            .toolbar {
                BarItem(.cancellationAction) {
                    BarWord(text: L.cancel()) { dismiss() }
                }
            }
        }
        .task { await load() }
        .onChange(of: searchText) { _, text in
            // Emptying the field (x button or deletes) returns to browse; typing
            // alone never searches — only Return does (runSearch via onSubmit).
            if text.trimmingCharacters(in: .whitespaces).isEmpty { clearSearch() }
        }
        .onDisappear {
            searchTask?.cancel()
            Task { await service.close() }
        }
    }

    /// Two-layer browse (projects → sessions) plus, above the projects, the
    /// server file browser entry (F1) — present even when the history list is
    /// empty or failed, since attaching files doesn't need past conversations.
    @ViewBuilder private var browseContent: some View {
        if loading {
            HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                // 背景 = past conversations only. Files and directories have
                // their own ＋ entry (服务器文件…), so the browser row that used
                // to sit here was the same thing twice (2026-10-15: 设计要统一).
                if let err = loadError {
                    Section {
                        Text(err).font(.caption).foregroundStyle(.red)
                            .listRowBackground(Palette.surface)
                    }
                } else if projects.isEmpty {
                    Section {
                        Text(L.noConversationsOnServer())
                            .font(.subheadline).foregroundStyle(.secondary)
                            .listRowBackground(Palette.surface)
                    }
                } else {
                    Section {
                        ForEach(orderedProjects) { p in
                            NavigationLink {
                                ContextSessionList(service: service, project: p,
                                                   currentSessionId: currentSessionId,
                                                   remote: remoteTarget != nil,
                                                   onPickMany: onPickMany)
                            } label: {
                                projectRow(p)
                            }
                            .listRowBackground(Palette.surface)
                        }
                    } footer: {
                        if remoteTarget == nil { Text(L.contextProjectsFooter(ChatStore.contextTurnLimit)) }
                    }
                }
            }
        }
    }

    // MARK: - Search (submit-time, flat results)

    /// Search box atop the picker — same styling as the history drawer's.
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.footnote).foregroundStyle(.secondary)
            TextField(L.searchAllProjects(), text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { runSearch() }
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
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

    /// Flat cross-project results: project tail name + snippet + backend badge +
    /// relative time. Picking rides the SAME onPick as browse; the current
    /// conversation shows but stays unselectable, as in the browse layer.
    @ViewBuilder private var searchResults: some View {
        if searching {
            HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = searchError {
            Text(err).font(.caption).foregroundStyle(.red)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if searchHits.isEmpty {
            Text(L.noConversationMentions(searchQuery ?? ""))
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            List {
                Section {
                    ForEach(searchHits) { hit in
                        if hit.id == currentSessionId {
                            hitRow(hit, isCurrent: true)
                                .listRowBackground(Palette.surface)
                        } else {
                            Button { onPick(hit.project, hit.summary) } label: {
                                hitRow(hit, isCurrent: false)
                            }
                            .listRowBackground(Palette.surface)
                        }
                    }
                } footer: {
                    if remoteTarget == nil { Text(L.contextSearchFooter(ChatStore.contextTurnLimit)) }
                }
            }
        }
    }

    private func hitRow(_ hit: SessionSearchHit, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(hit.projectName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCurrent ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                if isCurrent {
                    // fixedSize: "This conversation" is more than twice the
                    // width of 「当前对话」, and in an HStack next to a project
                    // name of any length SwiftUI would shorten the CHIP —
                    // "This conve…" reads like a broken row, while a clipped
                    // project name still reads as a name. The variable half
                    // yields; the fixed label never does.
                    Text(L.currentConversation())
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.surface2, in: Capsule())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            if !hit.snippet.isEmpty {
                Text(hit.snippet)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 6) {
                Text(hit.agent.tag)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Palette.surface2, in: Capsule())
                    .foregroundStyle(.tint)
                Text(hit.modifiedDate, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Fire the server-side scan for the CURRENT field text. Re-submitting while
    /// one runs cancels the old task; results landing for a cancelled task are
    /// dropped (the guard), so stale hits can't overwrite a newer query's.
    private func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { clearSearch(); return }
        searchTask?.cancel()
        searchQuery = q
        searching = true
        searchError = nil
        searchHits = []
        searchTask = Task {
            do {
                let hits = try await service.search(query: q, scoped: false)   // input is not fenced
                guard !Task.isCancelled else { return }
                searchHits = hits
                searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                searchError = pervioErrorText(error, L.searchFailed())
            }
            searching = false
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchQuery = nil
        searching = false
        searchError = nil
        searchHits = []
    }

    private func projectRow(_ p: ProjectInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text((p.path as NSString).lastPathComponent)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.middle)
                if isCurrentProject(p.path) {
                    // See the search row below: the chip keeps its full width
                    // ("This project" vs 「本项目」) and the folder name yields.
                    Text(L.thisProject())
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.accent.opacity(0.18), in: Capsule())
                        .foregroundStyle(.tint)
                        .fixedSize()
                }
            }
            Text(p.path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                Text(L.sessionCount(p.sessions)).foregroundStyle(.tint)
                Text(p.modifiedDate, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            do {
                projects = try await service.projects(scoped: false)   // what you hand over is not fenced (2026-10-17)
            } catch let error where remoteTarget != nil && !Task.isCancelled
                        && !(error is SSHService.ConnectionError) && !(error is CancellationError) {
                // The other computer answered, but not with a project list: it
                // may never have been the home one — the only one whose scripts
                // the app keeps current — so its `pervio-sessions` is missing
                // or old. Bring the scripts up to this build and ask once more.
                // Not for a computer that cannot be reached (the same wait
                // again), and never from a page already closed: a cancelled
                // task gets every command's reply back empty at once, so an
                // install started from one would fire its whole sequence
                // without waiting for any step. Hence a task of its own —
                // once started, it finishes like the home computer's does.
                let (far, key) = (profile, secret)
                _ = await Task { await ServerProvisioner().ensureCurrent(profile: far, secret: key) }.value
                guard !Task.isCancelled else { return }
                await service.disconnect()
                projects = try await service.projects(scoped: false)
            }
            loadError = nil
        } catch {
            loadError = pervioErrorText(error, "Couldn't load the projects.")
        }
    }
}

/// Layer two: the picked project's conversations, newest first. The current
/// conversation (if it lives here) is tagged 「当前对话」 and not selectable.
/// One project's layer: tick what to hand over — its conversations, and the
/// notes / rules / memory files its agents read on their own (CLAUDE.md,
/// AGENTS.md, .claude/rules, .cursor/rules, Claude's memory for the folder) —
/// then one button attaches them all (the person's ask, 2026-10-17). The
/// files are listed by name so what goes over is visible before it does.
private struct ContextSessionList: View {
    @ObservedObject var service: SessionService
    let project: ProjectInfo
    let currentSessionId: String?
    /// Listing another computer: see ContextPickerPane.remoteTarget.
    var remote = false
    let onPickMany: (String, [SessionSummary], [String]) -> Void

    @State private var sessions: [SessionSummary] = []
    @State private var docs: [ProjectDoc] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var pickedSessions: Set<String> = []
    @State private var pickedDocs: Set<String> = []

    private var notes: [ProjectDoc] { docs.filter { !$0.isMemory } }
    private var memory: [ProjectDoc] { docs.filter(\.isMemory) }
    private var pickedCount: Int { pickedSessions.count + pickedDocs.count }

    var body: some View {
        Group {
            if loading {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if sessions.isEmpty && docs.isEmpty {
                Text(L.noConversationsInProject())
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                List {
                    if !notes.isEmpty {
                        Section {
                            ForEach(notes) { d in docRow(d) }
                        } header: { Text(L.contextNotesSection()) }
                    }
                    if !memory.isEmpty {
                        Section {
                            ForEach(memory) { d in docRow(d) }
                        } header: { Text(L.contextMemorySection()) } footer: { Text(L.contextMemoryFooter()) }
                    }
                    Section {
                        ForEach(sessions) { s in
                            if s.id == currentSessionId {
                                row(s, isCurrent: true, picked: false)
                                    .listRowBackground(Palette.surface)
                            } else {
                                Button {
                                    if pickedSessions.contains(s.id) { pickedSessions.remove(s.id) } else { pickedSessions.insert(s.id) }
                                } label: {
                                    row(s, isCurrent: false, picked: pickedSessions.contains(s.id))
                                }
                                .listRowBackground(Palette.surface)
                            }
                        }
                    } header: { Text(L.contextConversationsSection()) } footer: {
                        if !remote { Text(L.contextSessionFooter(ChatStore.contextTurnLimit)) }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        let picks = sessions.filter { pickedSessions.contains($0.id) }
                        let files = docs.filter { pickedDocs.contains($0.path) }.map(\.path)
                        onPickMany(project.path, picks, files)
                    } label: {
                        Text(L.contextAttachCount(pickedCount))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pickedCount == 0)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .accessibilityIdentifier("context-attach")
                }
            }
        }
        .pervioBackground()
        .pervioBar((project.path as NSString).lastPathComponent)
        .task { await load() }
    }

    private func docRow(_ d: ProjectDoc) -> some View {
        Button {
            if pickedDocs.contains(d.path) { pickedDocs.remove(d.path) } else { pickedDocs.insert(d.path) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: pickedDocs.contains(d.path) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(pickedDocs.contains(d.path) ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(d.name).font(.subheadline)
                        DocEngineMarks(kind: d.kind)
                    }
                    Text(d.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 4)
                Text(ByteCountFormatter.string(fromByteCount: Int64(d.bytes), countStyle: .file))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Palette.surface)
    }

    private func row(_ s: SessionSummary, isCurrent: Bool, picked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !isCurrent {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                }
                Text(s.title)
                    .font(.subheadline).foregroundStyle(isCurrent ? .secondary : .primary)
                    .lineLimit(2)
                if isCurrent {
                    // The session title next to it is already free to wrap onto
                    // a second line; the chip is not, so pin its width.
                    Text(L.currentConversation())
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.surface2, in: Capsule())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            HStack(spacing: 6) {
                Text(s.agent.tag)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Palette.surface2, in: Capsule())
                    .foregroundStyle(.tint)
                Text(s.modifiedDate, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            sessions = try await service.sessions(dir: project.path)
            loadError = nil
        } catch {
            loadError = pervioErrorText(error, "Couldn't load this project's conversations.")
        }
        // The folder's own documents ride along; an older server without the
        // verb simply lists none.
        docs = (try? await service.projectDocs(dir: project.path)) ?? []
    }
}

/// F1: path browser over the server's real file system. One SSH call per layer
/// (the embedded fs script's `ls`) on the sheet's one-shot connection, same
/// lifecycle as the project/session layers. Navigation is IN PLACE — tapping a
/// directory descends by swapping `path`, the header's 上一级 ascends — so a
/// deep tree never piles up NavigationLink layers, and the toolbar back always
/// returns straight to the picker root.
struct ServerFileBrowser: View {
    @ObservedObject var service: SessionService
    /// The profile's projectDir, possibly tilde-form ("~", "~/x") — the SERVER
    /// script expands it; the first successful listing replaces it with the
    /// resolved absolute path for display and parent math.
    let startPath: String
    let onPickFile: (String) -> Void
    let onHandoffDir: (String) -> Void
    /// Folder-picker use (DirectoryPickerSheet): the directory button says
    /// "use this directory" instead of the composer's hand-off wording, and
    /// the hand-off footer stays out.
    var dirActionLabel: String? = nil
    /// The server's scope (ServerProfile.scopeDir): listings are fenced to it
    /// on the Mac and "up one level" stops at it. nil = the whole disk.
    var fence: String? = nil
    /// Non-nil when browsing ANOTHER computer for a file to bring over: the
    /// largest one a tap may bring (a larger one says so in its row and is not
    /// tappable — the limit is known here, before anything is read). In that
    /// mode a directory cannot be handed over (its path means nothing to the
    /// conversation's own computer) and the page's footer about attaching text
    /// stays out; the sheet's source row carries the note.
    var bringCap: Int? = nil

    @State private var path = ""
    @State private var fencedRoot = false
    @State private var entries: [ServerFileEntry] = []
    @State private var total = 0
    @State private var capped = false
    @State private var loading = true
    @State private var loadError: String?
    @State private var showHidden = false
    /// The one in-flight listing. Kept so every navigation can cancel and
    /// replace it — a slow earlier descend must never land its rows on top of
    /// a newer layer.
    @State private var loadTask: Task<Void, Never>?

    /// Hidden (dot-prefixed) entries are returned by the script but shown only
    /// when the bottom toggle says so.
    private var visible: [ServerFileEntry] {
        showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }

    private var parentPath: String {
        (path as NSString).deletingLastPathComponent
    }

    private var atRoot: Bool { path.isEmpty || path == "/" || fencedRoot }

    var body: some View {
        VStack(spacing: 0) {
            header
            if loading {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                listBody
            }
        }
        .pervioBackground()
        .pervioBar(L.serverFilesTitle(), back: false)
        .task { navigate(startPath) }
        .onDisappear { loadTask?.cancel() }
    }

    /// Current path + 上一级, pinned above the list.
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                navigate(parentPath)
            } label: {
                Label(L.goUpOneLevel(), systemImage: "arrow.turn.left.up")
                    .font(.footnote.weight(.semibold))
                    // "Up one level" is four times the width of 「上一级」 and
                    // sits beside a path that already truncates in the middle.
                    // The path is the flexible one — the button that navigates
                    // must never come out as "Up one lev…".
                    .fixedSize()
            }
            .buttonStyle(.bordered)
            .disabled(atRoot || loading)
            Text(path.isEmpty ? startPath : path)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private var listBody: some View {
        List {
            // A failed descend (permission / vanished dir) reports inline and
            // keeps the current layer's rows below, so you're never stranded.
            if let err = loadError {
                Section {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .listRowBackground(Palette.surface)
                }
            }
            if !path.isEmpty, bringCap == nil {
                Section {
                    Button {
                        onHandoffDir(path)
                    } label: {
                        Label(dirActionLabel ?? L.handOffDirectory(),
                              systemImage: dirActionLabel == nil ? "text.insert" : "checkmark.circle")
                            .font(.subheadline)
                    }
                    .listRowBackground(Palette.surface)
                } footer: {
                    if dirActionLabel == nil { Text(L.handoffDirFooter()) }
                }
            }
            Section {
                // The "empty" rows only speak when the layer actually loaded —
                // while loadError is up, an empty `entries` just means the load
                // failed, and claiming 此目录为空 would be a lie.
                if visible.isEmpty, loadError == nil {
                    Text(entries.isEmpty ? L.directoryEmpty() : L.onlyHiddenItems())
                        .font(.subheadline).foregroundStyle(.secondary)
                        .listRowBackground(Palette.surface)
                } else if !visible.isEmpty {
                    ForEach(visible) { e in
                        let tooBig = !e.isDir && e.size > (bringCap ?? .max)
                        Button {
                            let full = (path as NSString).appendingPathComponent(e.name)
                            if e.isDir {
                                navigate(full)
                            } else {
                                onPickFile(full)
                            }
                        } label: {
                            entryRow(e, tooBig: tooBig)
                        }
                        .disabled(tooBig)
                        .listRowBackground(Palette.surface)
                    }
                }
            } footer: {
                if capped {
                    Text(L.directoryCapped(total))
                }
            }
            Section {
                Toggle(L.showHiddenItems(), isOn: $showHidden)
                    .font(.subheadline)
                    .listRowBackground(Palette.surface)
            } footer: {
                if bringCap == nil { Text(L.fileBrowserFooter()) }
            }
        }
    }

    private func entryRow(_ e: ServerFileEntry, tooBig: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: e.isDir ? "folder.fill" : "doc.text")
                .font(.subheadline)
                .foregroundStyle(e.isDir ? Color.accentColor : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name)
                    .font(.subheadline).foregroundStyle(tooBig ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                if let link = e.link {
                    // A link, and where it leads — seen before it is tapped.
                    // The mark is its own glyph: a long path is cut at its
                    // head, and a "→" typed in front of it went with the cut.
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.turn.down.right")
                        Text(link).lineLimit(1).truncationMode(.head)
                    }
                    .font(.caption2).foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("entry-link")
                }
            }
            Spacer(minLength: 6)
            if tooBig {
                // Said in the row, before a tap: this one cannot be brought.
                Text(L.remoteFileOverCap())
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize()
            }
            if !e.isDir {
                Text(ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if e.mtime > 0 {
                Text(e.modifiedDate, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if e.isDir {
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// The only way to change layers: cancel whatever listing is still in
    /// flight and start the new one, so results always apply in tap order.
    private func navigate(_ target: String) {
        loadTask?.cancel()
        loadTask = Task { await load(target) }
    }

    private func load(_ target: String) async {
        loading = true              // every navigation shows the loading state,
        loadError = nil             // descends included — no stale rows to tap
        do {
            let listing = try await service.listDir(target, under: fence)
            guard !Task.isCancelled else { return }   // superseded navigation
            if let code = listing.error {
                loadError = SSHService.serverFsErrorText(code)   // stay on current layer
            } else {
                path = listing.path ?? target
                fencedRoot = listing.atRoot ?? false
                entries = listing.entries ?? []
                total = listing.total ?? entries.count
                capped = listing.truncated ?? false
            }
        } catch is CancellationError {
            return                  // the newer navigation owns the UI now
        } catch {
            guard !Task.isCancelled else { return }
            loadError = pervioErrorText(error, L.directoryReadFailed())
        }
        // A FIRST load that failed outright (path never resolved — e.g. the
        // profile's projectDir no longer exists on this server) retries once
        // against the server home, so the browser opens somewhere real instead
        // of an error over a dead empty screen.
        if loadError != nil, path.isEmpty, target != "~" {
            await load("~")
            return
        }
        loading = false
    }
}

/// ＋ → 服务器文件…: the SAME browser the 背景 sheet embeds (F1 browse, F2 file
/// pick, F3 directory handoff), given its own front door. It shipped buried as
/// a row INSIDE the context picker, where "attach a file that's already on the
/// Mac" read as background-transcript machinery and went unfound — the user
/// asked for the feature believing it didn't exist. Lives in this file so it
/// can host the private `ServerFileBrowser`; the one-shot SessionService
/// lifecycle (built per presentation, disconnected on dismiss) is
/// ContextPickerSheet's, copied.
struct ServerFileSheet: View {
    let profile: ServerProfile
    let secret: String
    /// Where browsing starts — the conversation's own dir (tilde-form is fine;
    /// the server script resolves it, same as the embedded browser).
    let startPath: String
    /// The other saved computers; empty = no source row (2026-11-22).
    var others: [ServerProfile] = []
    /// A saved computer's own credential (the Keychain, by its id).
    var secretFor: (ServerProfile) -> String = { Keychain.get($0.id.uuidString) ?? "" }
    /// A file picked on ANOTHER computer: brought over through the phone.
    var onPickRemoteFile: (RemoteSource, String) -> Void = { _, _ in }
    let onPickFile: (String) -> Void
    let onHandoffDir: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The other computer chosen in the From row, with its credential — read
    /// once, when it is chosen (nil = this conversation's own).
    @State private var remote: RemoteSource?

    var body: some View {
        let from = remote?.profile ?? profile
        NavigationStack {
            VStack(spacing: 0) {
                if !others.isEmpty {
                    SourceSwitcher(here: profile, others: others,
                                   selected: Binding(get: { from.id }, set: { id in
                                       remote = others.first { $0.id == id }
                                           .map { RemoteSource(profile: $0, secret: secretFor($0)) }
                                   }),
                                   note: remote == nil ? nil : L.remoteFilesNote(profile.name))
                }
                ServerFilePane(profile: from, secret: remote?.secret ?? secret,
                               // Another computer starts in ITS working folder:
                               // this conversation's need not exist there.
                               startPath: remote == nil ? startPath : from.scopeDir,
                               bringCap: remote == nil ? nil : RemoteRead.fileCap,
                               onPickFile: { path in
                    if let remote { onPickRemoteFile(remote, path) } else { onPickFile(path) }
                },
                               onHandoffDir: onHandoffDir)
                    .id(from.id)    // another computer = another pane, with its own connection
            }
            .pervioBackground()
            .toolbar {
                BarItem(.cancellationAction) {
                    BarWord(text: L.cancel()) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// One computer's files, on a connection of its own for as long as it shows.
private struct ServerFilePane: View {
    let startPath: String
    let bringCap: Int?
    let onPickFile: (String) -> Void
    let onHandoffDir: (String) -> Void
    @StateObject private var service: SessionService

    init(profile: ServerProfile, secret: String, startPath: String, bringCap: Int?,
         onPickFile: @escaping (String) -> Void, onHandoffDir: @escaping (String) -> Void) {
        self.startPath = startPath
        self.bringCap = bringCap
        self.onPickFile = onPickFile
        self.onHandoffDir = onHandoffDir
        _service = StateObject(wrappedValue: SessionService(profile: profile, secret: secret))
    }

    var body: some View {
        ServerFileBrowser(service: service, startPath: startPath,
                          // Attaching is NOT fenced to the server's scope: a ~/a entry may
                          // hand the chat a file from anywhere on the Mac (the person's
                          // call, 2026-10-16). Only where a conversation LIVES is scoped
                          // (the new-conversation directory picker).
                          onPickFile: onPickFile, onHandoffDir: onHandoffDir, bringCap: bringCap)
            .onDisappear { Task { await service.close() } }
    }
}


/// Which engines read a notes file of this kind — the marks beside its name
/// (2026-10-19, in place of a text capsule that crowded the row): Claude Code's
/// for CLAUDE.md, rules and its memory; Codex's and Cursor's for AGENTS.md;
/// Cursor's for .cursor/rules. A tap says it in words.
enum ContextDocEngines {
    static func engines(for kind: String) -> [AgentBackend] {
        switch kind {
        case "claude-md", "rules", "memory": return [.claude]
        case "agents-md": return [.codex, .cursor]
        case "cursor-rules": return [.cursor]
        default: return []
        }
    }
    /// The engine's icon asset.
    static func icon(_ b: AgentBackend) -> String {
        switch b { case .claude: return "claude-code"; case .codex: return "codex"; case .cursor: return "cursor" }
    }
}

struct DocEngineMarks: View {
    let kind: String
    @State private var explain = false

    var body: some View {
        let engines = ContextDocEngines.engines(for: kind)
        if !engines.isEmpty {
            Button { explain = true } label: {
                HStack(spacing: 3) {
                    ForEach(engines, id: \.self) { e in
                        Image(ContextDocEngines.icon(e)).resizable().scaledToFit().frame(width: 14, height: 14)
                    }
                    if kind == "memory" {
                        Text(L.contextMemoryWord()).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.contextDocKind(kind))
            .alert(L.contextDocKind(kind), isPresented: $explain) { Button("OK") {} }
        }
    }
}
