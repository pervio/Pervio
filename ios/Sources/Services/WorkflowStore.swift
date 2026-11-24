import Foundation

/// Loads the list of a server's workflows for `WorkflowsView`. Holds its own SSH
/// connection (separate from any ChatStore / RunMonitor), connecting lazily on the
/// first load and reconnecting if the channel drops. The server is the source of
/// truth — we don't persist workflow ids on the phone.
@MainActor
final class WorkflowListStore: ObservableObject {
    @Published private(set) var items: [WorkflowSummary] = []
    @Published private(set) var schedules: [WorkflowSchedule] = []
    @Published private(set) var loading = false
    @Published private(set) var errorText: String?

    let profile: ServerProfile
    private let secret: String
    /// Held through the protocol (see SSHServiceProtocol.swift) so a test can make
    /// a delete FAIL; the default is the real connection.
    private let ssh: any WorkflowListSSHProtocol
    private var connected = false
    /// Per-schedule write chain: rapid enable/disable toggles run serialized in tap
    /// order so the server settles on the LAST intent, not on whichever detached
    /// request happened to finish last (#13).
    private var scheduleToggle: [String: Task<Void, Never>] = [:]

    init(profile: ServerProfile, secret: String,
         ssh: any WorkflowListSSHProtocol = SSHService()) {
        self.profile = profile
        self.secret = secret
        self.ssh = ssh
    }

    /// The load on the wire, and since when.
    private var inFlight: (task: Task<PageRefresher.Outcome, Never>, since: Date)?

    /// One load — the outcome is what the page's refresher goes by. It rides
    /// this store's one connection, so a second asked for while the first is
    /// still on the wire is not started beside it (the two would dial the
    /// connection twice): it waits for that one's answer. One that has been
    /// out for longer than any answer takes is cut loose — its connection is
    /// closed under it — so a socket the network dropped without a word
    /// cannot hold every later load.
    @discardableResult
    func load() async -> PageRefresher.Outcome {
        if let out = inFlight {
            if Date().timeIntervalSince(out.since) > 40 {
                connected = false
                await ssh.disconnect()
            }
            return await out.task.value
        }
        let task = Task { await self.loadNow() }
        inFlight = (task, Date())
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    private func loadNow() async -> PageRefresher.Outcome {
        loading = true
        defer { loading = false }
        var outcome = PageRefresher.Outcome.reached
        do {
            if !connected {
                try await ssh.connect(profile: profile, secret: secret)
                connected = true
            }
            items = try await ssh.listWorkflows(profile: profile)
            schedules = try await ssh.listSchedules(profile: profile)
            errorText = nil
        } catch {
            // Drop the (possibly half-open) connection so the next load reconnects.
            connected = false
            await ssh.disconnect()
            // (The page says it in its own line: MacProblemRow, from the outcome.)
            outcome = .of(error, "Couldn't load workflows.")
        }
        return outcome
    }

    // MARK: schedules

    func setScheduleEnabled(_ id: String, _ enabled: Bool) async {
        // Optimistic toggle (the switch answers instantly); reload reconciles.
        if let i = schedules.firstIndex(where: { $0.id == id }) {
            var rows = schedules
            rows[i] = optimistic(rows[i], enabled: enabled)
            schedules = rows
        }
        // Chain behind any in-flight write for this id. The optimistic update above and
        // this chain-setup run synchronously on the main actor before the first await,
        // so concurrent toggles enqueue in tap order — the last tap applies last.
        let prev = scheduleToggle[id]
        let mine = Task { [weak self] in
            await prev?.value
            await self?.applyScheduleEnabled(id, enabled)
        }
        scheduleToggle[id] = mine    // replaced by the next toggle for this id
        await mine.value
    }

    private func applyScheduleEnabled(_ id: String, _ enabled: Bool) async {
        do {
            if !connected {
                try await ssh.connect(profile: profile, secret: secret)
                connected = true
            }
            try await ssh.setScheduleEnabled(profile: profile, id: id, enabled: enabled)
        } catch {
            connected = false
            await ssh.disconnect()
            // Same trap as delete(): the reload below succeeds and clears
            // errorText, so the switch snaps back to the server's truth with no
            // word of why — and the schedule the user meant to turn off keeps
            // firing (and spending) every day.
            await reload(keepingError: pervioErrorText(error, "Couldn't update the schedule."))
            return
        }
        await load()
    }

    func removeSchedule(_ id: String) async {
        schedules.removeAll { $0.id == id }
        do {
            if !connected {
                try await ssh.connect(profile: profile, secret: secret)
                connected = true
            }
            try await ssh.removeSchedule(profile: profile, id: id)
        } catch {
            connected = false
            await ssh.disconnect()
            await reload(keepingError: pervioErrorText(error, "Couldn't remove the schedule."))
        }
    }

    /// Move a schedule to another daily time (2026-10-20). Optimistic like the
    /// toggle: the row shows the new time at once; a failed write reloads the
    /// truth and says why.
    func updateScheduleTime(_ id: String, _ hhmm: String) async {
        if let i = schedules.firstIndex(where: { $0.id == id }) {
            var rows = schedules
            rows[i] = optimistic(rows[i], time: hhmm)
            schedules = rows
        }
        do {
            if !connected {
                try await ssh.connect(profile: profile, secret: secret)
                connected = true
            }
            try await ssh.updateScheduleTime(profile: profile, id: id, time: hhmm)
            await load()                     // nextDue moved; let the row say when
        } catch {
            connected = false
            await ssh.disconnect()
            await reload(keepingError: pervioErrorText(error, "Couldn't change the time."))
        }
    }

    /// Fire a schedule now; returns the new run's wfId (nil + errorText on failure).
    func fireSchedule(_ id: String) async -> String? {
        do {
            if !connected {
                try await ssh.connect(profile: profile, secret: secret)
                connected = true
            }
            let wf = try await ssh.fireSchedule(profile: profile, id: id)
            await load()                     // the new run shows up in Recent
            return wf
        } catch {
            connected = false
            await ssh.disconnect()
            errorText = pervioErrorText(error, "Couldn't start the scheduled workflow.")
            return nil
        }
    }

    /// A locally-patched copy for the optimistic toggle (the model is decode-only).
    private func optimistic(_ s: WorkflowSchedule, enabled: Bool? = nil, time: String? = nil) -> WorkflowSchedule {
        let obj: [String: Any] = ["id": s.id, "name": s.name, "time": time ?? s.time,
                                  "enabled": enabled ?? s.enabled, "keepRuns": s.keepRuns,
                                  "nextDue": s.nextDue, "lastFiredAt": s.lastFiredAt,
                                  "lastWfId": s.lastWfId, "lastStatus": s.lastStatus,
                                  "lastError": s.lastError, "tz": s.tz]
        if let d = try? JSONSerialization.data(withJSONObject: obj),
           let row = try? JSONDecoder().decode(WorkflowSchedule.self, from: d) {
            return row
        }
        return s
    }

    /// The original spec of a past run — nil (with errorText set) on failure.
    /// Feeds "Run again": the editor opens pre-filled instead of starting over.
    func spec(_ wfId: String) async -> WorkflowSpec? {
        do {
            if !connected {
                try await ssh.connect(profile: profile, secret: secret)
                connected = true
            }
            return try await ssh.workflowSpec(profile: profile, wfId: wfId)
        } catch {
            connected = false
            await ssh.disconnect()
            errorText = pervioErrorText(error, "Couldn't load that workflow's spec.")
            return nil
        }
    }

    func delete(_ wfId: String) async {
        // Optimistic: drop it from the list immediately, then delete server-side.
        // Reload on failure so a row that didn't actually delete reappears.
        items.removeAll { $0.wfId == wfId }
        do {
            if !connected {
                try await ssh.connect(profile: profile, secret: secret)
                connected = true
            }
            try await ssh.deleteWorkflow(profile: profile, wfId: wfId)
        } catch {
            connected = false
            await ssh.disconnect()
            await reload(keepingError: pervioErrorText(error, "Couldn't delete the workflow."))
        }
    }

    /// Reconcile the list with the server after a write FAILED, without letting
    /// the reload erase why. `load()` clears `errorText` when it succeeds — so
    /// reloading after a failed delete used to leave the user with no message at
    /// all, and `pervio-orchestrate delete` can exit non-zero having already
    /// dropped the run from `list`: the row vanishes, nothing complains, and the
    /// workflow is still on the server. The failure that started this is the one
    /// worth showing, so it goes back on top of whatever the reload concluded.
    private func reload(keepingError message: String) async {
        await load()
        errorText = message
    }

    func disconnect() async {
        connected = false
        await ssh.disconnect()
    }
}

/// Drives ONE workflow: either starts a freshly-built spec or attaches to an
/// existing wfId, then streams its ledger via `tailWorkflow`. If the tail channel
/// drops mid-run it falls back to reconnect-and-poll so the UI still converges on
/// the terminal state. Mirrors the `RunMonitor` connect/lifecycle pattern.
@MainActor
final class WorkflowStore: ObservableObject {
    enum Mode {
        case start(WorkflowSpec)   // build + start a new workflow, then tail it
        case attach(String)        // attach to an existing wfId and tail it
    }

    @Published private(set) var ledger: WorkflowLedger?
    @Published private(set) var wfId: String?
    @Published private(set) var statusLine = "Connecting…"
    @Published private(set) var errorText: String?
    /// True once the workflow reaches a terminal state (done/failed).
    @Published private(set) var finished = false

    /// Watching = the monitor page is on screen AND the app is foreground — same
    /// split as ChatStore: watched completions get a haptic, unwatched a banner.
    /// Set by WorkflowMonitorView; plain vars (no UI depends on them directly).
    var isOnScreen = false
    var isForeground = true

    let profile: ServerProfile
    private let secret: String
    private let mode: Mode
    private let ssh = SSHService()
    private var task: Task<Void, Never>?
    private var launched = false
    /// The workflow's own island card (same otter card as runs, workflow-flavored
    /// strings). Started on the first running ledger, stepped per ledger emit,
    /// ended on the terminal one. Leaving the page keeps the card (that's the
    /// point); RunMonitor's reconcile clears it if it finishes while we're gone.
    private let liveActivity = RunLiveActivityController()
    private var activityLive = false

    init(profile: ServerProfile, secret: String, mode: Mode) {
        self.profile = profile
        self.secret = secret
        self.mode = mode
        // Same server-side end path as a Run's card (see ChatStore.wireLiveActivityPush):
        // publish this activity's push token so the Mac can dismiss the island even
        // after iOS suspends us. Fire-and-forget on both hops.
        let p = profile
        let s = secret
        liveActivity.onPushToken = { wfId, token in
            Task { await LiveActivityTokenStore().upload(token: token, runId: wfId,
                                                         profile: p, secret: s) }
        }
        liveActivity.onActivityEnded = { wfId in
            Task { await LiveActivityTokenStore().clear(runId: wfId, profile: p, secret: s) }
        }
    }

    /// Idempotent: safe to call from `.task` even if the view re-appears. After a
    /// stop() (pushing into a step's detail pops us off-screen and stops the tail),
    /// a re-appear RESUMES tailing the same wfId — the old `launched`-only guard
    /// made that a no-op, so coming back from a step detail froze the monitor
    /// mid-run. Never re-runs startWorkflow (that would launch a duplicate).
    func start() {
        guard task == nil else { return }
        if let id = wfId {
            task = Task { await self.resume(id: id) }
        } else if !launched {
            launched = true
            task = Task { await self.run() }
        }
    }

    /// Re-attach the tail after a stop(): fresh channel, same workflow.
    private func resume(id: String) async {
        do {
            await ssh.disconnect()          // stop() left the old channel half-closed
            try await ssh.connect(profile: profile, secret: secret)
            try await tailLoop(id: id)
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            statusLine = "Reconnecting…"
            await fallbackPoll()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        Task { await ssh.disconnect() }
    }

    private func run() async {
        do {
            try await ssh.connect(profile: profile, secret: secret)
            let id: String
            switch mode {
            case .start(let spec):
                statusLine = "Starting…"
                id = try await ssh.startWorkflow(profile: profile, spec: spec)
            case .attach(let existing):
                id = existing
            }
            wfId = id
            statusLine = "Running…"
            try await tailLoop(id: id)
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            errorText = pervioErrorText(error, "Workflow connection failed.")
            if wfId != nil {
                // The workflow exists and only the tail channel dropped — recover
                // by reconnecting and polling its ledger until it's terminal.
                statusLine = "Reconnecting…"
                await fallbackPoll()
            } else {
                // connect()/startWorkflow() failed: nothing was started, so there's
                // nothing to poll — surface the error rather than a false "reconnect".
                statusLine = "Error"
            }
        }
    }

    private func tailLoop(id: String) async throws {
        let stream = ssh.tailWorkflow(profile: profile, wfId: id)
        for try await led in stream {
            apply(led)
        }
        // The stream finishes when the workflow ends; grab one authoritative
        // snapshot in case the final ledger write landed after the last emit.
        if let led = try? await ssh.workflowStatus(profile: profile, wfId: id) {
            apply(led)
        } else if ledger?.isRunning ?? true {
            // 2026-08-22 audit: the stream can end CLEANLY (channel EOF) while
            // this final read fails — swallowing that left the spinner on a
            // finished run forever. Recover exactly like a dropped tail channel.
            await fallbackPoll()
        }
    }

    /// Last-resort path when the tail channel drops while the workflow is still
    /// running: reconnect and poll the ledger until it reaches a terminal state
    /// (or the view goes away and cancels us).
    private func fallbackPoll() async {
        guard let id = wfId else { return }
        while !Task.isCancelled {
            do {
                await ssh.disconnect()
                try await ssh.connect(profile: profile, secret: secret)
                if let led = try await ssh.workflowStatus(profile: profile, wfId: id) {
                    apply(led)
                    errorText = nil
                    if led.status == "done" || led.status == "failed" { return }
                    statusLine = "Running…"
                }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                statusLine = "Reconnecting…"
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    /// Run one ad-hoc shell line on the server over this store's SSH connection
    /// (the report's long-press action menus, e.g. pervio-feedback). The command
    /// is wrapped so stderr and the exit code come back in-band: a non-zero exit
    /// throws WITH the script's own message and is never blindly re-executed —
    /// only a transport-level failure (dead channel, which can't have run the
    /// command to completion) retries once on a fresh channel, same as spec().
    func runAdhoc(_ command: String) async throws -> String {
        let wrapped = "{ " + command + " ; } 2>&1; printf '\\n__PERVIO_RC=%d' $?"
        let out: String
        do {
            out = try await ssh.runCommand(wrapped)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            await ssh.disconnect()
            try await ssh.connect(profile: profile, secret: secret)
            out = try await ssh.runCommand(wrapped)
        }
        // Our marker is printed last, so a backwards search can't be fooled by
        // command output that happens to contain the same text.
        guard let r = out.range(of: "\n__PERVIO_RC=", options: .backwards) else {
            return out                        // marker lost (truncated output) — return raw
        }
        let body = String(out[..<r.lowerBound])
        let rc = Int(out[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        guard rc == 0 else {
            let msg = body.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "Pervio.action", code: rc, userInfo: [
                NSLocalizedDescriptionKey: (msg.isEmpty ? "command failed" : msg) + " (exit \(rc))"])
        }
        return body
    }

    /// The spec this workflow ran from (for the monitor's Run again button).
    /// Retries once on a fresh channel — the tail's connection may be long dead by
    /// the time the user comes back to re-run something.
    func spec() async -> WorkflowSpec? {
        guard let id = wfId else { return nil }
        if let s = try? await ssh.workflowSpec(profile: profile, wfId: id) { return s }
        await ssh.disconnect()
        try? await ssh.connect(profile: profile, secret: secret)
        return try? await ssh.workflowSpec(profile: profile, wfId: id)
    }

    private func apply(_ led: WorkflowLedger) {
        ledger = led
        switch led.status {
        case "done":   statusLine = "Done"
        case "failed": statusLine = "Failed"
        default:       statusLine = "Running…"
        }
        if led.isRunning, !finished {
            let total = led.steps.count
            let stepsDone = led.steps.filter { $0.isDone }.count
            if !activityLive, let id = (wfId ?? (led.wfId.isEmpty ? nil : led.wfId)) {
                activityLive = true
                liveActivity.start(project: led.name.isEmpty ? "Workflow" : led.name,
                                   preview: total > 0 ? "\(total)-step workflow" : "Workflow",
                                   status: "Running…", runId: id,
                                   startedAt: led.startedAt > 0 ? led.startedDate : Date())
            }
            if activityLive {
                // "tips 2/4" for a fan-out step mid-flight, plain id otherwise.
                let runningLabels = led.steps.filter { $0.isRunning }.map { s -> String in
                    if let t = s.fanoutTotal, t > 0 {
                        return "\(s.id) \((s.fanoutOk ?? 0) + (s.fanoutFail ?? 0))/\(t)"
                    }
                    return s.id
                }
                // The island's filling cell needs a duration for the step now
                // underway. The truest estimate available is this workflow's OWN
                // pace so far (elapsed ÷ steps finished) — better than any fixed
                // number, because a 6-step paper digest and a 6-step build differ
                // by an order of magnitude. Before the first step lands there is
                // no observation, so 0 hands it to the island's own default.
                // Clamped so one pathological step can't stretch the cell past
                // anything a person would watch.
                let running = runningLabels.joined(separator: ", ")
                let elapsed = led.startedAt > 0 ? Date().timeIntervalSince(led.startedDate) : 0
                let pace = stepsDone > 0 && elapsed > 0 ? elapsed / Double(stepsDone) : 0
                liveActivity.update(status: "\(stepsDone)/\(total) steps done",
                                    detail: running,
                                    stepsDone: stepsDone, stepsTotal: total,
                                    // A workflow step is a milestone, not a tool call,
                                    // so it wears the same pawprint the trail drops.
                                    toolIcon: IslandGlyph.step, toolLine: running,
                                    stepETA: pace > 0 ? Int(min(max(pace, 20), 900)) : 0)
            }
        }
        if (led.status == "done" || led.status == "failed") && !finished {
            finished = true
            liveActivity.end(finalStatus: led.status == "done" ? "Done" : "Failed",
                             failed: led.status != "done")
            activityLive = false
            // Same watched/banner split as chat turns and runs, deduped on the
            // wfId: watching the monitor → just a haptic (the claim also stops
            // RunMonitor's poll from following up with a banner); finished in the
            // narrow not-watching-but-still-streaming window → banner from here.
            // …and, like a detached run, pervio-orchestrate ALSO pushes this exact
            // outcome to the lock screen (both outcomes now, not just failure), so
            // `serverPushes` keeps the two from arriving together.
            let key = led.wfId.isEmpty ? wfId : led.wfId
            if isOnScreen && isForeground {
                CompletionNotifier.watched(dedupeKey: key)
            } else {
                let ok = led.status == "done"
                CompletionNotifier.taskFinished(
                    ok: ok,
                    project: led.name.isEmpty ? L.workflowFallbackName() : led.name,
                    summary: ok ? L.workflowStepsFinishedBody(led.steps.count)
                                : L.workflowFailedBody(),
                    dedupeKey: key,
                    serverPushes: true)
            }
        }
    }
}
