import Foundation
import ActivityKit

/// Thin wrapper around ActivityKit that drives ONE Live Activity for the current
/// conversation's detached run. Start it when a run launches, update it as the run
/// streams tool calls, end it when the run finishes / is stopped. Every call is a
/// safe no-op when Live Activities are unavailable or disabled by the user, so the
/// caller never has to check.
///
/// Note: we update locally from the streaming turn, so while the app is fully
/// backgrounded the island freezes at its last state — that's the desired "I left,
/// it's still running" indicator — and reconciles when the app returns.
///
/// WHO ENDS THE CARD. Three layers, because the first two only work while the app
/// is alive and the interesting case is precisely when it isn't:
///
///  1. `end(finalStatus:)` — the app watched the run finish. Instant, exact.
///  2. `reconcile(runningRunIds:)` — the app came BACK and found a card whose run is
///     no longer running. Fixes it a poll after the user returns.
///  3. An ActivityKit PUSH from the Mac (`pervio-push liveactivity`). The only one
///     that works when the run finishes while iOS has the app suspended — which is
///     the whole point of Run mode, and was the "island counts forever" bug: every
///     `end()` above lives in this process, and this process is not running.
///     Layer 3 needs the activity's own push token, which is why `start` asks for
///     `pushType: .token` and pumps `pushTokenUpdates` into `onPushToken`.
///
/// And a backstop under all three: `staleDate`. If the push never lands (no APNs key
/// yet, phone offline, token expired) ActivityKit still flips the activity to
/// `.stale` after `staleAfter`, and the widget freezes its timer instead of counting
/// into next week.
@MainActor
final class RunLiveActivityController {
    private var activity: Activity<RunActivityAttributes>?
    private var step = 0
    /// Latest trail milestones, carried between `update`s so a status-only push
    /// doesn't reset the trail. `stepsTotal == 0` means an open-ended run.
    private var stepsDone = 0
    private var stepsTotal = 0
    /// Latest tool row (glyph + "Bash · npm test") and the current step's expected
    /// duration. Sticky for the same reason the trail is: a status-only update
    /// ("Running in background") must not blank the line that says what's running.
    private var toolIcon = ""
    private var toolLine = ""
    private var stepETA = 0
    /// The run this card tracks. Kept alongside `activity` because the token hooks
    /// are keyed by run id, and `end` needs it AFTER `activity` has been released.
    private var runId = ""
    /// Pumps `Activity.pushTokenUpdates` for the live card. Cancelled on end/restart
    /// so a replaced activity's loop can't publish a token for the new run.
    private var tokenTask: Task<Void, Never>?
    /// The last hex we published, so a redundant token update is not a round trip.
    private var publishedToken = ""

    /// How long a card may keep counting with no update before ActivityKit marks it
    /// stale. Long enough that a genuinely slow run isn't greyed out mid-work, short
    /// enough that a card orphaned by a failed push doesn't outlive the day.
    static let staleAfter: TimeInterval = 60 * 60
    static func staleDate(from start: Date) -> Date { start.addingTimeInterval(staleAfter) }

    /// Server-side seam, injected by the owner (ChatStore / WorkflowStore) because
    /// only they hold the profile + secret needed to reach the Mac. Left nil the
    /// card is purely local — the old behavior, and what previews/tests get.
    ///   * `onPushToken(runId, token)` — publish, so the Mac can end this card.
    ///   * `onActivityEnded(runId)`    — retire the token; it is dead.
    var onPushToken: ((String, Data) -> Void)?
    var onActivityEnded: ((String) -> Void)?

    /// Begin (or restart) the Live Activity for a run (or a workflow — same card,
    /// workflow-flavored strings). `startedAt` lets an attach show true elapsed.
    func start(project: String, preview: String, status: String, runId: String,
               detail: String = "", startedAt: Date = Date()) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Replace any existing activity immediately — no lingering "final frame".
        if let existing = activity {
            let oldId = self.runId
            activity = nil
            tokenTask?.cancel(); tokenTask = nil
            Task { await existing.end(nil, dismissalPolicy: .immediate) }
            if !oldId.isEmpty, oldId != runId { onActivityEnded?(oldId) }
        }
        // Also sweep any SYSTEM activity already tracking this id: re-attaching
        // creates a fresh store (and controller), and without this the same
        // workflow/run would get a duplicate card.
        for other in Activity<RunActivityAttributes>.activities
        where other.attributes.runId == runId && !runId.isEmpty {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
        step = 0
        stepsDone = 0
        stepsTotal = 0
        toolIcon = ""
        toolLine = ""
        stepETA = 0
        self.runId = runId
        publishedToken = ""
        let attributes = RunActivityAttributes(project: project, preview: preview,
                                               startedAt: startedAt, runId: runId)
        // `stepStartedAt` is stamped NOW, not from `startedAt`: the filling cell
        // shows the step being walked, and attaching to a two-hour-old workflow
        // must not hand it a cell that was "due" an hour and fifty minutes ago.
        let state = RunActivityAttributes.ContentState(status: status, detail: detail,
                                                       finished: false, step: 0,
                                                       stepsDone: 0, stepsTotal: 0, failed: false,
                                                       stepStartedAt: Self.nowEpoch())
        // `pushType: .token` is what mints the per-activity APNs token. Without it
        // there is simply no way to address this card from the server, and a run that
        // finishes while the app is suspended leaves it counting forever.
        //
        // The stale deadline runs from NOW, not from `startedAt`: attaching to an
        // already-running workflow passes its real start time (for a truthful elapsed
        // timer), and measuring staleness from that would hand a two-hour-old
        // workflow a card that is stale the instant it appears.
        activity = try? Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: Self.staleDate(from: Date())),
            pushType: .token)
        observeToken()
    }

    /// Pump the activity's push tokens to the server. The token is NOT available
    /// synchronously after `request` (ActivityKit mints it asynchronously) and it can
    /// ROTATE mid-activity, so this is an async sequence rather than a one-shot read.
    private func observeToken() {
        guard let activity, !runId.isEmpty, let sink = onPushToken else { return }
        let id = runId
        tokenTask?.cancel()
        tokenTask = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                // The controller is gone (its store was torn down) — stop pumping.
                guard !Task.isCancelled, let self else { return }
                let hex = PushTokenStore.hex(token)
                // Same token again (ActivityKit re-delivers on wake) — no round trip.
                guard self.runId == id, self.publishedToken != hex else { continue }
                self.publishedToken = hex
                sink(id, token)
            }
        }
    }

    /// End any Live Activity whose run is no longer running — e.g. it finished while
    /// the app was backgrounded, so no local code ended it (the "stuck island" bug).
    /// Called from the run poller with the set of still-running run ids. Uses the
    /// SYSTEM-wide activity list, so it works even after the originating ChatStore
    /// (and this controller instance) is gone.
    ///
    /// `onEnded` retires each swept card's push token; the owning controller is long
    /// gone by then, so the poller supplies it.
    static func reconcile(runningRunIds: Set<String>, onEnded: ((String) -> Void)? = nil) {
        let now = Date()
        for activity in Activity<RunActivityAttributes>.activities
        // 30s grace so a just-started activity isn't killed by a poll snapshot taken
        // microseconds before its run registered. Older ones whose run isn't running
        // (incl. pre-update cards with no runId) get cleared.
        where now.timeIntervalSince(activity.attributes.startedAt) > 30
            && !runningRunIds.contains(activity.attributes.runId) {
            let id = activity.attributes.runId
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            if !id.isEmpty { onEnded?(id) }
        }
    }

    /// Push a new status / latest-action line to the island, advancing the otter one
    /// walk-cycle frame and filling one more trail segment. Each update also pushes
    /// the stale deadline out, so an actively-streaming run never greys out — only a
    /// card nobody is updating any more does.
    ///
    /// `stepsDone`/`stepsTotal` describe the trail: a workflow passes its real
    /// completed/total steps (a literal N-segment path with a finish flag); an
    /// open-ended chat run passes neither (total stays 0 → an endless receding path,
    /// honest that we don't know how far but it's moving). They're sticky, so a
    /// status-only update (e.g. "Running in background") doesn't blank the trail.
    ///
    /// `toolIcon`/`toolLine` are the bottom row ("Bash · npm test", or a workflow's
    /// current step) and are sticky for the same reason. `stepETA` is how long the
    /// CALLER thinks the step now starting will take, in seconds — it only feeds
    /// the self-filling cell, and 0/nil means "no idea", which the island renders
    /// with its own conservative default rather than guessing here.
    ///
    /// Every update restamps `stepStartedAt`, because an update IS the step
    /// boundary: the previous cell is finished with, and the next one starts
    /// filling from zero.
    func update(status: String, detail: String, stepsDone: Int? = nil, stepsTotal: Int? = nil,
                toolIcon: String? = nil, toolLine: String? = nil, stepETA: Int? = nil) {
        guard let activity else { return }
        step += 1
        if let d = stepsDone { self.stepsDone = max(0, d) }
        if let t = stepsTotal { self.stepsTotal = max(0, t) }
        if let i = toolIcon { self.toolIcon = i }
        if let l = toolLine { self.toolLine = l }
        if let e = stepETA { self.stepETA = max(0, e) }
        let state = RunActivityAttributes.ContentState(status: status, detail: detail,
                                                       finished: false, step: step,
                                                       stepsDone: self.stepsDone,
                                                       stepsTotal: self.stepsTotal, failed: false,
                                                       toolIcon: self.toolIcon,
                                                       toolLine: self.toolLine,
                                                       stepETA: self.stepETA,
                                                       stepStartedAt: Self.nowEpoch())
        Task { await activity.update(.init(state: state,
                                           staleDate: Self.staleDate(from: Date()))) }
    }

    /// UNIX epoch seconds — the wire form `ContentState.stepStartedAt` uses (see
    /// there for why it isn't a `Date`).
    static func nowEpoch() -> Int { Int(Date().timeIntervalSince1970) }

    /// End the Live Activity (run finished / stopped / detached-and-gone). Leaves a
    /// brief "Done"/"Stopped" frame on screen, then dismisses. `failed` picks the
    /// terminal look: a clean finish plants a green flag at the trail's end and the
    /// otter rests; a failure slumps the (desaturated) otter by a rust cairn where
    /// the trail stopped. A completed run also fills the trail to its end.
    func end(finalStatus: String, failed: Bool = false) {
        guard let activity else { return }
        self.activity = nil
        tokenTask?.cancel(); tokenTask = nil
        let endedId = runId
        runId = ""
        publishedToken = ""
        // A clean finish tops the trail off; a failure leaves it where it stopped.
        // The tool row and the filling cell go away with the run: there is no
        // "currently doing" left to show, and a bar still creeping under a finished
        // card would be the stuck island all over again.
        let done = failed ? stepsDone : (stepsTotal > 0 ? stepsTotal : stepsDone)
        let state = RunActivityAttributes.ContentState(status: finalStatus, detail: "",
                                                       finished: true, step: step,
                                                       stepsDone: done, stepsTotal: stepsTotal,
                                                       failed: failed,
                                                       stepStartedAt: Self.nowEpoch())
        Task {
            await activity.end(.init(state: state, staleDate: nil),
                               dismissalPolicy: .after(Date().addingTimeInterval(3)))
        }
        // The token is dead the moment the activity is. Retiring it here stops the
        // Mac from later pushing at a card that no longer exists.
        if !endedId.isEmpty { onActivityEnded?(endedId) }
    }

    /// True while an activity is live — lets the caller avoid redundant starts.
    var isActive: Bool { activity != nil }
}
