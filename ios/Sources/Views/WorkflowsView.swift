import SwiftUI
import UIKit

/// Which of this server's schedules actually print a home card.
///
/// `schedule list` carries no spec, so the Workflows screen cannot tell a daily
/// job that publishes from one that just runs — and a badge that guessed would
/// be worse than none. `archives list` knows: it reports every publication and
/// joins the ONE schedule that publishes into it (absent when zero or several
/// do, so an ambiguous join never pins the wrong row).
///
/// Its own one-shot connection, like the market state and the home cards. The
/// loader is a closure rather than a protocol because this object needs exactly
/// one call — the seam exists so a test can hand it publications without a
/// socket.
@MainActor
final class SchedulePublicationIndex: ObservableObject {
    @Published private(set) var byScheduleId: [String: ArchivePublication] = [:]

    private let load: () async throws -> [ArchivePublication]
    /// One load at a time: this screen asks on `.task`, on `.onAppear` and on
    /// pull-to-refresh, and the first two BOTH fire when it opens — without
    /// this, every visit opened two SSH connections to answer the same question.
    private var inFlight = false

    init(load: @escaping () async throws -> [ArchivePublication]) {
        self.load = load
    }

    convenience init(profile: ServerProfile, secret: String) {
        self.init {
            let ssh = SSHService()
            do {
                try await ssh.connect(profile: profile, secret: secret)
                let pubs = try await ssh.listArchives(profile: profile)
                await ssh.disconnect()
                return pubs
            } catch {
                await ssh.disconnect()
                throw error
            }
        }
    }

    /// A failed load keeps whatever was known. The badge is decoration on rows
    /// that keep working either way; flickering it off on every flaky refresh
    /// teaches the user it means nothing.
    func refresh() async {
        if inFlight { return }
        inFlight = true
        defer { inFlight = false }
        guard let pubs = try? await load() else { return }
        var out: [String: ArchivePublication] = [:]
        for p in pubs {
            // No join (zero or several schedules publish there) → no badge. An
            // empty id indexed as-is would answer "yes" for every row whose
            // schedule id the server couldn't tell us either.
            guard let sid = p.scheduleId, !sid.isEmpty else { continue }
            out[sid] = p
        }
        byScheduleId = out
    }

    func publication(for scheduleId: String) -> ArchivePublication? { byScheduleId[scheduleId] }

    func publishes(_ scheduleId: String) -> Bool { publication(for: scheduleId) != nil }
}

/// Hub for a server's multi-step workflows: start a new one, or re-open a recent
/// run to watch its progress / outputs. Pushed from `ProjectsView`.
struct WorkflowsView: View {
    let profile: ServerProfile
    let secret: String
    @StateObject private var store: WorkflowListStore
    @StateObject private var refresher = PageRefresher()
    @StateObject private var publications: SchedulePublicationIndex
    @State private var rerunSeed: RerunSeed?
    @State private var attachTarget: AttachTarget?

    /// Hashable wrapper so navigationDestination(item:) can drive the push; a fresh
    /// UUID per fetch means re-running the same workflow twice still navigates.
    private struct RerunSeed: Hashable {
        let id = UUID()
        let spec: WorkflowSpec
        static func == (l: Self, r: Self) -> Bool { l.id == r.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    /// Same idiom for pushing a run's monitor (a schedule's last/just-fired run).
    private struct AttachTarget: Hashable {
        let id = UUID()
        let wfId: String
        let name: String
        static func == (l: Self, r: Self) -> Bool { l.id == r.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    /// Deletion is irreversible (the run dir AND its conversations go) and used
    /// to fire straight off a full swipe — days of digest runs silently vanished
    /// to accidental swipes while browsing. Now every delete confirms first.
    /// One state + ONE dialog for both kinds: two `.confirmationDialog`s hung on
    /// the same List presented erratically (wrong text/anchor for the swiped row).
    ///
    /// Internal (not private) because the sentence the user reads before the
    /// irreversible tap is worth a test — doubly so now that a subscription can
    /// be deleted from a BUTTON sitting in the row, which is far easier to hit
    /// by accident than a deliberate swipe.
    enum PendingDelete: Equatable {
        case run(String)
        /// `publishes` = this subscription prints a home card, so deleting it
        /// also ends the morning card (see `prompt`).
        case schedule(id: String, publishes: Bool)

        var prompt: (title: String, confirm: String) {
            switch self {
            case .run:
                return (L.deleteRunTitle(), L.deleteRunConfirm())
            case .schedule(_, let publishes):
                return publishes
                    ? (L.deleteSubscriptionTitle(), L.deleteSubscriptionConfirm())
                    : (L.deleteScheduleTitle(), L.deleteScheduleConfirm())
            }
        }
    }
    @State private var pendingDelete: PendingDelete?
    /// The schedule whose daily time is being changed (the wheel sheet).
    @State private var editingTime: WorkflowSchedule?

    init(profile: ServerProfile, secret: String) {
        self.profile = profile
        self.secret = secret
        _store = StateObject(wrappedValue: WorkflowListStore(profile: profile, secret: secret))
        _publications = StateObject(wrappedValue:
            SchedulePublicationIndex(profile: profile, secret: secret))
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    WorkflowEditorView(profile: profile, secret: secret)
                } label: {
                    Label("New workflow", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
                .listRowBackground(Palette.surface)

                NavigationLink {
                    WorkflowMarketView(profile: profile, secret: secret)
                } label: {
                    Label("Browse the market", systemImage: "square.grid.2x2.fill")
                }
                .listRowBackground(Palette.surface)
            } footer: {
                Text("Chain Claude Code and Codex across steps — one agent's output feeds the next, independent steps run in parallel. Start from a template in the market or build your own.")
            }

            if !store.schedules.isEmpty {
                Section {
                    ForEach(store.schedules) { s in
                        // The row-wide tap gesture moved INSIDE, onto the text
                        // block: the row now carries a destructive button, and a
                        // parent gesture over a button is exactly the ambiguity
                        // that ends with "I tapped Delete and it opened a run".
                        scheduleRow(s)
                            .listRowBackground(Palette.surface)
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Delete", role: .destructive) { stageDelete(s) }
                            }
                            .swipeActions(edge: .leading) {
                                Button { runNow(s) } label: {
                                    Label("Run now", systemImage: "play.fill")
                                }
                                .tint(.green)
                            }
                            .contextMenu {
                                Button { runNow(s) } label: {
                                    Label("Run now", systemImage: "play.fill")
                                }
                                Button { editingTime = s } label: {
                                    Label(L.changeTime(), systemImage: "clock")
                                }
                                Button(role: .destructive) {
                                    stageDelete(s)
                                } label: {
                                    Label(deleteVerb(s), systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text("Scheduled")
                } footer: {
                    Text("The server fires these itself — your phone doesn't need to be on. Times are the server's clock\(serverTZHint). Tap a schedule's name for its latest run; the Delete button on the row (or a swipe) stops it, with a confirmation first.")
                }
            }

            Section {
                if refresher.problem != nil {
                    MacProblemRow(problem: refresher.problem, retrying: refresher.retrying,
                                  profile: profile, secret: secret) { refresher.refresh() }
                        .listRowBackground(Palette.surface)
                } else if store.loading && store.items.isEmpty {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                        .listRowBackground(Palette.surface)
                } else if let err = store.errorText {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .listRowBackground(Palette.surface)
                } else if store.items.isEmpty {
                    Text("No workflows yet.").foregroundStyle(.secondary)
                        .listRowBackground(Palette.surface)
                }
                ForEach(store.items) { w in
                    NavigationLink {
                        WorkflowMonitorView(profile: profile, secret: secret, wfId: w.wfId, name: w.name)
                    } label: {
                        summaryRow(w)
                    }
                    .listRowBackground(Palette.surface)
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) {
                            pendingDelete = .run(w.wfId)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button { rerun(w.wfId) } label: {
                            Label("Run again", systemImage: "arrow.clockwise")
                        }
                        .tint(.green)
                    }
                    .contextMenu {
                        Button { rerun(w.wfId) } label: {
                            Label("Run again", systemImage: "arrow.clockwise")
                        }
                        Button { exportSpec(w.wfId) } label: {
                            Label("Copy spec JSON", systemImage: "doc.on.doc")
                        }
                    }
                }
            } header: {
                Text("Recent")
            } footer: {
                if !store.items.isEmpty {
                    Text("Swipe a row right (or long-press) to run it again — the editor opens pre-filled with that run's steps.")
                }
            }
        }
        .pervioBackground()
        .confirmationDialog(pendingDelete?.prompt.title ?? "",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(pendingDelete?.prompt.confirm ?? L.delete(), role: .destructive) {
                switch pendingDelete {
                case .run(let id): Task { await store.delete(id) }
                case .schedule(let id, _): Task { await store.removeSchedule(id) }
                case nil: break
                }
                pendingDelete = nil
            }
        }
        .pervioBar("Workflows")
        .sheet(item: $editingTime) { s in
            ScheduleTimeSheet(schedule: s) { hhmm in
                Task { await store.updateScheduleTime(s.id, hhmm) }
            }
            .presentationDetents([.height(360)])
        }
        // Opened, pulled, come back to (from the editor / market: a schedule
        // just saved, a run just started), the app back in front — and again by
        // itself while the Mac cannot be reached (PageRefresher).
        .readsTheMac(refresher) {
            let outcome = await store.load()
            if outcome == .reached { await publications.refresh() }
            return outcome
        }
        .onDisappear { Task { await store.disconnect() } }
        .navigationDestination(item: $rerunSeed) { seed in
            WorkflowEditorView(profile: profile, secret: secret, seed: seed.spec)
        }
        .navigationDestination(item: $attachTarget) { t in
            WorkflowMonitorView(profile: profile, secret: secret, wfId: t.wfId, name: t.name)
        }
    }

    /// Stage a schedule's deletion — from the row's own Delete button, the
    /// swipe, or the long-press menu alike. ONE funnel, so a visible entry can
    /// never become the path that skips the confirmation, and all three carry
    /// whether this subscription prints a home card (the dialog says so).
    private func stageDelete(_ s: WorkflowSchedule) {
        pendingDelete = .schedule(id: s.id, publishes: publications.publishes(s.id))
    }

    private func deleteVerb(_ s: WorkflowSchedule) -> String {
        publications.publishes(s.id) ? L.deleteSubscriptionConfirm() : L.deleteScheduleConfirm()
    }

    /// Fetch the past run's spec and open the editor pre-filled with it.
    private func rerun(_ wfId: String) {
        Task {
            if let spec = await store.spec(wfId) {
                rerunSeed = RerunSeed(spec: spec)
            }
        }
    }

    /// Copy the run's spec as the share JSON (dir reset to "~") — paste-able into
    /// another phone's market Import.
    private func exportSpec(_ wfId: String) {
        Task {
            if let spec = await store.spec(wfId) {
                UIPasteboard.general.string =
                    WorkflowMarketItem.wrapping(spec: spec).exportJSON()
                Haptics.tick()
            }
        }
    }

    // MARK: schedules

    private func openLastRun(_ s: WorkflowSchedule) {
        guard !s.lastWfId.isEmpty else { return }
        attachTarget = AttachTarget(wfId: s.lastWfId, name: s.name)
    }

    private func runNow(_ s: WorkflowSchedule) {
        Task {
            if let wf = await store.fireSchedule(s.id) {
                Haptics.tick()
                attachTarget = AttachTarget(wfId: wf, name: s.name)
            }
        }
    }

    /// "(server +0800)" when the server's UTC offset differs from the phone's —
    /// silent when they match (the common same-desk case).
    private var serverTZHint: String {
        guard let tz = store.schedules.first?.tz, !tz.isEmpty else { return "" }
        let f = DateFormatter()
        f.dateFormat = "Z"
        return f.string(from: Date()) == tz ? "" : " (server \(tz))"
    }

    private func scheduleRow(_ s: WorkflowSchedule) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.title3)
                .foregroundStyle(s.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(s.name.isEmpty ? "Scheduled workflow" : s.name).font(.headline)
                        // Says which of these daily jobs is the one printing a
                        // home card — the same 刊物 word as the market shelf it
                        // came from.
                        if publications.publishes(s.id) { PublicationChip() }
                    }
                    Text(scheduleSubtitle(s)).font(.caption).foregroundStyle(.secondary)
                    if !s.lastError.isEmpty {
                        Text(s.lastError).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { openLastRun(s) }
                // U3: the delete used to be a swipe (or a long-press) and
                // nothing on screen said so — an unwanted subscription kept
                // firing every morning because there was no visible way out.
                // Still a two-step: this only stages the confirmation.
                HStack(spacing: 8) {
                    // Visible, like Delete (U3): the time is the one thing a
                    // subscription needs changing most, so it is not a gesture.
                    Button { editingTime = s } label: {
                        Label(L.changeTime(), systemImage: "clock")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("schedule-change-time")
                    Button(role: .destructive) { stageDelete(s) } label: {
                        Label(deleteVerb(s), systemImage: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
                }
                .padding(.top, 3)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { s.enabled },
                set: { on in Task { await store.setScheduleEnabled(s.id, on) } }
            ))
            .labelsHidden()
        }
    }

    private func scheduleSubtitle(_ s: WorkflowSchedule) -> String {
        var bits: [String] = ["Daily \(s.time)"]
        if !s.enabled {
            bits.append("paused")
        } else if let next = s.nextDueDate {
            bits.append("next \(next.formatted(.relative(presentation: .named)))")
        }
        switch s.lastStatus {
        case "done":
            if let d = s.lastFiredDate {
                bits.append("last ✓ \(d.formatted(.relative(presentation: .named)))")
            } else {
                bits.append("last ✓")
            }
        case "failed": bits.append("last ✗ failed")
        case "running": bits.append("running now")
        default: break
        }
        return bits.joined(separator: " · ")
    }

    private func summaryRow(_ w: WorkflowSummary) -> some View {
        HStack(spacing: 12) {
            WorkflowStatusBadge(status: w.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(w.name.isEmpty ? "Untitled workflow" : w.name).font(.headline)
                HStack(spacing: 4) {
                    if w.isScheduled {
                        Image(systemName: "calendar.badge.clock")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(w.startedDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if w.isRunning { ProgressView() }
        }
    }
}


/// "HH:MM" (the server's own spelling) ↔ a Date on today, for the wheel.
enum ScheduleTime {
    static func date(from hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = parts.count == 2 ? parts[0] : 6
        c.minute = parts.count == 2 ? parts[1] : 30
        return Calendar.current.date(from: c) ?? Date()
    }
    static func hhmm(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// The time wheel for one schedule (2026-10-20): pick, Save — the Mac moves the
/// same record (its id stays) and re-arms its clock.
struct ScheduleTimeSheet: View {
    let schedule: WorkflowSchedule
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Date

    init(schedule: WorkflowSchedule, onSave: @escaping (String) -> Void) {
        self.schedule = schedule
        self.onSave = onSave
        _picked = State(initialValue: ScheduleTime.date(from: schedule.time))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(schedule.name.isEmpty ? "Scheduled workflow" : schedule.name)
                    .font(.headline).lineLimit(1)
                DatePicker("", selection: $picked, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .accessibilityIdentifier("schedule-time-wheel")
                Text(L.changeTimeNote(schedule.tz))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 8)
            .pervioBackground()
            .pervioBar(L.changeTime(), back: false)
            .toolbar {
                BarItem(.navigationBarLeading) { BarWord(text: L.cancel()) { dismiss() } }
                BarItem(.navigationBarTrailing) {
                    BarWord(text: L.save(), weight: .semibold) {
                        onSave(ScheduleTime.hhmm(from: picked))
                        Haptics.tick()
                        dismiss()
                    }
                    .accessibilityIdentifier("schedule-time-save")
                }
            }
        }
    }
}
