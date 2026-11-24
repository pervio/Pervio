import Foundation

/// A multi-step agent workflow, mirroring the JSON that `pervio-orchestrate`
/// consumes (`start --spec-b64`) and reports (`status`/`tail` → ledger). Kept in
/// exact sync with server/bin/pervio-orchestrate.

/// One step the user defines: which agent runs it, the prompt (may reference an
/// earlier step's output via `{{stepId.output}}`), what it depends on, and an
/// optional verify command that must pass for the step to count as done.
struct WorkflowStep: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var backend: AgentBackend = .claude
    var prompt: String = ""
    var dependsOn: [String] = []
    /// Claude only — permission mode (default | acceptEdits | plan | bypassPermissions).
    var perm: String?
    /// Codex only — sandbox (read-only | workspace-write | danger-full-access).
    var sandbox: String?
    var model: String?
    var effort: String?
    /// Optional shell command (e.g. "npm test") that must exit 0 for this step to pass.
    var verify: String?
    /// Claude only — when true, the step is allowed to reach the network (WebFetch)
    /// WITHOUT bypassPermissions. The server maps it to `--allowedTools "WebFetch"`.
    var allowNetwork: Bool?
    /// When set, this step FANS OUT: the server splits `fanout.over`'s list and runs
    /// one child agent turn per item, with `{{item}}` in the prompt as the template.
    var fanout: WorkflowFanout?
    /// Claude only — when true, the step may spawn child agent turns via pervio-dispatch,
    /// guarded server-side by depth/concurrency/budget caps.
    var allowDispatch: Bool?
    /// When set, the step runs this shell line INSTEAD of an agent turn — its stdout
    /// becomes the step's output. Deterministic and token-free (the data layer of
    /// scheduled digests). Same trust level as `verify`: it runs in your server's shell.
    var command: String?
    /// Per-step working-directory override (the server has always honored it).
    /// E.g. the paper digest's editorial step runs in ~/.pervio/papers so its
    /// acceptEdits writes (archive, profile) stay scoped to that state dir.
    var dir: String?
    /// The spec's `publish` key is heterogeneous JSON — `true` (archive to the
    /// default ~/.pervio/archives/<name>/) or a directory string — so it splits
    /// into two Swift fields. When set, the ORCHESTRATOR writes this step's
    /// final output as <dir>/<YYYY-MM-DD>.md on completion, making the workflow
    /// a publication (home card + back-issue reader); the step itself never
    /// writes the file. At most one step per spec may publish (server-validated).
    var publishEnabled: Bool = false
    /// Custom publish directory; nil = the server's default slug directory.
    var publishDir: String?
    /// When true this step never blocks the graph: its failure lets dependents
    /// run (their {{refs}} substitute empty) and leaves the RUN done.
    var isOptional: Bool?
    /// The author's failure budget: up to N re-runs on any failure (0–5).
    /// nil keeps the server's legacy contract (one re-run, transient only).
    var retry: Int?
    /// Command steps only — a template ({{id.output}}/{{id.json}} refs allowed)
    /// fed to the command on stdin. The data lane; the command line stays fixed.
    var stdin: String?
    /// Agent steps only — a JSON-Schema-subset contract the step's output must
    /// match (the server validates, corrects once, then fails). Carried opaquely:
    /// the editor has no schema UI yet, but editing a spec must not strip it.
    var outputSchema: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, backend, prompt, dependsOn, perm, sandbox, model, effort, verify
        case allowNetwork, fanout, allowDispatch, command, dir, publish
        case isOptional = "optional"
        case retry, stdin, outputSchema
    }

    init(id: String, backend: AgentBackend = .claude, prompt: String = "",
         dependsOn: [String] = []) {
        self.id = id; self.backend = backend; self.prompt = prompt; self.dependsOn = dependsOn
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        backend = (try? c.decode(AgentBackend.self, forKey: .backend)) ?? .claude
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        dependsOn = (try? c.decode([String].self, forKey: .dependsOn)) ?? []
        perm = try? c.decode(String.self, forKey: .perm)
        sandbox = try? c.decode(String.self, forKey: .sandbox)
        model = try? c.decode(String.self, forKey: .model)
        effort = try? c.decode(String.self, forKey: .effort)
        verify = try? c.decode(String.self, forKey: .verify)
        allowNetwork = try? c.decode(Bool.self, forKey: .allowNetwork)
        fanout = try? c.decode(WorkflowFanout.self, forKey: .fanout)
        allowDispatch = try? c.decode(Bool.self, forKey: .allowDispatch)
        command = try? c.decode(String.self, forKey: .command)
        dir = try? c.decode(String.self, forKey: .dir)
        // publish: Bool first (true/false), then String (custom directory) —
        // any other shape falls through to "not published", like every field here.
        if let b = try? c.decode(Bool.self, forKey: .publish) {
            publishEnabled = b
        } else if let s = try? c.decode(String.self, forKey: .publish) {
            publishEnabled = true
            publishDir = s
        }
        isOptional = try? c.decode(Bool.self, forKey: .isOptional)
        retry = try? c.decode(Int.self, forKey: .retry)
        stdin = try? c.decode(String.self, forKey: .stdin)
        outputSchema = try? c.decode(JSONValue.self, forKey: .outputSchema)
    }

    /// Hand-written because `publish` fuses two properties into one key —
    /// otherwise byte-for-byte what the synthesized encoder emitted (optionals
    /// only when present), so existing exported specs don't change shape.
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(backend, forKey: .backend)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(dependsOn, forKey: .dependsOn)
        try c.encodeIfPresent(perm, forKey: .perm)
        try c.encodeIfPresent(sandbox, forKey: .sandbox)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(verify, forKey: .verify)
        try c.encodeIfPresent(allowNetwork, forKey: .allowNetwork)
        try c.encodeIfPresent(fanout, forKey: .fanout)
        try c.encodeIfPresent(allowDispatch, forKey: .allowDispatch)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(dir, forKey: .dir)
        if publishEnabled {
            if let d = publishDir { try c.encode(d, forKey: .publish) }
            else { try c.encode(true, forKey: .publish) }
        }
        try c.encodeIfPresent(isOptional, forKey: .isOptional)
        try c.encodeIfPresent(retry, forKey: .retry)
        try c.encodeIfPresent(stdin, forKey: .stdin)
        try c.encodeIfPresent(outputSchema, forKey: .outputSchema)
    }

    var isFanout: Bool { fanout != nil }
    var isCommand: Bool { !(command ?? "").isEmpty }
}

/// An arbitrary JSON tree, round-tripped verbatim. Exists so spec fields the
/// editor has no UI for (outputSchema) survive a decode→edit→encode cycle
/// instead of being silently stripped by CodingKeys.
enum JSONValue: Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
        }
    }

    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// The fan-out modifier on a step: split `over`'s list and run one child per item.
/// Round-trips the server spec verbatim so editing a demo never strips it.
struct WorkflowFanout: Codable, Equatable, Hashable {
    var over: String                 // "{{producerStep.output}}"
    var split: String?               // numbered | lines | json (default numbered)
    var asVar: String?               // per-item placeholder name (default "item")
    var max: Int?                    // hard cap on items (default 50)
    var maxParallel: Int?            // concurrent children (default 4)
    var minSuccessRate: Double?      // step fails below this fraction (default 0)
    var timeoutSec: Int?             // per-child wall clock; server clamps to 60–900 (default 180)
    var tolerateAllFail: Bool?       // step is done even if every child failed (degraded downstream beats skipped)

    enum CodingKeys: String, CodingKey {
        case over, split, max, maxParallel, minSuccessRate, timeoutSec, tolerateAllFail
        case asVar = "as"
    }
    init(over: String, split: String? = nil, asVar: String? = nil, max: Int? = nil,
         maxParallel: Int? = nil, minSuccessRate: Double? = nil, timeoutSec: Int? = nil,
         tolerateAllFail: Bool? = nil) {
        self.over = over; self.split = split; self.asVar = asVar
        self.max = max; self.maxParallel = maxParallel; self.minSuccessRate = minSuccessRate
        self.timeoutSec = timeoutSec; self.tolerateAllFail = tolerateAllFail
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        over = (try? c.decode(String.self, forKey: .over)) ?? ""
        split = try? c.decode(String.self, forKey: .split)
        asVar = try? c.decode(String.self, forKey: .asVar)
        max = try? c.decode(Int.self, forKey: .max)
        maxParallel = try? c.decode(Int.self, forKey: .maxParallel)
        minSuccessRate = try? c.decode(Double.self, forKey: .minSuccessRate)
        timeoutSec = try? c.decode(Int.self, forKey: .timeoutSec)
        tolerateAllFail = try? c.decode(Bool.self, forKey: .tolerateAllFail)
    }
}

/// Pure-presentation hints on a spec: the report viewer folds each declared
/// level-2 section behind a disclosure. Content stays plain self-sufficient
/// markdown — a viewer that doesn't know this key just shows it unfolded.
struct WorkflowDisplay: Codable, Equatable, Hashable {
    var collapseSections: [String]?
    /// Directory of dated markdown issues this workflow archives (e.g.
    /// "~/.pervio/papers/archive"). Non-nil makes the workflow a "publication":
    /// the server's `archives list` surfaces it and the home page gives it a
    /// reader. Purely declarative — a viewer that ignores it loses nothing.
    var archiveDir: String?

    enum CodingKeys: String, CodingKey { case collapseSections, archiveDir }
    init(collapseSections: [String]? = nil, archiveDir: String? = nil) {
        self.collapseSections = collapseSections
        self.archiveDir = archiveDir
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        collapseSections = try? c.decode([String].self, forKey: .collapseSections)
        archiveDir = try? c.decode(String.self, forKey: .archiveDir)
    }
}

/// One gesture→server-command binding: report text matching `match` gets a
/// long-press menu of `menu` items; picking one runs `run` on the server with
/// {N} = regex capture group N and {choice} = the picked item (the app shell-
/// quotes each substituted value). Same trust level as workflow steps, which
/// already run arbitrary shell.
struct WorkflowAction: Codable, Equatable, Hashable {
    var match: String
    var menu: [String]
    var run: String

    enum CodingKeys: String, CodingKey { case match, menu, run }
    init(match: String, menu: [String], run: String) {
        self.match = match; self.menu = menu; self.run = run
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        match = (try? c.decode(String.self, forKey: .match)) ?? ""
        menu = (try? c.decode([String].self, forKey: .menu)) ?? []
        run = (try? c.decode(String.self, forKey: .run)) ?? ""
    }
}

/// What gets submitted to `pervio-orchestrate start`.
struct WorkflowSpec: Codable, Equatable {
    var name: String = ""
    var dir: String = "~"
    var steps: [WorkflowStep] = []
    /// Optional presentation contract (collapse hints / long-press actions).
    /// Optional so old specs decode to nil and old apps ignore the keys; the
    /// server passes both through verbatim (no key whitelist in its validator).
    var display: WorkflowDisplay?
    var actions: [WorkflowAction]?
}

extension WorkflowSpec {
    /// The name a daily schedule created from THIS spec carries — the second
    /// half of "the two create paths can never drift" (the first is
    /// `ScheduleFirstIssue`). The editor's Save and the market's one-tap 订阅
    /// both ask here, so they cannot answer differently.
    ///
    /// Why the name has to be a pure function of the SPEC: the market decides
    /// 已订阅 by looking its own answer up in `schedule list`, and a schedule
    /// carries nothing but this name. The market's `title` (a catalog entry's
    /// display name, or a template wrapper's) never reaches the server and never
    /// reaches the editor, so naming a schedule after it produced a name the
    /// editor could not reproduce even in principle: a nameless spec saved in the
    /// editor was invisible to its own market row, whose 订阅 button stayed lit
    /// and, on one tap, minted a second daily schedule that ran and billed twice
    /// every morning.
    var scheduleName: String { name.isEmpty ? Self.unnamedScheduleName : name }

    /// The fallback for a spec that carries no name. It is the editor's historic
    /// string, kept verbatim BECAUSE schedules under it are already on users'
    /// servers: any prettier spelling would converge the two paths onto a name
    /// that fails to recognize the subscriptions people already have — the same
    /// duplicate, one release later.
    static let unnamedScheduleName = "Scheduled workflow"
}

/// One step's live state in the ledger that `pervio-orchestrate` writes.
struct WorkflowStepState: Identifiable, Decodable, Equatable, Hashable {
    let id: String
    let backend: AgentBackend
    /// pending | running | done | failed | skipped
    let status: String
    let output: String
    let error: String
    let bytes: Int
    /// Ids this step waits for (execution/stage ordering) — carried into the ledger
    /// so the phone can lay out the graph even when attaching to a workflow it
    /// didn't start.
    let dependsOn: [String]
    /// Ids whose output this step pulls in ({{id.output}} refs) — the data-flow
    /// edges drawn in the graph (distinct from `dependsOn`, which is just timing).
    let inputs: [String]
    /// Fan-out progress, present only on a fan-out step (children succeeded / failed /
    /// total that ran). Drives a "37/50 done" hint without any per-child nodes.
    let fanoutOk: Int?
    let fanoutFail: Int?
    let fanoutTotal: Int?
    /// True for a command step (a shell line ran instead of an agent turn).
    let isCommand: Bool

    var agent: AgentBackend { backend }
    var isRunning: Bool { status == "running" }
    var isDone: Bool { status == "done" }
    var isFailed: Bool { status == "failed" || status == "skipped" }
    var isFanout: Bool { fanoutTotal != nil }

    enum CodingKeys: String, CodingKey {
        case id, backend, status, output, error, bytes, dependsOn, inputs
        case fanoutOk, fanoutFail, fanoutTotal
        case isCommand = "command"
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        backend = (try? c.decode(AgentBackend.self, forKey: .backend)) ?? .claude
        status = (try? c.decode(String.self, forKey: .status)) ?? "pending"
        output = (try? c.decode(String.self, forKey: .output)) ?? ""
        error = (try? c.decode(String.self, forKey: .error)) ?? ""
        bytes = (try? c.decode(Int.self, forKey: .bytes)) ?? 0
        dependsOn = (try? c.decode([String].self, forKey: .dependsOn)) ?? []
        inputs = (try? c.decode([String].self, forKey: .inputs)) ?? []
        fanoutOk = try? c.decode(Int.self, forKey: .fanoutOk)
        fanoutFail = try? c.decode(Int.self, forKey: .fanoutFail)
        fanoutTotal = try? c.decode(Int.self, forKey: .fanoutTotal)
        isCommand = (try? c.decode(Bool.self, forKey: .isCommand)) ?? false
    }
}

/// One row in the workflow list (`pervio-orchestrate list`), which returns only
/// `{wfId,name,status,startedAt}` per run — no `dir`/`steps`. Kept separate from
/// `WorkflowLedger` so a list row never looks like it carries a (missing) dir.
struct WorkflowSummary: Decodable, Identifiable, Equatable {
    let wfId: String
    let name: String
    /// running | done | failed
    let status: String
    let startedAt: Int
    /// Set when this run was fired by a schedule — the list shows a clock badge.
    let scheduleId: String

    var id: String { wfId }
    var isRunning: Bool { status == "running" }
    var isScheduled: Bool { !scheduleId.isEmpty }
    var startedDate: Date { Date(timeIntervalSince1970: TimeInterval(startedAt)) }

    enum CodingKeys: String, CodingKey { case wfId, name, status, startedAt, scheduleId }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        wfId = (try? c.decode(String.self, forKey: .wfId)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? ""
        startedAt = (try? c.decode(Int.self, forKey: .startedAt)) ?? 0
        scheduleId = (try? c.decode(String.self, forKey: .scheduleId)) ?? ""
    }
}

/// One saved schedule (`pervio-orchestrate schedule list`): a spec the SERVER
/// fires on its own clock (launchd/cron → tick) — the phone plays no part in
/// triggering, it only manages the entries and reads the results.
struct WorkflowSchedule: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    /// "HH:MM", server-local.
    let time: String
    let enabled: Bool
    let keepRuns: Int
    /// Epoch of the next occurrence (0 = unknown/never).
    let nextDue: Int
    let lastFiredAt: Int
    let lastWfId: String
    /// "" | running | done | failed — the most recent run's state.
    let lastStatus: String
    let lastError: String
    /// Server UTC offset like "+0800" — shown so a phone in another timezone
    /// isn't surprised by when "06:30" actually is.
    let tz: String

    var nextDueDate: Date? { nextDue > 0 ? Date(timeIntervalSince1970: TimeInterval(nextDue)) : nil }
    var lastFiredDate: Date? { lastFiredAt > 0 ? Date(timeIntervalSince1970: TimeInterval(lastFiredAt)) : nil }

    enum CodingKeys: String, CodingKey {
        case id, name, time, enabled, keepRuns, nextDue, lastFiredAt, lastWfId
        case lastStatus, lastError, tz
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        time = (try? c.decode(String.self, forKey: .time)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        keepRuns = (try? c.decode(Int.self, forKey: .keepRuns)) ?? 7
        nextDue = (try? c.decode(Int.self, forKey: .nextDue)) ?? 0
        lastFiredAt = (try? c.decode(Int.self, forKey: .lastFiredAt)) ?? 0
        lastWfId = (try? c.decode(String.self, forKey: .lastWfId)) ?? ""
        lastStatus = (try? c.decode(String.self, forKey: .lastStatus)) ?? ""
        lastError = (try? c.decode(String.self, forKey: .lastError)) ?? ""
        tz = (try? c.decode(String.self, forKey: .tz)) ?? ""
    }
}

/// One saved template in the server's library (`pervio-orchestrate templates
/// list` over ~/.pervio/templates/*.json) — written either by Claude from a chat
/// (the market's "Build with Claude" flow) or by the editor's "Save as server
/// template". `ok == false` means the file didn't parse: the row shows `error`
/// and can't open the editor. Field-tolerant like the other wire models.
struct ServerTemplate: Decodable, Identifiable {
    let file: String
    let name: String
    let ok: Bool
    let steps: Int?
    let summary: String?
    let error: String?
    let mtime: Int?
    let spec: WorkflowSpec?
    /// Template kind — nil on old servers and on plain workflow wrappers, which
    /// both mean "workflow". "playbook" = a methodology markdown that gets
    /// LOADED INTO A CONVERSATION (never started/scheduled as a workflow).
    let kind: String?
    /// The playbook's markdown, verbatim (playbook entries only — playbooks are
    /// small, so the listing carries the full text and no second fetch exists).
    let body: String?
    /// "HH:MM" the WRAPPER declared — the daily time a one-tap 订阅 arms this
    /// template at. Read off the wrapper only (like name/summary), never out of
    /// the spec body, so an agent-written spec can't declare its own schedule.
    /// Absent on older servers and on templates that suggest no time: nil then,
    /// and the market subscribes at `PublicationTarget.defaultDailyTime`.
    let suggestedTime: String?

    var id: String { file }
    var mtimeDate: Date? {
        guard let m = mtime, m > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(m))
    }

    var isPlaybook: Bool { kind == "playbook" }
    /// A playbook the app can actually load: listed ok, with a non-empty body.
    /// (A broken playbook file is listed with `error` like any broken template.)
    var isUsablePlaybook: Bool { isPlaybook && ok && !(body ?? "").isEmpty }

    /// The FIXED chat-load text for this playbook: prefix + verbatim body —
    /// what the market's 在对话中用 prefills into a new chat's composer. Nil
    /// unless this is a usable playbook.
    var playbookLoadText: String? {
        guard isUsablePlaybook, let b = body else { return nil }
        return Self.playbookLoadText(name: name.isEmpty ? file : name, body: b)
    }

    /// 载入前缀 is a fixed contract (spec'd verbatim) — do not reword casually:
    /// the server's start-refusal copy points people at this load path. The
    /// Chinese prefix stays byte-for-byte; English is the Settings prompt
    /// language's variant of the SAME contract. The playbook BODY is market
    /// content and rides verbatim in either language.
    static func playbookLoadText(name: String, body: String,
                                 language: PromptLanguage = .current) -> String {
        switch language {
        case .chinese:
            return "【载入剧本:\(name)】以下是本对话要遵循的剧本,读完直接开始执行第一步,不要复述剧本内容:\n\n" + body
        case .english:
            return "[Load playbook: \(name)] The following is the playbook this "
                 + "conversation must follow. Read it, then start with step 1 right "
                 + "away; do not recite the playbook back:\n\n" + body
        }
    }

    enum CodingKeys: String, CodingKey {
        case file, name, ok, steps, summary, error, mtime, spec, kind, body, suggestedTime
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        file = (try? c.decode(String.self, forKey: .file)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        // Default false: a record that can't even say it's ok shouldn't open the
        // editor off a nil/half-decoded spec.
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        steps = try? c.decode(Int.self, forKey: .steps)
        summary = try? c.decode(String.self, forKey: .summary)
        error = try? c.decode(String.self, forKey: .error)
        mtime = try? c.decode(Int.self, forKey: .mtime)
        spec = try? c.decode(WorkflowSpec.self, forKey: .spec)
        kind = try? c.decode(String.self, forKey: .kind)
        body = try? c.decode(String.self, forKey: .body)
        suggestedTime = try? c.decode(String.self, forKey: .suggestedTime)
    }
}

/// One dated markdown issue inside a publication's archive directory
/// (`pervio-orchestrate archives list` → `files`). Field-tolerant like the
/// other wire models.
struct ArchiveFile: Decodable, Identifiable, Equatable {
    let file: String
    let mtime: Int

    var id: String { file }
    var mtimeDate: Date { Date(timeIntervalSince1970: TimeInterval(mtime)) }

    enum CodingKeys: String, CodingKey { case file, mtime }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        file = (try? c.decode(String.self, forKey: .file)) ?? ""
        mtime = (try? c.decode(Int.self, forKey: .mtime)) ?? 0
    }
}

/// One "publication" (`pervio-orchestrate archives list`): a schedule/template
/// spec that declared `display.archiveDir`, with its dated *.md issues newest
/// first. Carries the spec's presentation contract (display/actions) so the
/// reader renders issues exactly like the workflow monitor renders results.
/// Field-tolerant like ServerTemplate; `dir` is the Identifiable id (the
/// server already de-duplicates on it).
struct ArchivePublication: Decodable, Identifiable {
    let name: String
    let dir: String
    let display: WorkflowDisplay?
    let actions: [WorkflowAction]?
    let files: [ArchiveFile]
    /// Schedule join, present only when exactly one schedule publishes into this
    /// directory (the server matches on realpath). All optional — an older
    /// server that doesn't send them decodes to nil and the home card simply
    /// has no schedule awareness (no missed-issue state, no reprint).
    let scheduleId: String?
    let scheduleEnabled: Bool?
    /// "" | running | done | failed — the joined schedule's most recent run.
    let lastStatus: String?
    let lastError: String?
    let lastFiredAt: Int?
    let nextDue: Int?

    var id: String { dir }
    var lastFiredDate: Date? {
        guard let t = lastFiredAt, t > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(t))
    }

    enum CodingKeys: String, CodingKey {
        case name, dir, display, actions, files
        case scheduleId, scheduleEnabled, lastStatus, lastError, lastFiredAt, nextDue
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        dir = (try? c.decode(String.self, forKey: .dir)) ?? ""
        display = try? c.decode(WorkflowDisplay.self, forKey: .display)
        actions = try? c.decode([WorkflowAction].self, forKey: .actions)
        files = (try? c.decode([ArchiveFile].self, forKey: .files)) ?? []
        scheduleId = try? c.decode(String.self, forKey: .scheduleId)
        scheduleEnabled = try? c.decode(Bool.self, forKey: .scheduleEnabled)
        lastStatus = try? c.decode(String.self, forKey: .lastStatus)
        lastError = try? c.decode(String.self, forKey: .lastError)
        lastFiredAt = try? c.decode(Int.self, forKey: .lastFiredAt)
        nextDue = try? c.decode(Int.self, forKey: .nextDue)
    }
}

/// Worktree-isolation summary the server adds to the ledger when a run's parallel
/// write steps executed in git worktrees: where the results are (the integration
/// branch), and whether they were fast-forwarded back onto the user's own branch.
/// Absent on shared (non-isolated) runs.
struct WorkflowGitState: Decodable, Equatable {
    let branch: String
    let merged: Bool
    let note: String

    enum CodingKeys: String, CodingKey { case branch, merged, note }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        branch = (try? c.decode(String.self, forKey: .branch)) ?? ""
        merged = (try? c.decode(Bool.self, forKey: .merged)) ?? false
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
    }
}

/// The ledger `pervio-orchestrate status`/`tail` returns.
struct WorkflowLedger: Decodable, Identifiable, Equatable {
    let wfId: String
    let name: String
    let dir: String
    /// running | done | failed
    let status: String
    let startedAt: Int
    let steps: [WorkflowStepState]
    /// Present only when the run used worktree isolation.
    let git: WorkflowGitState?

    var id: String { wfId }
    var isRunning: Bool { status == "running" }
    var startedDate: Date { Date(timeIntervalSince1970: TimeInterval(startedAt)) }

    enum CodingKeys: String, CodingKey { case wfId, name, dir, status, startedAt, steps, git }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        wfId = (try? c.decode(String.self, forKey: .wfId)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        dir = (try? c.decode(String.self, forKey: .dir)) ?? "~"
        status = (try? c.decode(String.self, forKey: .status)) ?? "running"
        startedAt = (try? c.decode(Int.self, forKey: .startedAt)) ?? 0
        steps = (try? c.decode([WorkflowStepState].self, forKey: .steps)) ?? []
        git = try? c.decode(WorkflowGitState.self, forKey: .git)
    }
}
