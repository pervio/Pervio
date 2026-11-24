import Foundation

// What an engine runs beside the conversation's own thread: the sub-agents it
// spawned and the commands it put in its background. One line above the
// composer counts them; a sheet lists them (2026-11-22, the person: "可以跟后面
// 进程弄在一个框(不然太多就是盖住对话了)只不过可以点击查看一共有多少").
//
// The fields are Claude Code's own (read off the installed 2.1.322 and
// measured on two real turns the same day — the streams are the fixtures in
// ios/Tests/Fixtures/tasks, recorded by server/tests/capture_tasks.py):
//   system/background_tasks_changed  the whole pending BACKGROUND set
//   system/task_started              one task registered; is_backgrounded=false
//                                    is a sub-agent its tool call waits for,
//                                    which the pending set never lists
//   system/task_progress             a sub-agent's running totals, per tool use
//   system/task_updated              a patch (ended, moved to the background)
//   system/task_notification         one ended: status, summary, totals

/// One task that is going: what it is, since when, and — for a sub-agent —
/// how much it has used and what it is doing right now.
struct BackgroundTask: Equatable, Identifiable {
    enum Kind: String, Equatable, Codable {
        case agent, command, other

        /// From Claude Code's `task_type`. Its list grows (local_workflow,
        /// monitor_mcp, mcp_task, …): what is neither a sub-agent nor a shell
        /// command is counted as "other", never guessed into one of the two.
        init(taskType: String) {
            switch taskType {
            case "local_agent", "remote_agent", "in_process_teammate": self = .agent
            case "local_bash": self = .command
            default: self = .other
            }
        }
    }

    let id: String
    var description: String
    let startedAt: Date
    var kind: Kind = .other
    /// "general-purpose", "Explore", a custom agent's name.
    var agentType: String? = nil
    /// The sub-agent that launched this one (a command an agent put in its own background).
    var parentId: String? = nil
    /// The tool call that spawned it is waiting for it: part of the turn, not
    /// of the engine's pending set — so that set never removes it.
    var foreground = false
    var tokens: Int? = nil
    var toolUses: Int? = nil
    /// What it is doing now, in the engine's words ("Running npm test").
    var activity: String? = nil
}

/// One that ended, kept for the list until the process itself is gone.
struct BackgroundTaskRecord: Equatable, Identifiable, Codable {
    let id: String
    let description: String
    var duration: TimeInterval
    /// completed | failed | stopped
    var status: String
    var kind: BackgroundTask.Kind = .other
    var agentType: String? = nil
    var parentId: String? = nil
    var tokens: Int? = nil
    var toolUses: Int? = nil
    /// What it came back with (a sub-agent's answer, "exit code 0" for a command).
    var summary: String? = nil
}

/// The totals a sub-agent reports about itself.
struct BackgroundTaskUsage: Equatable {
    var tokens: Int
    var toolUses: Int
    var durationMs: Int

    init(tokens: Int, toolUses: Int, durationMs: Int) {
        self.tokens = tokens; self.toolUses = toolUses; self.durationMs = durationMs
    }

    init?(_ obj: Any?) {
        guard let u = obj as? [String: Any], let tokens = u["total_tokens"] as? Int else { return nil }
        self.init(tokens: tokens, toolUses: (u["tool_uses"] as? Int) ?? 0, durationMs: (u["duration_ms"] as? Int) ?? 0)
    }
}

/// The two lists and how the engine's events move a task between them — a
/// value, so every step of it is tested without a store or a connection.
struct BackgroundBoard: Equatable {
    var running: [BackgroundTask] = []
    var done: [BackgroundTaskRecord] = []

    // The words and the counts are an engine's — a model's, in the end — so
    // each has a ceiling: a row shows this much, the list holds this many.
    static let rowCap = 300          // running tasks listed
    static let doneCap = 200         // ended ones kept (the latest)
    static let textCap = 300         // a description, what it is doing
    static let summaryCap = 2_000    // what it came back with

    mutating func apply(_ event: AgentEvent, now: Date = Date()) {
        switch event {
        case .backgroundTasks(let set):
            // The pending BACKGROUND set, whole. What we already know of a task
            // stays (its start, its totals); one first heard of now starts now.
            // A sub-agent its tool call waits for is not this set's to remove.
            var next = set.map { row -> BackgroundTask in
                guard var known = running.first(where: { $0.id == row.id }) else { return row }
                known.foreground = false
                // …and what an older Mac's ledger could not say is filled in.
                if known.kind == .other { known.kind = row.kind }
                if known.agentType == nil { known.agentType = row.agentType }
                if known.parentId == nil { known.parentId = row.parentId }
                if known.description.isEmpty { known.description = row.description }
                return known
            }
            next += running.filter { t in t.foreground && !set.contains { $0.id == t.id } }
            running = next
            // A sub-agent sent a further message runs again under the id it ended with.
            done.removeAll { d in set.contains { $0.id == d.id } }

        case .backgroundTaskStarted(let task):
            // Only what the pending set will not announce: a sub-agent in the
            // foreground. (A command in the foreground is the turn's own tool row.)
            guard task.foreground, task.kind == .agent, running.count < Self.rowCap,
                  !running.contains(where: { $0.id == task.id }) else { return }
            done.removeAll { $0.id == task.id }
            running.append(task)

        case .backgroundTaskProgress(let id, let activity, let usage):
            guard let i = running.firstIndex(where: { $0.id == id }) else { return }
            if let activity, !activity.isEmpty { running[i].activity = String(activity.prefix(Self.textCap)) }
            if let usage { running[i].tokens = usage.tokens; running[i].toolUses = usage.toolUses }

        case .backgroundTaskUpdate(let id, let status, let description, let backgrounded):
            if let i = running.firstIndex(where: { $0.id == id }) {
                if let description, !description.isEmpty { running[i].description = String(description.prefix(Self.textCap)) }
                if let backgrounded { running[i].foreground = !backgrounded }
            }
            if let ended = Self.endedStatus(status) { finish(id, status: ended, summary: nil, usage: nil, now: now) }

        case .backgroundTaskDone(let id, let status, let summary, let usage):
            finish(id, status: Self.endedStatus(status) ?? status, summary: summary, usage: usage, now: now)

        case .result:
            // The turn is answered: every tool call it waited for has returned,
            // so a foreground sub-agent still listed is one whose ending we missed.
            running.removeAll { $0.foreground }

        default: break
        }
    }

    /// task_updated says completed | failed | killed (and pending, running,
    /// paused, which end nothing); task_notification says completed | failed |
    /// stopped. One vocabulary for the list.
    private static func endedStatus(_ status: String?) -> String? {
        switch status {
        case "completed": return "completed"
        case "failed": return "failed"
        case "killed", "stopped": return "stopped"
        default: return nil
        }
    }

    private mutating func finish(_ id: String, status: String, summary: String?, usage: BackgroundTaskUsage?, now: Date) {
        let said = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = running.firstIndex(where: { $0.id == id }) {
            let t = running.remove(at: i)
            done.removeAll { $0.id == id }
            // The engine's own figure when it gives one: ours is the phone's
            // clock since it first heard of the task, wrong after a reopen.
            let took = usage.map { TimeInterval($0.durationMs) / 1000 } ?? now.timeIntervalSince(t.startedAt)
            done.append(BackgroundTaskRecord(id: id, description: t.description, duration: max(0, took), status: status,
                                             kind: t.kind, agentType: t.agentType, parentId: t.parentId,
                                             tokens: usage?.tokens ?? t.tokens, toolUses: usage?.toolUses ?? t.toolUses,
                                             summary: (said?.isEmpty ?? true) ? nil : said.map { String($0.prefix(Self.summaryCap)) }))
            if done.count > Self.doneCap { done.removeFirst(done.count - Self.doneCap) }
        } else if let j = done.firstIndex(where: { $0.id == id }) {
            // Already ended by its task_updated; the notification that follows
            // brings what it came back with.
            done[j].status = status
            if let said, !said.isEmpty { done[j].summary = String(said.prefix(Self.summaryCap)) }
            if let usage {
                done[j].tokens = usage.tokens; done[j].toolUses = usage.toolUses
                done[j].duration = TimeInterval(usage.durationMs) / 1000
            }
        }
    }
}

/// What ended beside a conversation's last turn, kept on the phone so that
/// leaving the conversation and coming back still shows the row (2026-11-22,
/// the person's "你不是可以试试看么"). Per saved computer AND conversation — a
/// conversation id alone is the other computer's word, and two computers can
/// say the same one. The next turn sent from here forgets it; so does half a
/// day, since a turn sent from somewhere else never tells this phone.
enum BackgroundDoneShelf {
    static let keep = 50                       // records
    static let summaryKeep = 500               // characters of each one's summary
    static let maxAge: TimeInterval = 12 * 3600

    private struct Saved: Codable { let at: Date; let records: [BackgroundTaskRecord] }
    static func key(profile: UUID, session: String) -> String { "pervio.bgdone.\(profile.uuidString).\(session)" }

    static func save(_ records: [BackgroundTaskRecord], profile: UUID, session: String,
                     now: Date = Date(), defaults: UserDefaults = .standard) {
        guard !records.isEmpty else { return forget(profile: profile, session: session, defaults: defaults) }
        let slim = records.suffix(keep).map { r -> BackgroundTaskRecord in
            var r = r
            r.summary = r.summary.map { String($0.prefix(summaryKeep)) }
            return r
        }
        if let data = try? JSONEncoder().encode(Saved(at: now, records: slim)) {
            defaults.set(data, forKey: key(profile: profile, session: session))
        }
    }

    static func load(profile: UUID, session: String, now: Date = Date(), defaults: UserDefaults = .standard) -> [BackgroundTaskRecord] {
        let k = key(profile: profile, session: session)
        guard let data = defaults.data(forKey: k), let saved = try? JSONDecoder().decode(Saved.self, from: data),
              now.timeIntervalSince(saved.at) < maxAge, now.timeIntervalSince(saved.at) >= -60 else {
            defaults.removeObject(forKey: k)
            return []
        }
        return saved.records
    }

    static func forget(profile: UUID, session: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(profile: profile, session: session))
    }
}

/// How many of what — the one line above the composer, and the sheet's header.
struct BackgroundCount: Equatable {
    var agents = 0, commands = 0, others = 0
    var total: Int { agents + commands + others }

    init(_ kinds: [BackgroundTask.Kind]) {
        for k in kinds {
            switch k {
            case .agent: agents += 1
            case .command: commands += 1
            case .other: others += 1
            }
        }
    }
}

enum BackgroundFormat {
    /// 850 · 9.9k · 13.2k · 128k · 1.2M — the way Claude Code writes a sub-agent's tokens.
    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<100_000: return trimmed(Double(n) / 1000) + "k"
        case ..<1_000_000: return "\(Int((Double(n) / 1000).rounded()))k"
        default: return trimmed(Double(n) / 1_000_000) + "M"
        }
    }

    private static func trimmed(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    /// The rows of one section in the order they are shown: each task, and
    /// right under it whatever it launched itself (one level drawn; deeper
    /// ones follow their own parent). A task whose parent is not in this
    /// section stands on its own — Claude Code's rule for an unknown parent.
    static func nested<T: Identifiable>(_ rows: [T], parent: (T) -> String?) -> [(row: T, depth: Int)] where T.ID == String {
        let ids = Set(rows.map(\.id))
        var out: [(row: T, depth: Int)] = []
        var placed = Set<String>()
        func place(_ r: T, _ depth: Int) {
            guard placed.insert(r.id).inserted else { return }
            out.append((r, depth))
            for c in rows where parent(c) == r.id { place(c, depth + 1) }
        }
        for r in rows where parent(r).map({ !ids.contains($0) || $0 == r.id }) ?? true { place(r, 0) }
        for r in rows { place(r, 0) }          // a loop of parents: nobody is left out
        return out
    }
}
