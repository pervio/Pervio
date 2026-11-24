import SwiftUI
import Foundation
import UIKit

/// Editor working-copy of one step. Carries a stable `id` (UUID) for SwiftUI list
/// identity that is independent of the user-editable `stepId`, and keeps the
/// Claude and Codex knobs on separate fields so flipping backend never feeds a
/// Claude model id to Codex. Converted to the wire `WorkflowStep` on Run.
struct DraftStep: Identifiable, Equatable {
    let id = UUID()
    var stepId: String
    var backend: AgentBackend = .claude
    var prompt: String = ""
    var dependsOn: Set<String> = []      // derived from stage order on build (not user-edited)

    // Claude axis
    var perm: String = "default"
    var claudeModel: String = ""        // empty = account default
    var claudeEffort: String = ""       // empty = session default

    // Codex axis
    var sandbox: String = "workspace-write"
    var codexModel: String = ""         // empty = codex config default
    var codexEffort: String = ""        // empty = model's own default

    // Cursor axis: its own model menu (empty = auto); the run mode rides `perm`
    // (plan → --mode plan, bypassPermissions → --force); no effort knob.
    var cursorModel: String = ""

    var verify: String = ""             // optional shell gate (exit 0 = pass)
    var allowNetwork: Bool = false      // Claude only: allow WebFetch (no bypass)
    var isShell: Bool = false           // step TYPE: shell command instead of an
                                        // agent turn (picked in the Type section;
                                        // the wire format stays `command` presence)
    var command: String = ""            // the shell line (shell steps only):
                                        // stdout becomes the output, zero tokens
    var dirOverride: String = ""        // per-step working dir (empty = workflow dir)

    // Fan-out (optional): run this step once per item of an earlier step's list
    // output. Numeric knobs are text fields (empty = server default). The spec
    // knobs without editor UI (as / minSuccessRate) are still carried through
    // import → build, so editing a template never strips them.
    var fanoutOver: String = ""          // "{{id.output}}" or "{{id.json}}"; empty = no fan-out
    var fanoutSplit: String = "numbered" // numbered | lines | json
    var fanoutMax: String = ""           // item cap; empty = server default (50)
    var fanoutMaxParallel: String = ""   // concurrent children; empty = server default (4)
    var fanoutAs: String?                // pass-through: per-item variable name
    var fanoutMinRate: Double?           // pass-through: minSuccessRate
    var fanoutTimeoutSec: Int?           // pass-through: per-child wall clock
    var fanoutTolerateAllFail: Bool?     // pass-through: degraded beats skipped

    var allowDispatch: Bool = false     // Claude only: may spawn helper agents

    // Failure policy (WF-2) + the structured lane's pass-throughs (WF-1).
    var isOptional: Bool = false        // failure doesn't block dependents
    var retryText: String = ""          // extra attempts on failure; empty = server default
    var stdinText: String = ""          // command steps: refs fed on stdin
    var outputSchema: JSONValue?        // opaque pass-through (no editor UI yet)

    // Publish: this step's output becomes the workflow's publication — the
    // SERVER archives it daily as <dir>/<YYYY-MM-DD>.md (home card + reader).
    var publishEnabled: Bool = false
    var publishDir: String = ""         // custom dir; empty = server default
                                        // (~/.pervio/archives/<name>/)

    /// The per-item placeholder this step's prompt should use ({{item}} unless a
    /// template overrode `as`).
    var fanoutVar: String { (fanoutAs?.isEmpty == false) ? fanoutAs! : "item" }

    func toStep(validIds: Set<String>) -> WorkflowStep {
        var s = WorkflowStep(id: stepId, backend: backend, prompt: prompt,
                             dependsOn: dependsOn.filter { $0 != stepId && validIds.contains($0) }.sorted())
        if backend == .codex {
            s.sandbox = sandbox
            let m = codexModel.trimmingCharacters(in: .whitespaces)
            if !m.isEmpty { s.model = m }
            if !codexEffort.isEmpty { s.effort = codexEffort }
        } else if backend == .cursor {
            s.perm = perm
            let m = cursorModel.trimmingCharacters(in: .whitespaces)
            if !m.isEmpty { s.model = m }
        } else {
            s.perm = perm
            let m = claudeModel.trimmingCharacters(in: .whitespaces)
            if !m.isEmpty { s.model = m }
            if !claudeEffort.isEmpty { s.effort = claudeEffort }
        }
        let v = verify.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { s.verify = v }
        if allowNetwork && backend == .claude { s.allowNetwork = true }
        let cmd = isShell ? command.trimmed : ""
        if !cmd.isEmpty { s.command = cmd }
        let d = dirOverride.trimmed
        if !d.isEmpty { s.dir = d }
        let over = isShell ? "" : fanoutOver.trimmed
        if !over.isEmpty {
            // A {{id.json}} source is already item-shaped — the server refuses
            // an explicit split there, so the editor must not send one.
            let structured = over.contains(".json")
            s.fanout = WorkflowFanout(over: over,
                                      split: (structured || fanoutSplit == "numbered")
                                          ? nil : fanoutSplit,
                                      asVar: fanoutAs,
                                      max: Int(fanoutMax.trimmed),
                                      maxParallel: Int(fanoutMaxParallel.trimmed),
                                      minSuccessRate: fanoutMinRate,
                                      timeoutSec: fanoutTimeoutSec,
                                      tolerateAllFail: fanoutTolerateAllFail)
        }
        if allowDispatch && backend == .claude { s.allowDispatch = true }
        if isOptional { s.isOptional = true }
        if let r = Int(retryText.trimmed), r > 0 { s.retry = r }
        if !cmd.isEmpty {
            let sd = stdinText.trimmed
            if !sd.isEmpty { s.stdin = sd }
        }
        s.outputSchema = outputSchema
        if publishEnabled {
            s.publishEnabled = true
            let p = publishDir.trimmed
            s.publishDir = p.isEmpty ? nil : p
        }
        return s
    }
}

extension DraftStep {
    /// Prefill from a market/template step. In an extension so DraftStep keeps the
    /// synthesized memberwise `init(stepId:)` that `addStep()` uses.
    init(importing s: WorkflowStep) {
        self.init(stepId: s.id, backend: s.backend, prompt: s.prompt, dependsOn: Set(s.dependsOn))
        perm = s.perm ?? "default"
        sandbox = s.sandbox ?? "workspace-write"
        if s.backend == .codex {
            codexModel = s.model ?? ""
            codexEffort = s.effort ?? ""
        } else if s.backend == .cursor {
            cursorModel = s.model ?? ""
        } else {
            claudeModel = s.model ?? ""
            claudeEffort = s.effort ?? ""
        }
        verify = s.verify ?? ""
        allowNetwork = s.allowNetwork ?? false
        command = s.command ?? ""
        isShell = !(s.command ?? "").isEmpty
        dirOverride = s.dir ?? ""
        if let fo = s.fanout {
            fanoutOver = fo.over
            fanoutSplit = fo.split ?? "numbered"
            fanoutMax = fo.max.map(String.init) ?? ""
            fanoutMaxParallel = fo.maxParallel.map(String.init) ?? ""
            fanoutAs = fo.asVar
            fanoutMinRate = fo.minSuccessRate
            fanoutTimeoutSec = fo.timeoutSec
            fanoutTolerateAllFail = fo.tolerateAllFail
        }
        isOptional = s.isOptional ?? false
        retryText = s.retry.map(String.init) ?? ""
        stdinText = s.stdin ?? ""
        outputSchema = s.outputSchema
        allowDispatch = s.allowDispatch ?? false
        publishEnabled = s.publishEnabled
        publishDir = s.publishDir ?? ""
    }
}

/// A stage = a group of steps that run in PARALLEL. Stages run in sequence (each
/// after the one above). This replaces hand-edited dependencies: on build, every
/// step's `dependsOn` is generated as "all steps in the previous stage".
struct DraftStage: Identifiable, Equatable {
    let id = UUID()
    var steps: [DraftStep]
}

/// Build a multi-step workflow as a stack of STAGES (steps in a stage run in
/// parallel; stages run in order) and launch it. On Run it flattens the stages
/// into a `WorkflowSpec` — generating each step's dependsOn from the stage
/// structure — and pushes `WorkflowMonitorView`.
struct WorkflowEditorView: View {
    let profile: ServerProfile
    let secret: String

    @State private var name = ""
    @State private var dir: String
    @State private var stages: [DraftStage]
    @State private var builtSpec: WorkflowSpec? = nil
    @State private var goMonitor = false
    /// LEGACY compat layer: display (collapseSections/archiveDir) has no editing
    /// UI any more — folding now lives in the report content as <details>, and
    /// publication is the per-step Publish toggle. A seed that still carries
    /// display keeps it verbatim through buildSpec (never silently dropped);
    /// the Interactions section shows a read-only note when it's present.
    @State private var legacyDisplay: WorkflowDisplay?
    /// actions round-trip UNTOUCHED (template → editor → built spec) — they are
    /// authored in the template JSON, not in this form.
    @State private var actions: [WorkflowAction]?

    // Schedule (daily): when ON, the primary action becomes "Save" — the spec is
    // stored server-side and the SERVER fires it at the chosen time (launchd/cron),
    // phone off or not. A template can suggest a time (e.g. the paper digest).
    @State private var schedOn: Bool
    @State private var schedTime: Date
    @State private var savingSchedule = false
    @State private var scheduleError: String?
    /// C10 toast — a NEW subscription prints its first issue immediately
    /// (schedule add arms the current period, so the first clock fire would
    /// otherwise be tomorrow). Shown briefly before the editor pops.
    @State private var scheduleToast: String?

    // "Save as server template" (~/.pervio/templates) — one-shot connection like
    // saveSchedule; the result surfaces as an alert (success haptic, or the error).
    @State private var savingTemplate = false
    @State private var templateSavedAlert = false
    @State private var templateError: String?
    @Environment(\.dismiss) private var dismiss

    init(profile: ServerProfile, secret: String, seed: WorkflowSpec? = nil,
         suggestedTime: String? = nil) {
        self.profile = profile
        self.secret = secret
        // A re-run seed carries the original run's real dir — keep it. Market
        // templates use "~" as an explicit "replace with my project dir" placeholder.
        if let sd = seed?.dir, !sd.isEmpty, sd != "~" {
            _dir = State(initialValue: sd)
        } else {
            _dir = State(initialValue: profile.projectDir)
        }
        if let seed {
            _name = State(initialValue: seed.name)
            _stages = State(initialValue: Self.stages(from: seed))
        } else {
            var first = DraftStep(stepId: "step1")
            first.backend = profile.backend
            _stages = State(initialValue: [DraftStage(steps: [first])])
        }
        // Keep a legacy display only when it actually says something — an empty
        // {} normalizes to nil, exactly what the old CSV/dir fields rebuilt.
        let disp = seed?.display
        let hasLegacy = (disp?.collapseSections?.isEmpty == false)
            || (disp?.archiveDir?.isEmpty == false)
        _legacyDisplay = State(initialValue: hasLegacy ? disp : nil)
        _actions = State(initialValue: seed?.actions)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        if let t = suggestedTime, let d = f.date(from: t) {
            _schedOn = State(initialValue: true)     // the template is MEANT to be daily
            _schedTime = State(initialValue: d)
        } else {
            _schedOn = State(initialValue: false)
            _schedTime = State(initialValue: f.date(from: "06:30") ?? Date())
        }
    }

    var body: some View {
        Form {
            Section("Workflow") {
                TextField("Name (optional)", text: $name)
                TextField("Working directory", text: $dir)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            }
            .listRowBackground(Palette.surface)

            Section {
                if let acts = actions, !acts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(acts.enumerated()), id: \.offset) { _, a in
                            actionRow(a)
                        }
                        Text("Actions are edited in the template JSON or via the Build-with-Claude chat.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No actions — add via Build-with-Claude")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if legacyDisplay != nil {
                    // Not editable here any more, but never silently dropped:
                    // buildSpec carries the seed's display verbatim.
                    Text("Legacy display hints carried along")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Interactions")
            } footer: {
                Text("Long-press menus on matching report text; they ride along the spec. Folding lives in the report content (<details>); a home card comes from a step's Publish toggle.")
            }
            .listRowBackground(Palette.surface)

            Section {
                Toggle("Run daily on the server", isOn: $schedOn.animation())
                if schedOn {
                    DatePicker("At", selection: $schedTime, displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text(schedOn
                     ? "The server fires this by itself every day at the chosen time (its own clock, survives reboots) — your phone doesn't need to be on. Runs appear under Workflows; the last 7 are kept, older ones are cleaned up. Tap Save above to store it."
                     : "Off = run once now. On = save it as a daily job the server runs unattended — e.g. a paper digest ready when you wake up.")
            }
            .listRowBackground(Palette.surface)

            if let err = scheduleError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
                .listRowBackground(Palette.surface)
            }

            if graphNodes.count > 1 {
                Section("Shape") {
                    WorkflowGraphView(nodes: graphNodes, scrolls: false)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                .listRowBackground(Palette.surface)
            }

            ForEach($stages) { $stage in
                let idx = stages.firstIndex { $0.id == stage.id } ?? 0
                Section {
                    ForEach($stage.steps) { $step in
                        NavigationLink {
                            WorkflowStepEditorView(step: $step, earlierRefs: refIds(beforeStage: idx))
                        } label: {
                            stepRow(step)
                        }
                    }
                    .onDelete { offsets in deleteSteps(stageId: stage.id, at: offsets) }
                    Button { addStep(toStageId: stage.id) } label: {
                        Label("Add parallel step", systemImage: "plus.circle")
                    }
                } header: {
                    HStack {
                        Text("Stage \(idx + 1)")
                        Spacer()
                        Text(stageHint(idx, count: stage.steps.count))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    if stage.steps.count > 1 {
                        Text("These \(stage.steps.count) steps run in parallel.")
                    }
                }
                .listRowBackground(Palette.surface)
            }

            Section {
                Button { addStage() } label: {
                    Label("Add stage (runs after)", systemImage: "arrow.down.circle")
                }
            } footer: {
                Text("Steps in the same stage run in parallel; each stage runs after the one above. Use {{id.output}} in a prompt to pull in an earlier step's result.")
            }
            .listRowBackground(Palette.surface)

            publicationSection

            if let err = validationError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                .listRowBackground(Palette.surface)
            }
        }
        .pervioBackground()
        // Same bottom-toast shell as the monitor's action feedback; the error
        // half is unused here (save failures render inline in the form).
        .actionFeedback(toast: $scheduleToast, error: .constant(nil))
        .pervioBar("New workflow")
        .toolbar {
            // ONE HStack for the whole trailing group: three bare siblings in a
            // toolbar item drew only the first on iOS 26 — the person saw "…"
            // and no Edit, Run or Save (2026-10-20). Run and Save sit side by
            // side whatever the schedule toggle says: Run is always the test.
            BarItem(.navigationBarTrailing) {
                HStack(spacing: 2) {
                    Menu {
                        Button {
                            // Share format: the whole item wrapper with dir reset to "~"
                            // — paste-able straight into another phone's market Import.
                            UIPasteboard.general.string =
                                WorkflowMarketItem.wrapping(spec: buildSpec()).exportJSON()
                            Haptics.tick()
                        } label: {
                            Label("Copy spec JSON (backup / share)", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Text(L.templateMenuHint())
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.body.weight(.medium))
                            .frame(width: 30, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("wf-more")
                    EditButton().font(.subheadline)
                    BarWord(text: "Run", weight: .semibold) { runWorkflow() }
                        .disabled(validationError != nil)
                        .accessibilityIdentifier("wf-run")
                    BarWord(text: (savingTemplate || savingSchedule) ? "Saving…" : "Save", weight: .semibold) { saveDraft() }
                        .disabled(validationError != nil || savingTemplate || savingSchedule)
                        .accessibilityIdentifier("wf-save")
                }
            }
        }
        .navigationDestination(isPresented: $goMonitor) {
            if let spec = builtSpec {
                WorkflowMonitorView(profile: profile, secret: secret, spec: spec)
            }
        }
        .alert(L.templateSavedAlert(), isPresented: $templateSavedAlert) {
            Button("OK") {}
        }
        .alert("Couldn't save the template", isPresented: Binding(
            get: { templateError != nil },
            set: { if !$0 { templateError = nil } })) {
            Button("OK") { templateError = nil }
        } message: {
            Text(templateError ?? "")
        }
    }

    // MARK: publication (the fact that was invisible)

    /// The answer to "does this workflow print a home card?", read UNDER the
    /// step tree — the fact is marked twice on the way down: a 刊物 chip on the
    /// publishing step's row, then this block once the tree has been read.
    ///
    /// The only switch is `Publish as home card`, inside ONE step's detail page:
    /// the user found it by hunting, and a workflow they were editing gave no
    /// sign at all that it feeds the home screen. ON → a highlighted block that
    /// names the step and the archive dir; OFF → one quiet line saying where the
    /// switch is (silence is what sent them hunting in the first place).
    ///
    /// Deliberately NOT a banner above the form: a header the eye skips on every
    /// edit is not where this belongs — it belongs next to the thing it is about.
    @ViewBuilder private var publicationSection: some View {
        if let notice = Self.publicationNotice(stages: stages, name: name,
                                               legacyArchiveDir: legacyDisplay?.archiveDir) {
            Section {
                PublicationNoticeCard(notice: notice)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            .listRowBackground(Color.clear)
        } else {
            Section {
                Label(L.publishSectionOffLabel(), systemImage: "doc.text")
                    .font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text(L.publishSectionOffFooter(PublicationTarget.root))
            }
            .listRowBackground(Palette.surface)
        }
    }

    /// What the block says, computed from the DRAFT (not a built spec) so it
    /// tracks a toggle the moment it is flipped. Static and internal: the rule
    /// — publish on ANY step wins, else the legacy display.archiveDir the seed
    /// carries — is the thing worth testing, and a `body` can't be.
    static func publicationNotice(stages: [DraftStage], name: String,
                                  legacyArchiveDir: String?) -> PublicationNotice? {
        let steps = stages.flatMap { $0.steps }
        if let s = steps.first(where: { $0.publishEnabled }) {
            let custom = s.publishDir.trimmingCharacters(in: .whitespacesAndNewlines)
            return PublicationNotice(
                stepId: s.stepId.trimmingCharacters(in: .whitespacesAndNewlines),
                archiveDir: PublicationTarget.archiveDir(
                    workflowName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    publishDir: custom),
                isCustomDir: !custom.isEmpty)
        }
        let legacy = (legacyArchiveDir ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !legacy.isEmpty {
            return PublicationNotice(stepId: "", archiveDir: legacy, isCustomDir: true)
        }
        return nil
    }

    // MARK: rows / hints

    private func stepRow(_ s: DraftStep) -> some View {
        HStack(spacing: 12) {
            if !s.isShell {
                Image(s.backend.iconAsset).resizable().scaledToFit().frame(width: 22, height: 22)
            } else {
                Image(systemName: "terminal.fill")
                    .font(.body).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(s.stepId.isEmpty ? "untitled step" : s.stepId).font(.headline)
                    if !s.fanoutOver.trimmed.isEmpty {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // Which step actually prints the card — visible in the list,
                    // so turning it off doesn't mean opening every step again.
                    if s.publishEnabled { PublicationChip() }
                }
                Text(promptPreview(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// One long-press action, read-only: the match regex, how many menu items,
    /// and the server command it runs. Editing happens in the template JSON.
    private func actionRow(_ a: WorkflowAction) -> some View {
        HStack(spacing: 8) {
            Text(a.match)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text("\(a.menu.count) items")
                .font(.caption2).foregroundStyle(.tint)
                .layoutPriority(1)
            Text(a.run)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 130, alignment: .trailing)
        }
    }

    private func promptPreview(_ s: DraftStep) -> String {
        let cmd = s.isShell ? s.command.trimmed : ""
        if !cmd.isEmpty {
            return "$ " + (cmd.split(whereSeparator: \.isNewline).first.map(String.init) ?? cmd)
        }
        let line = s.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "No prompt yet" : t
    }

    private func stageHint(_ idx: Int, count: Int) -> String {
        let order = idx == 0 ? "runs first" : "after stage \(idx)"
        return count > 1 ? "\(count) parallel · \(order)" : order
    }

    // MARK: live shape

    /// Graph nodes derived from the stage structure (deps = previous stage's ids),
    /// for the "Shape" preview. Only steps with a non-empty, unique id.
    private var graphNodes: [WorkflowGraphNode] {
        var out: [WorkflowGraphNode] = []
        var prevIds: [String] = []
        var seen = Set<String>()
        for stage in stages {
            let ids = stage.steps.map { $0.stepId.trimmed }.filter { !$0.isEmpty }
            for s in stage.steps {
                let id = s.stepId.trimmed
                guard !id.isEmpty, !seen.contains(id) else { continue }
                seen.insert(id)
                out.append(WorkflowGraphNode(id: id, backend: s.backend, status: "",
                                             dependsOn: prevIds,
                                             inputs: workflowOutputRefs(in: s.prompt + " " + s.fanoutOver)))
            }
            prevIds = ids
        }
        return out
    }

    // MARK: structural edits

    /// Ids of every step in the stages BEFORE `idx` — the only steps a step here
    /// may reference (their output is guaranteed ready).
    private func refIds(beforeStage idx: Int) -> [String] {
        stages.prefix(idx).flatMap { $0.steps.map { $0.stepId.trimmed } }.filter { !$0.isEmpty }
    }

    private func freshStepId() -> String {
        let existing = Set(stages.flatMap { $0.steps.map { $0.stepId } })
        var n = stages.reduce(0) { $0 + $1.steps.count } + 1
        while existing.contains("step\(n)") { n += 1 }
        return "step\(n)"
    }

    private func addStep(toStageId stageId: UUID) {
        guard let si = stages.firstIndex(where: { $0.id == stageId }) else { return }
        var s = DraftStep(stepId: freshStepId())
        s.backend = profile.backend
        stages[si].steps.append(s)
        Haptics.tick()
    }

    private func deleteSteps(stageId: UUID, at offsets: IndexSet) {
        guard let si = stages.firstIndex(where: { $0.id == stageId }) else { return }
        stages[si].steps.remove(atOffsets: offsets)
        if stages[si].steps.isEmpty { stages.remove(at: si) }   // drop an emptied stage
    }

    private func addStage() {
        var s = DraftStep(stepId: freshStepId())
        s.backend = profile.backend
        stages.append(DraftStage(steps: [s]))
        Haptics.tick()
    }

    // MARK: validation / build

    private var validationError: String? {
        let all = stages.flatMap { $0.steps }
        if all.isEmpty { return "Add at least one step." }
        var seen = Set<String>()
        for s in all {
            let id = s.stepId.trimmed
            if id.isEmpty { return "Every step needs an id." }
            if id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil {
                return "Step id “\(id)” — use only letters, numbers, _ and -."
            }
            if id == "item" { return "“item” is reserved (the fan-out per-item variable)." }
            if seen.contains(id) { return "Duplicate step id “\(id)”." }
            seen.insert(id)
            if s.isShell {
                if s.command.trimmed.isEmpty {
                    return "Step “\(id)” is a shell step but has no command."
                }
            } else if s.prompt.trimmed.isEmpty {
                return "Step “\(id)” needs a prompt."
            }
        }
        // Fan-out: the source must reference an EARLIER stage's step (its output is
        // the only thing guaranteed ready), and the numeric knobs must be sane —
        // the server quietly falls back on 0 and slices lists on negatives.
        var earlier = Set<String>()
        for stage in stages {
            for s in stage.steps {
                let id = s.stepId.trimmed
                let over = s.fanoutOver.trimmed
                if !over.isEmpty {
                    let refs = workflowOutputRefs(in: over)
                    if refs.isEmpty {
                        return "Step “\(id)” fan-out source must be a {{id.output}} reference."
                    }
                    if let bad = refs.first(where: { !earlier.contains($0) }) {
                        return "Step “\(id)” fans out over “\(bad)”, which isn't in an earlier stage."
                    }
                    for (label, text) in [("Max items", s.fanoutMax), ("Parallel children", s.fanoutMaxParallel)] {
                        let t = text.trimmed
                        if !t.isEmpty && (Int(t) ?? 0) < 1 {
                            return "Step “\(id)” — \(label) must be a number ≥ 1 (or empty for the default)."
                        }
                    }
                }
            }
            earlier.formUnion(stage.steps.map { $0.stepId.trimmed })
        }
        return nil
    }

    private func runWorkflow() {
        guard validationError == nil else { return }
        Haptics.tick()
        builtSpec = buildSpec()
        goMonitor = true
    }

    /// Store the spec as a daily schedule server-side (one-shot connection — the
    /// editor holds no channel of its own), then settle C10's first issue via
    /// the SHARED `ScheduleFirstIssue` policy — the market's one-tap 订阅 runs
    /// the exact same code, so the two paths can never drift. A short toast
    /// shows before the editor pops back to the Workflows list.
    private func saveSchedule() {
        guard validationError == nil, !savingSchedule else { return }
        let spec = buildSpec()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        let hhmm = f.string(from: schedTime)
        savingSchedule = true
        scheduleError = nil
        Task {
            let ssh = SSHService()
            do {
                try await ssh.connect(profile: profile, secret: secret)
                _ = try await ScheduleCreate.add(ssh: ssh, profile: profile,
                                                 spec: spec, time: hhmm)
                let line = await ScheduleFirstIssue.settle(ssh: ssh, time: hhmm)
                await ssh.disconnect()
                Haptics.tick()
                // savingSchedule stays true through the toast so a second Save
                // tap can't create a duplicate schedule while it lingers.
                withAnimation(.easeOut(duration: 0.2)) { scheduleToast = line }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                savingSchedule = false
                dismiss()
            } catch {
                await ssh.disconnect()
                savingSchedule = false
                scheduleError = pervioErrorText(error, "Couldn't save the schedule.")
            }
        }
    }

    /// Store the current draft as a template file in the SERVER's library
    /// (~/.pervio/templates) so the market's "My templates" shows it — the
    /// durable sibling of Copy's clipboard export. Content is the market-item
    /// wrapper shape {name, summary, spec}, which `templates list` recognizes
    /// alongside bare specs. One-shot connection, same idiom as saveSchedule.
    /// The one Save (2026-10-20): the draft becomes a template of MINE on the Mac
    /// (the market's Mine shelf — modify a market template, Save, and you have
    /// your own), and, with "Run daily" on, a daily schedule at the chosen time
    /// as well. A second Save makes a second schedule, never edits the first:
    /// a template is a blueprint, the Workflows page manages the copies.
    private func saveDraft() {
        guard validationError == nil, !savingTemplate, !savingSchedule else { return }
        if schedOn {
            saveAsTemplate(thenSchedule: true)
        } else {
            saveAsTemplate(thenSchedule: false)
        }
    }

    private func saveAsTemplate(thenSchedule: Bool = false) {
        guard !savingTemplate else { return }
        let spec = buildSpec()
        struct Payload: Encodable {
            let name: String; let summary: String; let spec: WorkflowSpec
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(Payload(name: spec.name, summary: "", spec: spec)),
              let json = String(data: data, encoding: .utf8) else { return }
        let filename = SSHService.templateFilename(for: spec.name)
        savingTemplate = true
        templateError = nil
        Task {
            let ssh = SSHService()
            do {
                try await ssh.connect(profile: profile, secret: secret)
                try await ssh.saveTemplate(profile: profile, filename: filename, json: json)
                if thenSchedule {
                    // The same connection makes the daily copy; its first issue
                    // settles through the shared policy, exactly as the market's 订阅.
                    savingSchedule = true
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.dateFormat = "HH:mm"
                    let hhmm = f.string(from: schedTime)
                    _ = try await ScheduleCreate.add(ssh: ssh, profile: profile, spec: spec, time: hhmm)
                    let line = await ScheduleFirstIssue.settle(ssh: ssh, time: hhmm)
                    await ssh.disconnect()
                    Haptics.tick()
                    withAnimation(.easeOut(duration: 0.2)) { scheduleToast = line }
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    savingTemplate = false
                    savingSchedule = false
                    dismiss()
                    return
                }
                await ssh.disconnect()
                savingTemplate = false
                Haptics.tick()
                templateSavedAlert = true
            } catch {
                await ssh.disconnect()
                savingTemplate = false
                savingSchedule = false
                templateError = pervioErrorText(error, thenSchedule ? "Couldn't save." : "Couldn't save the template.")
            }
        }
    }

    /// Flatten stages → WorkflowSpec, generating each step's dependsOn as "all
    /// steps in the previous stage" (so a stage waits for the one above it).
    private func buildSpec() -> WorkflowSpec {
        var spec = WorkflowSpec()
        spec.name = name.trimmingCharacters(in: .whitespaces)
        let d = dir.trimmingCharacters(in: .whitespaces)
        spec.dir = d.isEmpty ? "~" : d

        let allIds = Set(stages.flatMap { $0.steps.map { $0.stepId.trimmed } })
        var prevStageIds: [String] = []
        var out: [WorkflowStep] = []
        for stage in stages {
            let thisIds = stage.steps.map { $0.stepId.trimmed }.filter { !$0.isEmpty }
            for var d0 in stage.steps {
                d0.stepId = d0.stepId.trimmed
                var s = d0.toStep(validIds: allIds)
                s.dependsOn = prevStageIds.filter { allIds.contains($0) }
                out.append(s)
            }
            prevStageIds = thisIds
        }
        spec.steps = out
        // Presentation contract: carry the seed's legacy display and its actions
        // through VERBATIM — buildSpec() reconstructs the spec from fields, so
        // forgetting either here would silently strip it from every Run /
        // Save-schedule / Copy-JSON / Save-template path. (Folding is authored
        // in the report content now, publish on the step — both already in
        // `out`; display survives only as the compat layer for old templates.)
        spec.display = legacyDisplay
        spec.actions = actions
        return spec
    }

    /// Derive stages from a spec by topological layering (same as the flow graph):
    /// each layer of the DAG becomes one stage. Lossless for stage-shaped specs
    /// (all our templates); a fine-grained DAG is normalized to stages.
    static func stages(from spec: WorkflowSpec) -> [DraftStage] {
        let steps = spec.steps
        if steps.isEmpty {
            return [DraftStage(steps: [DraftStep(stepId: "step1")])]
        }
        let ids = Set(steps.map { $0.id })
        let byId = Dictionary(steps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var memo: [String: Int] = [:]
        var visiting = Set<String>()
        func layer(_ id: String) -> Int {
            if let m = memo[id] { return m }
            if visiting.contains(id) { return 0 }
            visiting.insert(id)
            let deps = (byId[id]?.dependsOn ?? []).filter { ids.contains($0) && $0 != id }
            let l = deps.isEmpty ? 0 : 1 + (deps.map { layer($0) }.max() ?? 0)
            visiting.remove(id)
            memo[id] = l
            return l
        }
        for s in steps { _ = layer(s.id) }
        let maxL = memo.values.max() ?? 0
        var buckets: [[DraftStep]] = Array(repeating: [], count: maxL + 1)
        for s in steps { buckets[memo[s.id] ?? 0].append(DraftStep(importing: s)) }   // order preserved
        return buckets.filter { !$0.isEmpty }.map { DraftStage(steps: $0) }
    }
}

/// `schedule add` for every path that creates one (the editor's Save and the
/// market's one-tap 订阅), so that what the schedule is CALLED is decided once.
///
/// There is deliberately no `name:` here: it comes from `spec.scheduleName`, and
/// a caller therefore has nothing to get wrong. It used to be each entrance's own
/// expression, and they disagreed for a spec with no name — the editor said
/// "Scheduled workflow", the market said its catalog title. The market decides
/// 已订阅 by looking ITS answer up in `schedule list`, so it could not see the
/// schedule the editor had saved for that very spec: the 订阅 button stayed lit,
/// the pre-add re-list asked about the wrong name too, and one tap armed a second
/// daily schedule that ran and billed twice every morning.
///
/// This is the name-half of the same "two paths, one policy" rule that
/// `ScheduleFirstIssue` below is the timing-half of.
enum ScheduleCreate {
    static func add(ssh: any MarketSSHProtocol, profile: ServerProfile,
                    spec: WorkflowSpec, time hhmm: String,
                    keepRuns: Int = 7) async throws -> String {
        try await ssh.scheduleAdd(profile: profile, spec: spec, name: spec.scheduleName,
                                  time: hhmm, keepRuns: keepRuns)
    }
}

/// C10's first-issue wording, in ONE place for every path that CREATES a
/// daily schedule (the editor's Save and the market's one-tap 订阅 — shared so
/// the two can never drift). Since 2026-09-01 this FIRES NOTHING: subscribing
/// registers, it never spends — the auto-run of a passed slot billed a full
/// pipeline run to a tap that only meant "sign me up". The server's own tick
/// owns every automatic print, and the explicit 现在来一期 button is the only
/// manual trigger. The clock read survives solely so the toast's promise
/// (今天 12:30 vs 明天) is honest across timezones.
enum ScheduleFirstIssue {
    /// Settle the first issue for a just-created schedule over the caller's
    /// open connection and return the toast line. A fire failure is NOT the
    /// save's failure — the schedule exists either way; "Run now" retries.
    /// `phoneClock` is the LAST-RESORT clock used when the server won't answer.
    /// It is a parameter only so a test can hand in a fixed one: with the real
    /// `Calendar.current` behind it, a test that means to prove "the SERVER's
    /// clock decided this" silently proves nothing during whichever minute of
    /// the day the phone happens to agree with the script.
    /// Word the toast for a just-created schedule — 今天 or 明天 — over the
    /// caller's open connection. `phoneClock` is the LAST-RESORT clock used
    /// when the server won't answer; a parameter only so tests can pin whose
    /// clock decided the wording.
    static func settle(ssh: any MarketSSHProtocol, time hhmm: String,
                       phoneClock: () -> (Int, Int) = Self.localClock) async -> String {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        let now = await serverClock(ssh: ssh, phoneClock: phoneClock)
        let stillAheadToday = parts.count == 2 && (parts[0], parts[1]) > now
        return stillAheadToday ? L.firstIssueScheduledToday(hhmm)
                               : L.firstIssueTomorrow(hhmm)
    }

    /// The SERVER's wall clock as (hour, minute).
    ///
    /// "06:30" on a schedule is server-local — it is the clock the server's own
    /// daily tick reads, and `WorkflowSchedule.tz` exists precisely because the
    /// phone is often somewhere else. Asking `Calendar.current` instead meant a
    /// phone an hour ahead of its server called a slot "already passed" and
    /// fired a duplicate first issue, and a phone behind it called a passed slot
    /// "still ahead" and left the subscription silent until the next day.
    ///
    /// Read over the connection the caller already has open. If the server won't
    /// answer we fall back to the phone's clock — the same guess as before, and
    /// the only one left; a subscription must not fail over a clock read.
    private static func serverClock(ssh: any MarketSSHProtocol,
                                    phoneClock: () -> (Int, Int)) async -> (Int, Int) {
        if let out = try? await ssh.runCommand("date +%H:%M") {
            // Take the LAST line that reads as a clock: a login banner or a
            // stray warning can arrive ahead of the answer.
            for line in out.split(whereSeparator: \.isNewline).reversed() {
                let p = line.trimmingCharacters(in: .whitespaces).split(separator: ":")
                            .compactMap { Int($0) }
                if p.count == 2, (0...23).contains(p[0]), (0...59).contains(p[1]) {
                    return (p[0], p[1])
                }
            }
        }
        return phoneClock()
    }

    /// This phone's wall clock — the fallback, and nothing else's default.
    static func localClock() -> (Int, Int) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (c.hour ?? 0, c.minute ?? 0)
    }
}

/// Edit one step: agent, prompt (with insert-an-earlier-output), model/effort, run
/// mode (Claude) / sandbox (Codex), and an optional verify command. Ordering is
/// the stage's job — there is no dependency picker here.
struct WorkflowStepEditorView: View {
    @Binding var step: DraftStep
    /// Ids of steps in EARLIER stages — the outputs this step may pull in.
    let earlierRefs: [String]

    var body: some View {
        Form {
            Section("Step id") {
                TextField("step id (letters, numbers, _ -)", text: $step.stepId)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            }
            .listRowBackground(Palette.surface)

            // A COMMAND step runs a fixed shell line and never touches an
            // agent — showing the agent picker / prompt / model / permission
            // sections for it displayed six screens of settings the server
            // ignores wholesale (the digest's fetch step wore a "claude" badge
            // it never used; the user rightly asked why). One rule: everything
            // agent-flavored appears only while the command field is empty.
            Section("Type") {
                ForEach(AgentBackend.allCases) { b in
                    Button { step.backend = b; step.isShell = false } label: { agentRow(b) }
                        .buttonStyle(.plain)
                }
                Button { step.isShell = true } label: { shellRow }
                    .buttonStyle(.plain)
            }
            .listRowBackground(Palette.surface)

            if !step.isShell {
            Section {
                if !usedInputs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Text("Inputs").font(.caption2).foregroundStyle(.secondary)
                            ForEach(usedInputs, id: \.self) { id in
                                Text(id)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Palette.surface2, in: Capsule())
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
                TextEditor(text: $step.prompt)
                    .frame(minHeight: 120)
                    .autocorrectionDisabled()
                if !earlierRefs.isEmpty {
                    Menu("Insert an earlier step's output…") {
                        ForEach(earlierRefs, id: \.self) { id in
                            Button("{{\(id).output}}") { insertRef(id) }
                        }
                    }
                    .font(.callout)
                }
            } header: {
                Text("Prompt")
            } footer: {
                if !usedInputs.isEmpty {
                    Text("This step pulls in: \(usedInputs.joined(separator: ", ")).")
                } else if !earlierRefs.isEmpty {
                    Text("Use {{id.output}} to pull in an earlier step's result.")
                }
            }
            .listRowBackground(Palette.surface)
            }

            if step.isShell {
                Section {
                    TextField("e.g. ~/.pervio/bin/pervio-arxiv-fetch …", text: $step.command)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("stdin (optional) — e.g. {{score.json}}", text: $step.stdinText)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    if !earlierRefs.isEmpty {
                        Menu("Feed an earlier step on stdin…") {
                            ForEach(earlierRefs, id: \.self) { id in
                                Button("{{\(id).output}} — its text") { step.stdinText = "{{\(id).output}}" }
                                Button("{{\(id).json}} — its parsed value") { step.stdinText = "{{\(id).json}}" }
                            }
                        }
                        .font(.callout)
                    }
                } header: {
                    Text("Shell command")
                } footer: {
                    Text("Runs this fixed shell line instead of an agent — stdout becomes the step's output; zero tokens. {{refs}} are never spliced into the command line; to hand it an earlier step's result, use the stdin field (data flows in on standard input, injection-free).")
                }
                .listRowBackground(Palette.surface)
            }

            if !step.isShell {
                fanoutSection
            }

            Section {
                Toggle("Optional (failure doesn't block)", isOn: $step.isOptional)
                HStack {
                    Text("Retries on failure")
                    Spacer()
                    TextField("0", text: $step.retryText)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .frame(maxWidth: 70)
                }
            } header: {
                Text("Failure policy")
            } footer: {
                Text("Optional: if this step fails, later steps still run (their {{refs}} to it come back empty) and the workflow still counts as done. Retries: extra attempts (0–5) on any failure — left empty, the server retries once and only for network-ish blips.")
            }
            .listRowBackground(Palette.surface)

            if !step.isShell {
                if step.backend == .codex { codexSections } else if step.backend == .cursor { cursorSections } else { claudeSections }
            }

            if !step.isShell && step.backend == .claude {
                Section {
                    Toggle("Allow network (WebFetch)", isOn: $step.allowNetwork)
                } header: {
                    Text("Network")
                } footer: {
                    Text("Lets this step fetch URLs / APIs with WebFetch — without bypassing permissions. Off by default.")
                }
                .listRowBackground(Palette.surface)

                Section {
                    Toggle("Allow helper agents (dispatch)", isOn: $step.allowDispatch)
                } header: {
                    Text("Helper agents")
                } footer: {
                    Text("Lets this step spawn short-lived child agent turns via pervio-dispatch — capped in depth, width, and budget, never above this step's own permissions. Off by default.")
                }
                .listRowBackground(Palette.surface)
            }

            Section {
                TextField("shell command, e.g. npm test", text: $step.verify)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: {
                Text("Verify (optional)")
            } footer: {
                Text("Runs in the working dir after the step. Must exit 0 for the step to count as done; otherwise the step fails.")
            }
            .listRowBackground(Palette.surface)

            Section {
                TextField("e.g. ~/.pervio/papers", text: $step.dirOverride)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: {
                Text("Run in directory (optional)")
            } footer: {
                Text("Overrides the workflow's working directory for THIS step — e.g. a state dir a digest step maintains, or a package inside a monorepo. Empty = the workflow's directory.")
            }
            .listRowBackground(Palette.surface)

            // The second half of "make publishing visible": the tree row wears a
            // 刊物 chip, and the step's own detail highlights the switch that put
            // it there — so arriving from either direction, the fact is loud.
            Section {
                Toggle("Publish as home card", isOn: $step.publishEnabled.animation())
                if step.publishEnabled {
                    TextField("Custom directory (optional)", text: $step.publishDir)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Publish")
                    if step.publishEnabled { PublicationChip() }
                }
            } footer: {
                Text("On = this step's output is archived daily as the workflow's publication — home card + back-issue reader. Directory defaults to ~/.pervio/archives/<name>/.")
            }
            .listRowBackground(step.publishEnabled
                               ? Palette.accent.opacity(0.14) : Palette.surface)
        }
        .pervioBackground()
        .pervioBar(step.stepId.isEmpty ? "Step" : step.stepId)
    }

    // MARK: fan-out

    @ViewBuilder private var fanoutSection: some View {
        Section {
            TextField("{{id.output}} — an earlier step's list", text: $step.fanoutOver)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            if !earlierRefs.isEmpty {
                Menu("Fan out over…") {
                    ForEach(earlierRefs, id: \.self) { id in
                        Button("{{\(id).output}} — its text, split below") {
                            step.fanoutOver = "{{\(id).output}}"
                        }
                        Button("{{\(id).json}} — its parsed array, one child per element") {
                            step.fanoutOver = "{{\(id).json}}"
                        }
                    }
                }
                .font(.callout)
            }
            if !step.fanoutOver.trimmed.isEmpty && !step.fanoutOver.contains(".json") {
                Picker("Split items by", selection: $step.fanoutSplit) {
                    Text("Numbered list").tag("numbered")
                    Text("Lines").tag("lines")
                    Text("JSON array").tag("json")
                }
            }
            if !step.fanoutOver.trimmed.isEmpty {
                HStack {
                    Text("Max items")
                    Spacer()
                    TextField("50", text: $step.fanoutMax)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .frame(maxWidth: 70)
                }
                HStack {
                    Text("Parallel children")
                    Spacer()
                    TextField("4", text: $step.fanoutMaxParallel)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .frame(maxWidth: 70)
                }
                Button("Insert {{\(step.fanoutVar)}} into the prompt") { insertItemVar() }
                    .font(.callout)
            }
        } header: {
            Text("Fan out (optional)")
        } footer: {
            Text(step.fanoutOver.trimmed.isEmpty
                 ? "Runs this step once per item of an earlier step's list output — e.g. one child per file. Leave empty to run it once."
                 : step.fanoutOver.contains(".json")
                 ? "One child agent turn per array element, in parallel. {{\(step.fanoutVar)}} is the whole element; {{\(step.fanoutVar)}}.key reaches into an object element's fields (write it as {{\(step.fanoutVar).key}}). Max items is a safety cap — extras are dropped. Parallel children = how many run at once."
                 : "One child agent turn per item, in parallel. Split says how the source text becomes items (numbered = '1. … 2. …' lines). {{\(step.fanoutVar)}} in the prompt stands for the current item. Max items is a safety cap — extras are dropped. Parallel children = how many run at once.")
        }
        .listRowBackground(Palette.surface)
    }

    /// Append the per-item placeholder on its own line (same idiom as insertRef).
    private func insertItemVar() {
        if !step.prompt.isEmpty && !step.prompt.hasSuffix("\n") { step.prompt += "\n" }
        step.prompt += "{{\(step.fanoutVar)}}"
    }

    /// The earlier-step ids this prompt already references — shown as chips so the
    /// wired inputs are visible without scrolling. Same parser that drives the
    /// graph's data-flow edges, so the chips and the diagram never disagree.
    private var usedInputs: [String] { workflowOutputRefs(in: step.prompt) }

    /// Append a reference on its own line so it never mashes into the preceding
    /// text (TextEditor gives no cursor position to insert at).
    private func insertRef(_ id: String) {
        if !step.prompt.isEmpty && !step.prompt.hasSuffix("\n") { step.prompt += "\n" }
        step.prompt += "{{\(id).output}}"
    }

    private var shellRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 22))
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Shell command").foregroundStyle(.primary)
                Text("A fixed shell line runs instead of an agent — zero tokens")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if step.isShell {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private func agentRow(_ b: AgentBackend) -> some View {
        HStack(spacing: 12) {
            Image(b.iconAsset).resizable().scaledToFit().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.label).foregroundStyle(.primary)
                Text(b.tagline).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if step.backend == b && !step.isShell {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
    }

    // MARK: Cursor knobs — its own model menu and three ways to run; no effort

    @ViewBuilder private var cursorSections: some View {
        Section {
            TextField("cursor model (empty = auto)", text: $step.cursorModel)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Menu("Quick pick…") {
                ForEach(ModelOption.cursorPresets) { m in
                    Button(m.label) { step.cursorModel = m.value }
                }
            }
            .font(.callout)
        } header: {
            Text("Model")
        } footer: {
            Text("Cursor's own menu (your account's models). Empty = auto, Cursor picks; effort is built into the model name.")
        }
        .listRowBackground(Palette.surface)

        Section("Run mode") {
            ForEach(CursorRunMode.all) { mode in
                Button { step.perm = mode.id } label: {
                    optionRow(icon: mode.icon, title: mode.title, subtitle: mode.subtitle,
                              dangerous: mode.isDangerous, selected: CursorRunMode.named(step.perm).id == mode.id)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: Claude knobs

    @ViewBuilder private var claudeSections: some View {
        Section {
            TextField("claude model (empty = account default)", text: $step.claudeModel)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Menu("Quick pick…") {
                // Tiers first: workflow specs live for months while model ids
                // churn — a tier is resolved by the SERVER at launch, so model
                // upgrades are one server-table edit, not spec surgery.
                // Workflow-only: chat model pickers must NOT offer these
                // (chats bypass the orchestrator's resolver).
                ForEach(WorkflowModelTier.presets) { t in
                    Button(t.label) { step.claudeModel = t.value }
                }
                Divider()
                ForEach(ModelOption.presets) { m in
                    Button(m.label) { step.claudeModel = m.value }
                }
            }
            .font(.callout)
        } header: {
            Text("Model")
        } footer: {
            Text("Tier names (flagship / balanced / fast) are translated to a concrete model by your server when the workflow runs — they survive model upgrades. A raw model id pins that exact model.")
        }
        .listRowBackground(Palette.surface)

        Section("Effort (reasoning depth)") {
            Picker("Effort", selection: $step.claudeEffort) {
                ForEach(EffortOption.presets) { e in Text(e.label).tag(e.value) }
            }
        }
        .listRowBackground(Palette.surface)

        Section("Run mode") {
            ForEach(RunMode.all) { mode in
                Button { step.perm = mode.id } label: {
                    optionRow(icon: mode.icon, title: mode.title, subtitle: mode.subtitle,
                              dangerous: mode.isDangerous, selected: step.perm == mode.id)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: Codex knobs

    @ViewBuilder private var codexSections: some View {
        Section("Model") {
            TextField("codex model (empty = config default)", text: $step.codexModel)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Menu("Quick pick…") {
                ForEach(CodexModelOption.presets) { m in
                    Button(m.label) { step.codexModel = m.value }
                }
            }
            .font(.callout)
        }
        .listRowBackground(Palette.surface)

        Section("Effort (reasoning depth)") {
            Picker("Effort", selection: $step.codexEffort) {
                ForEach(CodexEffortOption.all) { e in Text(e.label).tag(e.value) }
            }
        }
        .listRowBackground(Palette.surface)

        Section("Sandbox") {
            ForEach(CodexSandboxOption.headless) { sb in
                Button { step.sandbox = sb.value } label: {
                    optionRow(icon: sb.icon, title: sb.title, subtitle: sb.subtitle,
                              dangerous: sb.isDangerous, selected: step.sandbox == sb.value)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowBackground(Palette.surface)
    }

    private func optionRow(icon: String, title: String, subtitle: String,
                           dangerous: Bool, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(dangerous ? Color.orange : Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
