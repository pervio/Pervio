import SwiftUI

/// Attaches the floating "running tasks" pill to a screen: a slim capsule pinned
/// just below the nav bar (so it never covers nav-bar controls like the chat's
/// model selector), plus the sheet it opens. Apply with `.runPill()` on each
/// screen inside a server (projects / sessions / chat / terminal) — a single
/// NavigationStack-level inset didn't propagate to pushed views.
private struct RunPillContainer: ViewModifier {
    @EnvironmentObject private var store: AppStore
    let enabled: Bool
    @State private var showRunList = false

    func body(content: Content) -> some View {
        content
            // An OVERLAY, not a top safe-area inset: as an inset the pill took
            // ~38pt of layout, so every time a task started or finished the
            // whole transcript shifted by that much under the reader (measured
            // 2026-10-15: every row −38pt the moment a reply landed). Floating
            // over the first rows costs nothing — they are the oldest on screen.
            .overlay(alignment: .top) {
                if enabled, let m = store.activeMonitor {
                    RunPillBar(monitor: m) { showRunList = true }
                        .frame(maxWidth: .infinity)            // center the capsule
                        .animation(.easeOut(duration: 0.25),
                                   value: m.runningUnits + m.runningWorkflows.count)
                }
            }
            .sheet(isPresented: $showRunList) {
                if let m = store.activeMonitor {
                    RunListView(monitor: m, secret: store.secret(for: m.profile) ?? "")
                        .environmentObject(store)
                }
            }
    }
}

extension View {
    /// Show the global running-tasks pill on this screen. `enabled: false`
    /// suppresses it (used for the ChatView already inside the tasks sheet).
    func runPill(enabled: Bool = true) -> some View {
        modifier(RunPillContainer(enabled: enabled))
    }
}

/// Slim floating capsule shown at the top of every screen inside a server while
/// background runs are live. Tapping it opens the running-tasks list. Renders
/// nothing (zero height) when nothing is running, so it never steals space.
struct RunPillBar: View {
    @ObservedObject var monitor: RunMonitor
    var onTap: () -> Void

    var body: some View {
        let runCount = monitor.runningUnits
        let wfCount = monitor.runningWorkflows.count
        let bg = monitor.inBackground
        let active = runCount + wfCount + (runCount == 0 ? bg.count : 0)
        if active > 0 {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    OtterRunnerView(taskCount: active)
                    // Label by the actually-running run's agent (not the base profile,
                    // which is always Claude) so a Codex run reads "Codex is working";
                    // a lone workflow reads as itself.
                    // A run waiting for this phone's Allow/Deny says so before
                    // anything else: that one needs the person, the rest don't.
                    Text(monitor.waiting.first.map { L.runWaitingApproval($0.agent.tag) }
                         ?? (runCount == 0 && wfCount == 0 && !bg.isEmpty
                             ? L.bgPill(bg[0].agent.tag, BackgroundClock.elapsed(since: bg[0].shownBackground[0].startedAt > 0
                                 ? Date(timeIntervalSince1970: TimeInterval(bg[0].shownBackground[0].startedAt)) : Date()))
                             : nil)
                         ?? (active > 1 ? "\(active) tasks running"
                             : wfCount == 1 ? "Workflow running"
                             : !monitor.runningGroups.isEmpty ? L.groupPillRunning()
                             : "\(monitor.running.first?.agent.tag ?? "Claude") is working"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Palette.surface2, in: Capsule())
                .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Pervio's own running otter for the running pill: 8 hand-drawn full-colour otter
/// frames (our mascot) cycled as a frame animation,
/// running faster as more tasks pile up.
/// Rendered in original colour (not tinted) so the brown/cream otter shows. In-app
/// SwiftUI has a real render loop, so this genuinely animates — frames are swapped
/// (not cross-faded), so there's no flicker.
struct OtterRunnerView: View {
    var taskCount: Int = 1
    /// Frames/sec: a calm trot for one task, faster (capped) with more.
    private var fps: Double { 6 + Double(min(taskCount, 6)) * 2.5 }

    var body: some View {
        TimelineView(.animation) { timeline in
            let frame = Int(timeline.date.timeIntervalSinceReferenceDate * fps) % 8
            Image("otter\(frame)")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 18)
        }
    }
}

/// The running-tasks list, presented as a sheet. Each row pushes the conversation
/// (ChatView auto-reattaches to the run on open). Lives in its own NavigationStack.
struct RunListView: View {
    @ObservedObject var monitor: RunMonitor
    let secret: String
    @Environment(\.dismiss) private var dismiss

    /// The base server profile with THIS run's agent applied, so the reopened
    /// chat uses the right backend (transcript store + header + composer).
    private func runProfile(_ run: RunInfo) -> ServerProfile {
        var p = monitor.profile
        p.backend = run.agent
        return p
    }

    var body: some View {
        NavigationStack {
            Group {
                if monitor.conversationsOutsideGroups.isEmpty && monitor.runningWorkflows.isEmpty
                    && monitor.runningGroups.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "No background tasks",
                        systemImage: "moon.zzz",
                        description: "Send a message in Run mode to start one — it keeps going even if you leave."
                    )
                } else {
                    List {
                        // Running workflows share the pill, so they belong in its
                        // sheet too — a row jumps straight into the live monitor.
                        if !monitor.runningWorkflows.isEmpty {
                            Section("Workflows") {
                                ForEach(monitor.runningWorkflows) { w in
                                    NavigationLink {
                                        WorkflowMonitorView(profile: monitor.profile, secret: secret,
                                                            wfId: w.wfId, name: w.name)
                                    } label: {
                                        HStack(spacing: 12) {
                                            ProgressView().controlSize(.small).tint(Palette.accent)
                                                .frame(width: 22)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(w.name.isEmpty ? "Untitled workflow" : w.name)
                                                    .font(.subheadline).lineLimit(1)
                                                Text(w.startedDate, format: .relative(presentation: .numeric))
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 4)
                                        }
                                        .padding(.vertical, 3)
                                    }
                                    .listRowBackground(Palette.surface)
                                }
                            }
                        }
                        // A group (双开) is ONE row, like a workflow: its mode and
                        // where it stands, opening the group page — never its
                        // member runs one by one under the hidden header.
                        if !monitor.runningGroups.isEmpty {
                            Section(L.groupSectionTitle()) {
                                ForEach(monitor.runningGroups) { g in
                                    NavigationLink {
                                        GroupView(profile: monitor.profile, secret: secret, group: g)
                                    } label: {
                                        GroupRowLabel(group: g).padding(.vertical, 3)
                                    }
                                    .listRowBackground(Palette.surface)
                                }
                            }
                        }
                        ForEach(monitor.conversationsOutsideGroups) { run in
                            NavigationLink {
                                // Carry the RUN's own agent (Codex/Claude) so the reopened
                                // chat loads the matching transcript store and labels itself
                                // correctly — monitor.profile is always the base Claude default.
                                ChatView(profile: runProfile(run), secret: secret,
                                         dir: run.dir, resumeSessionId: run.sessionId,
                                         pillEnabled: false)
                            } label: {
                                RunRow(run: run)
                            }
                            .listRowBackground(Palette.surface)
                            .swipeActions(edge: .trailing) {
                                if run.isRunning {
                                    Button(role: .destructive) { monitor.stopRun(run.runId) } label: {
                                        Label("Stop", systemImage: "stop.fill")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .pervioBackground()
            .pervioBar("Background tasks", back: false)
            .toolbar {
                BarItem(.confirmationAction) { BarWord(text: L.done(), weight: .semibold) { dismiss() } }
            }
        }
    }
}

private struct RunRow: View {
    let run: RunInfo

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.title)
                    .font(.subheadline).lineLimit(2).foregroundStyle(.primary)
                HStack(spacing: 5) {
                    Image(run.agent.iconAsset)        // which agent ran this task
                        .resizable().scaledToFit()
                        .frame(width: 13, height: 13)
                    Text(run.agent.tag)
                    Text("·")
                    Text((run.dir as NSString).lastPathComponent)
                        .lineLimit(1)
                    Text("·")
                    Text(run.startedDate, format: .relative(presentation: .numeric))
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var statusIcon: some View {
        if run.isRunning {
            ProgressView().controlSize(.small).tint(Palette.accent)
        } else if run.isFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        }
    }
}
