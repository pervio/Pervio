import SwiftUI

/// The entry page (redesigned layout): greeting, the quiet composer, the
/// publications digest, recent threads, and a one-line servers footer. Server
/// management (add/edit/delete/set-home) lives one push away in ServersListView
/// so the home page stays a reading-and-asking surface, not an admin list.
struct RootView: View {
    @EnvironmentObject var store: AppStore
    /// The minimal Settings sheet (prompt language).
    @State private var showingSettings = false
    /// Watched here (same key SettingsView writes) so a language flip re-syncs
    /// ~/.pervio/push/lang on the Mac IMMEDIATELY — the server's push copy
    /// branches on that file, and waiting for the next cold launch would leave
    /// lock-screen pushes in the old language for days.
    @AppStorage(PromptLanguage.defaultsKey) private var promptLanguageRaw
        = PromptLanguage.chinese.rawValue
    /// Refresh-on-return: the page loads on appear and on pull, but coming BACK
    /// from the background used to show whatever was on screen when iOS froze
    /// us — the user's workaround was killing the app. Track the background
    /// transition and rerun the loads on return. The flag (rather than
    /// refreshing on every .active) keeps cold launch and app-switcher peeks
    /// from double-loading on top of .task.
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameFromBackground = false
    /// Today's publications + recent threads (HomeDashboard). Owned here so the
    /// loading `.task` hangs off the List itself — always alive, refires when
    /// the home profile changes — instead of a row that may not render.
    @StateObject private var publications = HomePublicationsModel()
    @StateObject private var recents = HomeRecentModel()
    /// Reads the two blocks above at the page's four times and, when the Mac
    /// could not be reached, reads them again by itself (PageRefresher) — the
    /// page used to stay on its error until the app was quit and opened again.
    @StateObject private var refresher = PageRefresher()
    /// The "N things running on the home server" line (workflows + runs). Unlike
    /// the two one-shot blocks above, this is a STANDING poll (a `RunMonitor`, the
    /// same object the pill uses on every server screen): the row's tap opens the
    /// pill's `RunListView`, which lists running workflows AND detached runs, and
    /// that view is driven by a live monitor, not a frozen count. See HomeRunningRow
    /// for why the tap target has to be that list (a workflow-only route hid every
    /// detached run). Held as `@State?` — not `@StateObject` — because it can only
    /// be built once the home profile (and its secret) are known, and it is rebuilt
    /// when the user switches home server. Its lifecycle is managed by hand
    /// (`syncRunningMonitor` on appear / home-profile change, `.stop()` on
    /// disappear), mirroring `AppStore.activateRuns`/`deactivateRuns`.
    @State private var homeMonitor: RunMonitor?

    /// Driven programmatically so the composer's send and the three chips can be
    /// Buttons. Sibling NavigationLinks inside ONE List row collapse into a
    /// single link — the last one wins the whole row, so "New chat" and
    /// "Workflows" both opened "Build" (measured on a simulator, 2026-08-07).
    @State private var path = NavigationPath()
    /// First-connect pave in flight — lets the publications block show "paving…"
    /// instead of a false "unreachable" while the scripts are still landing.
    @State private var paving = false
    /// Language switch, live (2026-09-01): L strings are read at view-build
    /// time, so already-built screens kept the old language until a relaunch.
    /// Keying the stack on the setting rebuilds the tree the moment it changes.
    @AppStorage(PromptLanguage.defaultsKey) private var uiLanguageRaw
        = PromptLanguage.english.rawValue

    var body: some View {
        NavigationStack(path: $path) {
            List {
                HomeGreetingHeader()

                if let home = store.homeProfile {
                    let secret = store.secret(for: home) ?? ""

                    HomeComposerRow(profile: home, secret: secret, path: $path)

                    HomePublicationRows(profile: home, secret: secret, model: publications,
                                        paving: paving, problem: refresher.problem,
                                        retrying: refresher.retrying,
                                        // After the checkup or the settings: the server may be
                                        // saved differently now — the running row's poll follows it.
                                        reread: { syncRunningMonitor(); refresher.refresh() })

                    // "N things running" — between the paper strip and Recent,
                    // hidden when nothing's running (see HomeRunningRow). Shown only
                    // once its monitor exists (built in syncRunningMonitor when the
                    // home profile is known); until then the row is simply absent,
                    // the same as its resting hidden state.
                    if let m = homeMonitor {
                        HomeRunningRow(secret: secret, monitor: m)
                    }

                    HomeRecentRows(profile: home, secret: secret, model: recents,
                                   pins: store.pins)

                    // Servers, collapsed to one quiet line — but two tap zones:
                    // the left (dot + name + host) drops straight into the home
                    // server's ProjectsView (the machine you talk to most), while
                    // only the trailing "Servers" word opens the management list.
                    // Buttons over an explicit path, not sibling NavigationLinks:
                    // two links in ONE List row collapse and the last wins the
                    // whole row (see HomeComposerRow).
                    Section {
                        HomeServersLine(profile: home, path: $path)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } else {
                    // First run: no profiles yet (homeProfile falls back to the
                    // first profile, so nil means the list is empty). With the
                    // home '+' gone, the empty state is the ONLY way in — so it
                    // pushes ServersListView, where the '+' now lives. Without
                    // this, a brand-new user (no profile → no footer) would have
                    // no route to add their first server at all.
                    ContentUnavailableViewCompat(
                        title: L.noServersTitle(),
                        systemImage: "server.rack",
                        description: L.noServersBody()
                    )
                    .listRowBackground(Color.clear)
                    Section {
                        Button { path.append(HomeQuickDest.servers) } label: {
                            Label(L.addServer(), systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 22).padding(.vertical, 11)
                                .background(Palette.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .pervioBackground()
            // A recent row's delete asks here, on the list that always exists
            // (the rows come and go with the server's answer), 2026-10-21.
            .confirmDeleteConversation($recents.pendingDelete) { s in
                if let home = store.homeProfile {
                    recents.delete(s, dir: recents.pendingDir, profile: home,
                                   secret: store.secret(for: home) ?? "", appStore: store)
                }
            }
            // The composer sits IN the list: a drag on the page while typing
            // must take the keyboard with it, or the only way out is the send.
            .scrollDismissesKeyboard(.interactively)
            // Opened, pulled, come back to, the app back in front: the Mac is
            // read, and read again by itself while it cannot be reached.
            .readsTheMac(refresher) { await readHome() }
            .onAppear {
                store.deactivateRuns()   // back at the entry page → stop the SERVER-page runs monitor
                // Start (or reuse) the HOME page's own runs monitor, so the "N 个在跑"
                // row and the list it opens are live. On appear (incl. navigating
                // BACK here) as well as in .task, because .task only refires when the
                // home profile id changes — a plain back-navigation keeps the id, so
                // without this the standing poll stopped in .onDisappear would never
                // restart. Idempotent: start() no-ops if the task is already running.
                syncRunningMonitor()
            }
            .onDisappear {
                // Leaving the entry page (into a server / chat) → drop the standing
                // poll. Mirrors AppStore.deactivateRuns for the pill's monitor: the
                // home page's signal is only meaningful while the home page is shown.
                homeMonitor?.stop()
            }
            .pervioBar("Pervio", back: false)        // small title; the greeting leads
            .toolbar { homeToolbar }
            .navigationDestination(for: ServerProfile.self) { profile in
                ProjectsView(profile: profile,
                             secret: store.secret(for: profile) ?? "")
            }
            .navigationDestination(for: HomeQuickDest.self) { dest in
                // First-run trap (caught by the 2026-09-01 rehearsal): with no
                // profile yet this closure used to render NOTHING, so the empty
                // state's own "Add server" push landed on a pure black page.
                // .servers needs no profile — route it unconditionally; any
                // profile-needing destination without a home falls back to the
                // server list too, never to a void.
                if case .servers = dest {
                    ServersListView()
                } else if let home = store.homeProfile {
                    HomeQuickDestView(dest: dest, profile: home,
                                      secret: store.secret(for: home) ?? "")
                } else {
                    ServersListView()
                }
            }
            .task(id: store.homeProfile?.id) {
                guard let home = store.homeProfile else { return }
                let secret = store.secret(for: home) ?? ""
                // The home profile is known (or just changed) → point the standing
                // runs monitor at it (rebuilds onto the new server on a home switch).
                syncRunningMonitor()
                // Keep the Mac's scripts in lockstep with this build — content-hash
                // handshake, repave on mismatch (ServerProvisioner). Still detached
                // from first paint, but no longer fire-and-forget: on a VIRGIN Mac
                // the parallel loads below race the pave and lose (command not
                // found → a scary "unreachable" over an all-green doctor — the
                // 2026-09-01 rehearsal's second fish). So the outcome is caught:
                // a fresh pave reloads the page's blocks, and while paving is in
                // flight the error line dresses as an honest progress note.
                Task { await provision(home: home, secret: secret) }
            }
            // Another server became the home one (or the first was added): read it.
            // (Not at launch — opening the page is that read.)
            .onChange(of: store.homeProfile?.id) { _, _ in refresher.refresh() }
            .id(uiLanguageRaw)   // language change → rebuild every L string
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .onChange(of: promptLanguageRaw) { _, newLang in
                // Push copy on the Mac follows ~/.pervio/push/lang; re-sync it now
                // rather than on the next cold launch. Fire-and-forget, same as the
                // token upload it rides on — a miss self-heals at the next launch.
                guard let home = store.homeProfile else { return }
                let secret = store.secret(for: home)
                Task {
                    await PushTokenStore().resyncLanguageIfNeeded(profile: home,
                                                                  secret: secret,
                                                                  lang: newLang)
                }
            }
            .onChange(of: store.notificationRoute) { _, route in
                consumeNotificationRoute(route)
            }
            .onAppear {
                // A cold launch FROM a notification tap: the route was buffered
                // and published before this view existed, so onChange never saw
                // the transition. Consume whatever is already waiting.
                consumeNotificationRoute(store.notificationRoute)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { cameFromBackground = true }
                guard phase == .active, cameFromBackground else { return }
                cameFromBackground = false
                guard store.homeProfile != nil else { return }
                // (What the page shows is read again by its refresher; this is
                // the standing "N running" poll, which stops with the app.)
                syncRunningMonitor()
            }
        }
    }

    /// One read of the home page: its two blocks over two one-shot connections
    /// in parallel — they are independent, so neither waits on the other's SSH.
    /// The server is looked up at every read, so one whose settings were just
    /// edited is read as it is saved now.
    @MainActor
    private func readHome() async -> PageRefresher.Outcome {
        guard let home = store.homeProfile else { return .reached }
        let secret = store.secret(for: home) ?? ""
        async let pubs = publications.load(profile: home, secret: secret)
        async let recent = recents.load(profile: home, secret: secret, pins: store.pins)
        let (a, b) = await (pubs, recent)
        let outcome = PageRefresher.Outcome.worst(a, b)
        // The Mac is back, and the launch-time script check never got through
        // to it: that check, the model menu and the engine probe were this
        // launch's only ones — do them now.
        if outcome == .reached { Task { await provisionIfPending(home: home, secret: secret) } }
        return outcome
    }

    /// A notification tap landed (or was waiting from a cold launch): steer the
    /// stack to what the push was about. One-shot — the route is cleared before
    /// navigating so re-appears don't replay it. The stack is RESET first: the
    /// push's subject, not whatever was open last week, is what the user asked
    /// for by tapping.
    ///
    /// A finished RUN needs a lookup: its push carries only the runId, and the
    /// conversation behind it (dir + session) lives in the Mac's run list. Ask
    /// once at tap time; if the run has already been swept (finished runs are
    /// kept ~6h) there is nothing to resolve — land on home, where Recent shows
    /// the same conversations. Never an error state: a tap always lands somewhere.
    private func consumeNotificationRoute(_ route: NotificationRoute?) {
        guard let route, store.homeProfile != nil else { return }
        store.notificationRoute = nil
        switch route {
        case .home:
            path = NavigationPath()          // the digest strip / recents ARE home
        case .workflow(let wfId):
            path = NavigationPath()
            path.append(HomeQuickDest.monitor(wfId))
        case .run(let runId):
            guard let home = store.homeProfile,
                  let secret = store.secret(for: home) else {
                path = NavigationPath()
                return
            }
            Task {
                let ssh = SSHService()
                var dest: HomeQuickDest?
                if (try? await ssh.connect(profile: home, secret: secret)) != nil,
                   let runs = try? await ssh.listRuns(profile: home),
                   let run = runs.first(where: { $0.runId == runId }) {
                    dest = .conversation(dir: run.dir, session: run.sessionId, origin: run.origin)
                }
                await ssh.disconnect()
                path = NavigationPath()
                if let dest { path.append(dest) }
            }
        }
    }

    /// Build/point the home page's standing runs monitor at the current home
    /// server and start it — the source of truth for the "N 个在跑" row and the
    /// `RunListView` it opens. Called on appear and whenever the home profile
    /// changes. Reuses the existing monitor when it's already that server (its
    /// poll keeps running); otherwise stops the old one and starts a fresh monitor
    /// on the new server — the same reuse rule `AppStore.activateRuns` follows for
    /// the pill. No home server yet → tear the monitor down (the row disappears).
    /// The launch-time script check could not reach the Mac: owed, and paid
    /// the first time the page reads it (see the refresher's work).
    @State private var provisionPending = false

    /// Keep the Mac's scripts in lockstep with this build, then the model menu
    /// and the engine probe that ride the same connect. A fresh pave reloads
    /// the page; a check that could not reach the Mac is owed for later.
    @MainActor
    private func provision(home: ServerProfile, secret: String) async {
        paving = true
        let outcome = await ServerProvisioner().ensureCurrent(profile: home, secret: secret)
        if case .failed = outcome { provisionPending = true } else { provisionPending = false }
        // The model paper rides the same connect: once per launch/home
        // switch, then cached — a menu changes a few times a year.
        await ModelMenuStore.shared.refresh(profile: home, secret: secret)
        // What this Mac has (claude / codex / tmux) rides the same
        // connect. A profile whose default engine is not installed
        // there flips to the one that is — a codex-only Mac used to
        // greet its very first message with "claude not found"
        // (the first outside testers, 2026-10-13). Re-read the
        // profile: an edit may have landed while the probe ran.
        if let probe = await EngineStore.shared.refresh(profile: home, secret: secret),
           let better = probe.preferredBackend(over: home.backend),
           var fresh = store.profiles.first(where: { $0.id == home.id }) {
            fresh.backend = better
            store.upsert(fresh, secret: nil)
        }
        if case .paved = outcome { refresher.refresh() }
        paving = false
    }

    @MainActor
    private func provisionIfPending(home: ServerProfile, secret: String) async {
        guard provisionPending, !paving, store.homeProfile?.id == home.id else { return }
        provisionPending = false
        await provision(home: home, secret: secret)
    }

    private func syncRunningMonitor() {
        guard let home = store.homeProfile else {
            homeMonitor?.stop()
            homeMonitor = nil
            return
        }
        let secret = store.secret(for: home) ?? ""
        if let m = homeMonitor, m.serves(home, secret: secret) {
            m.start()                // idempotent; restarts the poll after a back-nav stop
            return
        }
        // Another server — or this one with its settings edited since.
        homeMonitor?.stop()
        let m = RunMonitor(profile: home, secret: secret)
        m.start()
        homeMonitor = m
    }

    /// Gear only — adding a server moved off the entry page (it lives in
    /// ServersListView's own +). iOS 26 wraps a toolbar Button in a circular
    /// "Liquid Glass" capsule by default; the entry page is all hairlines, so that
    /// heavy chip looked wrong. `.buttonStyle(.plain)` flattens the button, and on
    /// the 26 SDK `sharedBackgroundVisibility(.hidden)` — which lives on
    /// ToolbarContent, not View — hides the item's glass so the gear reads as a
    /// bare glyph. Guarded: on iOS 17–25 the plain button is already a bare icon.
    @ToolbarContentBuilder
    private var homeToolbar: some ToolbarContent {
        BarItem(.topBarLeading) {
            BarGlyph(systemImage: "gearshape", tint: .secondary, label: "Settings") { showingSettings = true }
        }
    }
}

/// Server management, moved off the entry page: the full list with add / edit /
/// delete / set-home. Pushed from the home footer's "Servers" line; value-based
/// profile links reuse the stack-level ProjectsView destination RootView
/// registers.
struct ServersListView: View {
    @EnvironmentObject var store: AppStore
    /// Observed so a fresh probe repaints the rows' engine captions.
    @ObservedObject private var engines = EngineStore.shared
    @State private var editing: ServerProfile?
    @State private var creatingNew = false
    /// Deleting a profile throws away hand-entered SSH config (host, port, auth) —
    /// and a full swipe used to fire it instantly, burying Edit behind it. Every
    /// delete now stages here and confirms; full-swipe is disabled.
    @State private var confirmDelete: ServerProfile?

    var body: some View {
        List {
            if store.profiles.isEmpty {
                ContentUnavailableViewCompat(
                    title: L.noServersTitle(),
                    systemImage: "server.rack",
                    description: L.noServersBody()
                )
                .listRowBackground(Color.clear)
                .onAppear {
                    // A brand-new user came here to add their FIRST server —
                    // hand them the form instead of a dark empty list.
                    creatingNew = true
                }
            }
            ForEach(store.profiles) { profile in
                NavigationLink(value: profile) {
                    ServerRowLabel(profile: profile,
                                   isHome: profile.id == store.homeProfile?.id,
                                   engines: engines.probe(for: profile))
                }
                .listRowBackground(Color.clear)
                // The ledger rule: no card, no tile — one hairline between rows,
                // the same 0x3A3631 the composer and the report cards draw with.
                .listRowSeparatorTint(Palette.hairline)
                .swipeActions(allowsFullSwipe: false) {
                    Button(L.delete(), role: .destructive) { confirmDelete = profile }
                    Button(L.edit()) { editing = profile }.tint(Palette.accent)
                }
                .contextMenu {
                    // Which server the home screen leads with (publications,
                    // composer, quick entries). The current pick is disabled
                    // rather than hidden so the state stays visible.
                    Button { store.setHomeProfile(profile) } label: {
                        Label(L.setAsHomeServer(), systemImage: "star")
                    }
                    .disabled(profile.id == store.homeProfile?.id)
                    Button { editing = profile } label: {
                        Label(L.editServer(), systemImage: "pencil")
                    }
                    Button(role: .destructive) { confirmDelete = profile } label: {
                        Label(L.deleteServer(), systemImage: "trash")
                    }
                }
            }
        }
        .pervioBackground()
        .pervioBar(L.serversTitle())
        .toolbar { addToolbar }
        .confirmationDialog(L.deleteServerTitle(),
                            isPresented: Binding(get: { confirmDelete != nil },
                                                 set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button(L.deleteServer(), role: .destructive) {
                if let p = confirmDelete { store.delete(p) }
                confirmDelete = nil
            }
        }
        .sheet(item: $editing) { profile in
            ProfileEditView(profile: profile).environmentObject(store)
        }
        .sheet(isPresented: $creatingNew) {
            ProfileEditView(profile: ServerProfile()).environmentObject(store)
        }
    }

    /// The ONE place a server can be added: the standard top-trailing '+'. Wears
    /// the same treatment as the entry page's gear — `.buttonStyle(.plain)` plus,
    /// on the iOS 26 SDK, `sharedBackgroundVisibility(.hidden)` — so the toolbar
    /// glyph reads as a bare mark instead of a "Liquid Glass" capsule floating
    /// over a page made of hairlines. The `Image` (not a `Label`) keeps the
    /// element's identifier "plus", which the XCUITest taps by name.
    @ToolbarContentBuilder
    private var addToolbar: some ToolbarContent {
        BarItem(.primaryAction) {
            // `Image` (not a `Label`) keeps the element's identifier "plus",
            // which the XCUITest taps by name.
            Button { creatingNew = true } label: {
                Image(systemName: "plus").font(.body.weight(.medium)).foregroundStyle(Palette.accent)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.addServer())
        }
    }
}

/// ONE server, drawn the way the entry page draws everything: no tile, no card —
/// the name on top, the address under it in the secondary colour, and the home
/// server marked with a THIN WORD rather than a gold star (a star is a rating on
/// every other screen in this app; "主服务器 / Home" says what it means).
///
/// Factored out of `ServersListView`'s row so a snapshot test can render the list
/// without a `List`: `ImageRenderer` rasterizes a List as empty (the same trap
/// the reader and home-page cases document). `ServersListView` uses exactly this
/// as its NavigationLink label, so what the snapshot pins is what the page draws.
struct ServerRowLabel: View {
    let profile: ServerProfile
    let isHome: Bool
    /// What the last connect found installed there; nil until the first one.
    var engines: EngineProbe? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(profile.name).font(.subheadline)
                if isHome {
                    Text(L.homeServerBadge())
                        .font(.caption2)
                        .foregroundStyle(Palette.accent)
                }
            }
            // `verbatim:`, NOT a plain literal. `Text("…\(profile.port)")` picks
            // the LocalizedStringKey initializer, which formats an Int through
            // the locale — so a server on port 2222 printed "…:2,222" (caught in
            // the first recorded snapshot of this row). A port is an address,
            // never a quantity.
            Text(verbatim: "\(profile.username)@\(profile.host):\(profile.port)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            // "claude ✓ · codex ✗ · tmux ✓" — the inventory a tester otherwise
            // discovers one failed message at a time.
            if let engines {
                Text(verbatim: engines.caption)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }
}

/// ContentUnavailableView is iOS 17+; this keeps us building on iOS 16.
struct ContentUnavailableViewCompat: View {
    let title: String; let systemImage: String; let description: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(description).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
        .listRowSeparator(.hidden)
    }
}
