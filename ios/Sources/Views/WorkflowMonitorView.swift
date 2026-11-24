import SwiftUI
import UIKit

/// Live view of one workflow. Two lives: while it RUNS this is a progress page
/// (diagram/list of steps); once it FINISHES it's a reading page — the Result tab
/// (auto-selected) lays out the terminal steps' output as rendered markdown, since
/// that output — the paper list, the review, the digest — is the whole point.
struct WorkflowMonitorView: View {
    @StateObject private var store: WorkflowStore
    @Environment(\.scenePhase) private var scenePhase
    private let profile: ServerProfile
    private let secret: String
    private let title: String
    private enum Mode: Hashable { case result, diagram, list }
    @State private var mode: Mode = .diagram
    @State private var selectedStep: WorkflowStepState?
    @State private var rerunSeed: RerunSeed?
    /// Pushes a chat seeded with a "read this run's ledger first" prompt — the
    /// Discuss-with-Claude toolbar entry.
    @State private var discussChat = false
    /// The run's spec, for its presentation contract (display collapse hints +
    /// long-press actions). Present from birth in .start mode; fetched once the
    /// store learns its wfId in attach mode. nil just renders the plain report.
    @State private var spec: WorkflowSpec?
    @State private var actionToast: String?
    @State private var actionError: String?

    /// Hashable wrapper so navigationDestination(item:) can push the editor; a
    /// fresh UUID per fetch means tapping Run again twice still navigates.
    private struct RerunSeed: Hashable {
        let id = UUID()
        let spec: WorkflowSpec
        static func == (l: Self, r: Self) -> Bool { l.id == r.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    /// Start a new workflow from a spec, then watch it.
    init(profile: ServerProfile, secret: String, spec: WorkflowSpec) {
        self.profile = profile
        self.secret = secret
        _store = StateObject(wrappedValue:
            WorkflowStore(profile: profile, secret: secret, mode: .start(spec)))
        _spec = State(initialValue: spec)
        title = spec.name.isEmpty ? "Workflow" : spec.name
    }

    /// Attach to an existing workflow and watch it.
    init(profile: ServerProfile, secret: String, wfId: String, name: String = "") {
        self.profile = profile
        self.secret = secret
        _store = StateObject(wrappedValue:
            WorkflowStore(profile: profile, secret: secret, mode: .attach(wfId)))
        title = name.isEmpty ? "Workflow" : name
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)

            if let led = store.ledger, !led.steps.isEmpty {
                Picker("View", selection: $mode) {
                    Text("Result").tag(Mode.result)
                    Text("Diagram").tag(Mode.diagram)
                    Text("List").tag(Mode.list)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.bottom, 10)

                if mode == .result {
                    resultView
                } else if mode == .diagram {
                    WorkflowGraphView(
                        nodes: led.steps.map {
                            WorkflowGraphNode(id: $0.id, backend: $0.backend, status: $0.status,
                                              dependsOn: $0.dependsOn, inputs: $0.inputs)
                        },
                        onSelect: { id in selectedStep = led.steps.first { $0.id == id } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(led.steps) { step in
                            Button { selectedStep = step } label: { stepRow(step) }
                                .listRowBackground(Palette.surface)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            } else if store.errorText == nil {
                Spacer()
                HStack(spacing: 10) {
                    ProgressView()
                    Text(store.statusLine).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg.ignoresSafeArea())
        .pervioBar(title)
        .toolbar {
            BarItem(.navigationBarTrailing) {
              HStack(spacing: 2) {
                if store.wfId != nil {
                    BarGlyph(systemImage: "bubble.left.and.bubble.right", tint: Palette.accent, label: "Discuss with Claude") { discussChat = true }
                    BarGlyph(systemImage: "arrow.clockwise", tint: Palette.accent, label: "Run again") {
                        Task { if let s = await store.spec() { rerunSeed = RerunSeed(spec: s) } }
                    }
                }
              }
            }
        }
        .navigationDestination(item: $rerunSeed) { seed in
            WorkflowEditorView(profile: profile, secret: secret, seed: seed.spec)
        }
        // Chat opens with the ledger path prefilled so Claude answers from the
        // run's actual step outputs; the user appends their question and sends.
        .navigationDestination(isPresented: $discussChat) {
            ChatView(profile: profile, secret: secret,
                     initialInput: Prompts.monitorDiscuss(title: title,
                                                          wfId: store.wfId ?? ""),
                     pervioContext: true)   // wf-born: workflows context on by birth
        }
        .navigationDestination(item: $selectedStep) {
            WorkflowStepDetailView(step: $0,
                                   collapseSections: spec?.display?.collapseSections ?? [],
                                   actions: spec?.actions ?? [],
                                   runAction: { try await store.runAdhoc($0) })
        }
        .task {
            store.start()
            // Attach mode re-appear: the wfId is already known (onChange won't
            // fire again), so fetch the missed spec here.
            if spec == nil, store.wfId != nil { spec = await store.spec() }
        }
        .onChange(of: store.wfId) { _, id in
            // Attach mode: the spec lives server-side; fetch it once the store
            // learns its wfId (same channel the rerun seed uses). Until it lands
            // the report just renders without collapse/menus.
            guard spec == nil, id != nil else { return }
            Task { spec = await store.spec() }
        }
        .actionFeedback(toast: $actionToast, error: $actionError)
        .onAppear { store.isOnScreen = true }
        .onDisappear { store.isOnScreen = false; store.stop() }
        .onChange(of: scenePhase) { _, phase in store.isForeground = (phase == .active) }
        // "Watch it run, then read what it made": the moment the workflow ends —
        // including attaching to one that already ended — land on the Result tab.
        .onChange(of: store.finished) { _, fin in
            if fin { withAnimation(.easeOut(duration: 0.2)) { mode = .result } }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                WorkflowStatusBadge(status: store.ledger?.status ?? "running")
                if let p = progressText {
                    Text(p).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !store.finished, store.errorText == nil {
                    ProgressView()
                }
            }
            if store.finished == false {
                Text(store.statusLine).font(.caption).foregroundStyle(.secondary)
            }
            if let id = store.wfId {
                Text(id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let git = store.ledger?.git {
                gitRow(git)
            }
            if let err = store.errorText {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    /// Where an isolated run's results live — the single most important thing to
    /// tell the user when the fast-forward back onto their branch didn't happen.
    private func gitRow(_ git: WorkflowGitState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: git.merged ? "checkmark.circle.fill"
                                         : "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(git.merged ? .green : .orange)
            Text(gitText(git))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func gitText(_ git: WorkflowGitState) -> String {
        if git.merged { return git.note.isEmpty ? "Merged back" : git.note }
        if store.finished == false { return "Parallel steps run in isolated git worktrees" }
        if git.note.isEmpty { return "Results on branch \(git.branch)" }
        return git.note
    }

    private var progressText: String? {
        guard let steps = store.ledger?.steps, !steps.isEmpty else { return nil }
        let done = steps.filter { $0.status == "done" }.count
        return "\(done)/\(steps.count) done"
    }

    // MARK: result

    /// The workflow's DELIVERABLE steps. Consumption counts DATA edges only
    /// ({{id.output}} refs) — dependsOn is timing, and a cleanup step that merely
    /// runs after the digest must not hide the digest from this page (the paper
    /// digest ends fetch → … → digest → commit, where commit is a silent shell
    /// step). Among the unconsumed, agent steps outrank command steps (commands
    /// are usually plumbing), and silent steps are dropped while anything has
    /// output. Fallback: the last step, so the tab never renders empty.
    private var terminalSteps: [WorkflowStepState] {
        guard let steps = store.ledger?.steps, !steps.isEmpty else { return [] }
        let consumed = Set(steps.flatMap { $0.inputs })
        var terms = steps.filter { !consumed.contains($0.id) }
        let agents = terms.filter { !$0.isCommand }
        if !agents.isEmpty { terms = agents }
        let withOutput = terms.filter {
            !$0.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !withOutput.isEmpty { terms = withOutput }
        return terms.isEmpty ? Array(steps.suffix(1)) : terms
    }

    /// The reading page: terminal outputs as rendered markdown, copyable; a failed
    /// run puts the failing steps' errors first. This — not the diagram — is what a
    /// finished workflow opens to.
    private var resultView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if store.ledger?.status == "failed" {
                    ForEach((store.ledger?.steps ?? []).filter { !$0.error.isEmpty }) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(s.id) failed")
                                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                            Text(s.error).font(.callout).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                ForEach(terminalSteps) { s in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(s.id).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            WorkflowStatusBadge(status: s.status)
                            Spacer()
                            if !s.output.isEmpty {
                                Button {
                                    UIPasteboard.general.string = s.output
                                    Haptics.tick()
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                        if s.output.isEmpty {
                            Text(store.finished ? "No output."
                                                : "Working… the result lands here when it finishes.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            RichMessageText(text: s.output, streaming: false,
                                            reportStyle: true,
                                            collapseSections: spec?.display?.collapseSections ?? [],
                                            actions: spec?.actions ?? [],
                                            onAction: { fireAction($0) })
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Run a long-press action's command on the server: tick + toast the written
    /// line on success, alert on failure. Fire-and-forget from the menu button.
    private func fireAction(_ command: String) {
        Task {
            do {
                let out = try await store.runAdhoc(command)
                Haptics.tick()
                withAnimation(.easeOut(duration: 0.2)) { actionToast = actionFeedbackLine(out) }
            } catch {
                actionError = pervioErrorText(error, "Couldn't run the action on the server.")
            }
        }
    }

    // MARK: step row

    private func stepRow(_ s: WorkflowStepState) -> some View {
        HStack(spacing: 12) {
            if s.isCommand {
                Image(systemName: "terminal.fill")
                    .font(.body).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            } else {
                Image(s.backend.iconAsset).resizable().scaledToFit().frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(s.id).font(.headline)
                    WorkflowStatusBadge(status: s.status)
                    if let total = s.fanoutTotal, total > 0 {
                        FanoutProgressChip(ok: s.fanoutOk ?? 0, fail: s.fanoutFail ?? 0, total: total)
                    }
                }
                Text(stepPreview(s)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if s.status == "running" { ProgressView() }
        }
    }

    private func stepPreview(_ s: WorkflowStepState) -> String {
        if !s.error.isEmpty { return s.error }
        let line = s.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = line.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        switch s.status {
        case "pending": return "Waiting…"
        case "running": return "Working…"
        case "skipped": return "Skipped"
        default:        return "No output"
        }
    }
}

/// Fan-out children progress ("2/5" landed), fed by the ledger's live
/// fanoutOk/fanoutFail counters: neutral while children are still running,
/// green once all landed ok, orange as soon as any child failed.
struct FanoutProgressChip: View {
    let ok: Int
    let fail: Int
    let total: Int

    var body: some View {
        let done = ok + fail
        let color: Color = fail > 0 ? .orange : (done == total ? .green : .secondary)
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.caption2)
            Text("\(done)/\(total)").font(.caption2.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.18), in: Capsule())
        .foregroundStyle(color)
    }
}

/// Colored capsule for a step / workflow status. Colors/labels come from the
/// shared `WorkflowStatusStyle` so the badge and the graph never disagree.
struct WorkflowStatusBadge: View {
    let status: String

    var body: some View {
        let color = WorkflowStatusStyle.color(status)
        return Text(WorkflowStatusStyle.label(status))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Full output / error of one step.
struct WorkflowStepDetailView: View {
    let step: WorkflowStepState
    /// The workflow's presentation contract (defaults keep other callers as-is).
    var collapseSections: [String] = []
    var actions: [WorkflowAction] = []
    /// Runs an action command on the server (the monitor lends its store's SSH
    /// channel). nil disables the menus. This page owns its own toast/alert —
    /// the monitor's overlay would be hidden underneath a pushed detail.
    var runAction: ((String) async throws -> String)? = nil
    @State private var actionToast: String?
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    if step.isCommand {
                        Image(systemName: "terminal.fill")
                            .font(.title3).foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                        Text("Shell").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Image(step.backend.iconAsset).resizable().scaledToFit().frame(width: 24, height: 24)
                        Text(step.backend.label).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let total = step.fanoutTotal, total > 0 {
                        FanoutProgressChip(ok: step.fanoutOk ?? 0, fail: step.fanoutFail ?? 0, total: total)
                    }
                    WorkflowStatusBadge(status: step.status)
                }

                if !step.error.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Error").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        Text(step.error)
                            .font(.callout).foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }

                HStack {
                    Text("Output").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if !step.output.isEmpty {
                        Button {
                            UIPasteboard.general.string = step.output
                            Haptics.tick()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc").font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                if step.output.isEmpty {
                    Text(emptyOutputText)
                        .font(.callout).foregroundStyle(.secondary)
                } else if step.isCommand {
                    // Shell stdout is NOT markdown — a leading '#' is a comment,
                    // not a heading — so keep it raw, monospaced, selectable.
                    Text(step.output)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Agent output renders like everywhere else (chat, Result tab):
                    // markdown + syntax-highlighted code blocks. Copy keeps the raw.
                    RichMessageText(text: step.output, streaming: false,
                                    reportStyle: true,
                                    collapseSections: collapseSections,
                                    actions: actions,
                                    onAction: runAction == nil ? nil : { fireAction($0) })
                }
            }
            .padding(16)
        }
        .background(Palette.bg.ignoresSafeArea())
        .pervioBar(step.id)
        .actionFeedback(toast: $actionToast, error: $actionError)
    }

    private func fireAction(_ command: String) {
        guard let runAction else { return }
        Task {
            do {
                let out = try await runAction(command)
                Haptics.tick()
                withAnimation(.easeOut(duration: 0.2)) { actionToast = actionFeedbackLine(out) }
            } catch {
                actionError = pervioErrorText(error, "Couldn't run the action on the server.")
            }
        }
    }

    private var emptyOutputText: String {
        switch step.status {
        case "running": return "Working… output appears when the step finishes."
        case "pending": return "Waiting for its dependencies to finish."
        case "skipped": return "Skipped because a dependency failed."
        default:        return "No output."
        }
    }
}

// MARK: - Action feedback (toast + alert)

/// The toast line for a finished action command. pervio-feedback prints one
/// {"ok":true,"line":"…"} — show the written line; any other command falls back
/// to its (trimmed, clipped) stdout, or a plain "Done".
func actionFeedbackLine(_ output: String) -> String {
    struct Resp: Decodable { let ok: Bool?; let line: String? }
    let t = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if let r = try? JSONDecoder().decode(Resp.self, from: Data(t.utf8)),
       let line = r.line, !line.isEmpty {
        return line
    }
    return t.isEmpty ? "Done" : String(t.prefix(120))
}

extension View {
    /// The report-action outcome surfaces: a 2-second bottom toast (the line
    /// pervio-feedback wrote) and a failure alert. Shared by the monitor's
    /// Result tab and the step detail page — each owns its own state so the
    /// toast shows on whichever screen fired the action.
    func actionFeedback(toast: Binding<String?>, error: Binding<String?>) -> some View {
        overlay(alignment: .bottom) {
            if let line = toast.wrappedValue {
                Text(line)
                    .font(.caption)
                    .lineLimit(2)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Palette.surface2, in: Capsule())
                    .overlay(Capsule().stroke(Palette.hairline, lineWidth: 0.5))
                    .padding(.horizontal, 24).padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: toast.wrappedValue) {
            guard toast.wrappedValue != nil else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.2)) { toast.wrappedValue = nil }
        }
        .alert("Action failed",
               isPresented: Binding(get: { error.wrappedValue != nil },
                                    set: { if !$0 { error.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error.wrappedValue ?? "")
        }
    }
}
