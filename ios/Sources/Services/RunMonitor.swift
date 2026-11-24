import Foundation

/// Polls `pervio-run list` on a server so the UI can show a live "running tasks"
/// indicator anywhere in that server's screens. Holds its own SSH connection
/// (separate from any ChatStore) and the server is the source of truth — we don't
/// persist run ids on the phone.
@MainActor
final class RunMonitor: ObservableObject {
    @Published private(set) var runs: [RunInfo] = []

    let profile: ServerProfile
    private let secret: String
    private let ssh = SSHService()
    private var task: Task<Void, Never>?
    private var connected = false
    /// Run ids seen running on the previous poll — diffed against the new poll to
    /// fire a "task finished" reminder when one goes running→done while the user is
    /// away. Starts empty so the first poll never pings about already-finished runs.
    private var prevRunning: Set<String> = []
    /// Same for workflows: they're detached server-side like runs, but only the
    /// (transient) monitor page ever watched them — one finishing while the user
    /// was anywhere else used to be completely silent.
    private var prevRunningWfs: Set<String> = []
    /// Latest workflow list from the same poll — the pill and the tasks sheet
    /// surface the running ones alongside runs.
    @Published private(set) var workflows: [WorkflowSummary] = []
    var runningWorkflows: [WorkflowSummary] { workflows.filter { $0.isRunning } }
    /// The records of the groups (双开) that own a running run — fetched with
    /// the poll only while such a run exists — so the tasks sheet lists a
    /// group as ONE row, like a workflow, instead of its member runs one by
    /// one under the raw hidden header (the user, 2026-10-14).
    @Published private(set) var groups: [ChatGroup] = []
    var runningGroups: [ChatGroup] {
        let live = Set(running.compactMap { $0.group }.filter { !$0.isEmpty })
        return groups.filter { live.contains($0.id) }
    }
    /// What the sheet lists under the groups: every conversation whose run is
    /// not already represented by a group row (a run whose group record is
    /// gone still shows, so nothing counted is unreachable).
    var conversationsOutsideGroups: [RunInfo] {
        let known = Set(groups.map(\.id))
        return conversations.filter { r in
            guard let g = r.group, !g.isEmpty else { return true }
            return !known.contains(g)
        }
    }

    init(profile: ServerProfile, secret: String) {
        self.profile = profile
        self.secret = secret
    }

    /// Preview / test seam (additive, default-off): a monitor pre-seeded with the
    /// runs and workflows a poll would have produced, WITHOUT ever opening a
    /// connection or starting the poll loop (`start()` is not called, so `task`
    /// stays nil). The app never uses this — it always constructs the two-arg
    /// initializer and starts polling — but it lets a snapshot or a unit test
    /// exercise the derived views (`conversations`, `running`, `runningWorkflows`)
    /// off fixed data, the same way HomeRecentModel(previewItems:) does for the
    /// recents block. `secret` is empty because nothing here touches the wire.
    init(previewProfile: ServerProfile, runs: [RunInfo] = [], workflows: [WorkflowSummary] = [],
         groups: [ChatGroup] = []) {
        self.profile = previewProfile
        self.secret = ""
        self.runs = runs
        self.workflows = workflows
        self.groups = groups
    }

    /// One entry per CONVERSATION (sessionId), not per turn: the running run if
    /// the conversation has one, else its most recent run. A conversation only
    /// ever has one run executing at a time, so this is the natural "one task per
    /// conversation" view rather than a row for every reply.
    var conversations: [RunInfo] {
        var best: [String: RunInfo] = [:]
        for r in runs {
            let key = r.sessionId.isEmpty ? r.runId : r.sessionId
            if let cur = best[key] {
                let prefer = (r.isRunning && !cur.isRunning)
                    || (r.isRunning == cur.isRunning && r.started > cur.started)
                if prefer { best[key] = r }
            } else {
                best[key] = r
            }
        }
        return best.values.sorted { $0.started > $1.started }
    }

    /// Conversations with a task currently executing.
    var running: [RunInfo] { conversations.filter { $0.isRunning } }
    /// Runs blocked on this phone's Allow/Deny (2026-10-19) — the pill says so.
    var waiting: [RunInfo] { running.filter { $0.waiting } }
    /// Living runs whose engine has a background task of its own going
    /// (answered, process alive, task pending) — the pill names them (2026-10-20).
    var inBackground: [RunInfo] { conversations.filter { $0.state == "running" && !$0.shownBackground.isEmpty } }

    /// What the pill COUNTS: a group's member runs are one task, not N — the
    /// user watched one group round show up as three separate runs (2026-10-12).
    var runningUnits: Int {
        var groups = Set<String>()
        var plain = 0
        for r in running {
            if let g = r.group, !g.isEmpty { groups.insert(g) } else { plain += 1 }
        }
        return plain + groups.count
    }

    /// Whether the poll goes on after this failure: yes for a Mac that could
    /// not be reached, no for one that refused — a rejected key or password, a
    /// host key that is not the pinned one (the same line every page's own
    /// reads draw, PageRefresher.Outcome). Asked again every few seconds, as
    /// it was for as long as a server page stayed open, a refusal is the
    /// pattern an address gets banned for, and waiting cures none of it: the
    /// poll stops there, and starts again when a page of this server is next
    /// opened.
    static func keepsPolling(after error: Error) -> Bool {
        if case .refused = PageRefresher.Outcome.of(error, "runs poll") { return false }
        return true
    }

    /// This monitor's connection is the one the server's settings describe
    /// NOW. One built before they were edited (a corrected username, another
    /// key) carries the old ones for good — it has to be replaced, or the row
    /// it feeds stays dead until the app is quit.
    func serves(_ profile: ServerProfile, secret: String) -> Bool {
        Dial(self.profile) == Dial(profile) && self.secret == secret
    }

    /// What the poll's connection is made of: which server, where it is
    /// dialed, as whom, through which machines, and where the Mac's scripts
    /// are. Named one by one on purpose —
    ///   * not the working directory: a conversation hands on its own copy of
    ///     the profile with the directory replaced (ChatStore), and that is
    ///     the same server — a monitor replaced for it would blank the pill
    ///     at every step in and out of a chat;
    ///   * not the knobs a conversation turns (model, effort, mode, engine).
    /// A connection setting added to ServerProfile later belongs here too.
    private struct Dial: Equatable {
        let id: UUID
        let host: String
        let port: Int
        let username: String
        let authKind: ServerProfile.AuthKind
        let pinnedHostKey: String
        let route: [JumpHop]
        let launcherDir: String
        init(_ p: ServerProfile) {
            id = p.id; host = p.host; port = p.port; username = p.username
            authKind = p.authKind; pinnedHostKey = p.pinnedHostKey
            route = p.route; launcherDir = p.launcherDir
        }
    }

    /// The standing poll is going (it is not after `stop()`, nor after a refusal).
    var isPolling: Bool { task != nil }
    /// Seconds between polls: while something runs, and while nothing does.
    var pace: (busy: TimeInterval, idle: TimeInterval) = (4, 15)

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let goOn = await self?.poll() ?? false
                if !goOn {
                    if !Task.isCancelled { self?.task = nil }     // refused; a stop() has already put its own nil there
                    return
                }
                // Back off when nothing is running: poll briskly (4s) while a task
                // is live so the pill stays responsive, but idle slowly (15s) to
                // save battery/data when there's nothing to watch.
                let busy = (self?.running.isEmpty == false) || (self?.runningWorkflows.isEmpty == false)
                let wait = busy ? (self?.pace.busy ?? 4) : (self?.pace.idle ?? 15)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        connected = false
        Task { await ssh.disconnect() }
    }

    /// Force an immediate refresh (e.g. right after starting a run).
    func refresh() { Task { await poll() } }

    /// Stop a run from the list, then refresh so its state updates promptly.
    func stopRun(_ runId: String) {
        Task {
            try? await ssh.stopRun(profile: profile, runId: runId)
            await poll()
        }
    }

    /// One poll. False when the Mac refused it — the standing poll ends there.
    @discardableResult
    private func poll() async -> Bool {
        do {
            if !connected {
                try await ssh.connect(profile: profile, secret: secret)
                connected = true
            }
            runs = try await ssh.listRuns(profile: profile)
            let nowRunning = Set(runs.filter { $0.isRunning }.map { $0.runId })
            // A run that was running last poll and isn't now just finished — ping the
            // user (this is the path that catches a task the user left running and
            // walked away from, while the app is still alive to poll). Deduped on the
            // runId so a conversation the user is actively tailing doesn't double-fire.
            // `serverPushes`: pervio-run's own wrapper already pushed this exact
            // completion to the lock screen. That push is also the one that lands
            // when the transition happened while iOS had us suspended — which is
            // most of the time, since this diff is only noticed on the poll AFTER
            // the app comes back. Bannering here too is the double, so we defer.
            for runId in prevRunning.subtracting(nowRunning) {
                guard let info = runs.first(where: { $0.runId == runId }) else { continue }
                CompletionNotifier.taskFinished(ok: !info.isFailed,
                                                project: (info.dir as NSString).lastPathComponent,
                                                summary: info.preview, dedupeKey: runId,
                                                serverPushes: true)
            }
            prevRunning = nowRunning
            // The groups behind the running runs, by record — only asked for
            // while one exists; `try?` so a server too old for the verb changes
            // nothing (its runs then list plainly, as before).
            let liveGroupIds = Set(runs.filter { $0.isRunning }.compactMap { $0.group }.filter { !$0.isEmpty })
            if liveGroupIds.isEmpty {
                if !groups.isEmpty { groups = [] }
            } else if let gs = try? await ssh.groupList(profile: profile, dir: "") {
                groups = gs.filter { liveGroupIds.contains($0.id) }
            }
            // Workflows get the same running→gone completion diff as runs. `try?`
            // so a server without pervio-orchestrate (or a transient hiccup) never
            // disturbs the runs path above; skipping a round keeps prevRunningWfs
            // intact, so nothing is missed — just delivered a poll later. A deleted
            // workflow simply vanishes from the list → `continue`, no banner.
            var liveWfIds = prevRunningWfs
            if let wfs = try? await ssh.listWorkflows(profile: profile) {
                let nowWfs = Set(wfs.filter { $0.isRunning }.map { $0.wfId })
                for id in prevRunningWfs.subtracting(nowWfs) {
                    guard let w = wfs.first(where: { $0.wfId == id }) else { continue }
                    let ok = w.status == "done"
                    CompletionNotifier.taskFinished(
                        ok: ok,
                        project: w.name.isEmpty ? L.workflowFallbackName() : w.name,
                        summary: ok ? L.workflowFinishedBody() : L.workflowFailedBody(),
                        dedupeKey: id,
                        serverPushes: true)   // pervio-orchestrate pushes both outcomes
                }
                prevRunningWfs = nowWfs
                workflows = wfs
                liveWfIds = nowWfs
            }
            // Auto-clear stuck Live Activities: end any whose run is no longer
            // running (it may have finished while the app was backgrounded, where
            // no local code was left to end it). Workflow cards share the same
            // attributes type, so reconcile on the UNION — and on a transient
            // workflow-list failure we keep the previous wf set rather than
            // killing a live card on a blip.
            //
            // This only fires once the user comes BACK (it's a poll from a live app);
            // the server-side liveactivity push is what ends a card while we're gone.
            // Retire the swept cards' tokens too — the controller that started them
            // is long gone, so this poller is the only one left holding a connection.
            let p = profile
            let s = secret
            RunLiveActivityController.reconcile(runningRunIds: nowRunning.union(liveWfIds)) { runId in
                Task { await LiveActivityTokenStore().clear(runId: runId, profile: p, secret: s) }
            }
            return true
        } catch {
            connected = false
            await ssh.disconnect()
            return Self.keepsPolling(after: error)
        }
    }
}
