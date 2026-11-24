import XCTest
@testable import Pervio

/// The line that counts an engine's sub-agents and background commands, and
/// the list behind it (2026-11-22): what Claude Code's task events add up to.
///
/// The first two tests replay REAL streams (ios/Tests/Fixtures/tasks — two
/// turns of claude 2.1.322 recorded by server/tests/capture_tasks.py), so what
/// is checked is what the CLI says, not what we thought it says: every
/// sub-agent a background task by default, a sub-agent's own background
/// command hanging under it, its foreground commands NOT tasks of the
/// conversation, and — where background tasks are off — sub-agents no pending
/// set ever lists.
@MainActor
final class BackgroundBoardTests: XCTestCase {

    private final class BundleToken {}

    /// The store keeps what ended on the phone (BackgroundDoneShelf): nothing
    /// of a test's is left in the simulator's defaults.
    override func tearDown() {
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("pervio.bgdone.") { d.removeObject(forKey: k) }
        super.tearDown()
    }

    private func lines(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        guard let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: "jsonl") else {
            XCTFail("\(name).jsonl is missing from the test bundle — python3 server/tests/capture_tasks.py", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Every distinct state the board went through, and the events themselves.
    private func replay(_ name: String, backend: AgentBackend = .claude) throws -> (states: [BackgroundBoard], events: [AgentEvent]) {
        var board = BackgroundBoard()
        var states: [BackgroundBoard] = []
        var events: [AgentEvent] = []
        for l in try lines(name) {
            for e in AgentEvent.parse(line: l, backend: backend) {
                events.append(e)
                board.apply(e)
                if board != states.last { states.append(board) }
            }
        }
        return (states, events)
    }

    // MARK: - The real streams

    func testTheRealStreamReadsAsTwoSubagentsACommandAndWhatOneOfThemStarted() throws {
        let (states, events) = try replay("claude-subagents-background")
        let listFolder = "ab6e8b369f30be903", helper = "a91373d644fc3d54a", sleep = "bsx66lxmd", helpersOwn = "b4xddh5cd"

        // All three launched: two sub-agents and a command, as the line counts them.
        let launched = try XCTUnwrap(states.first { $0.running.count == 3 })
        XCTAssertEqual(launched.running.map(\.description), ["List the folder", "Slow background helper", "Background sleep"])
        XCTAssertEqual(launched.running.map(\.kind), [.agent, .agent, .command])
        XCTAssertEqual(launched.running.map(\.agentType), ["general-purpose", "general-purpose", nil])
        XCTAssertEqual(L.bgCount(BackgroundCount(launched.running.map(\.kind)), .chinese), "2 个子 agent · 1 个后台命令")
        XCTAssertEqual(L.bgCount(BackgroundCount(launched.running.map(\.kind)), .english), "2 subagents · 1 background command")

        // The helper put a command of its own in the background: a fourth task, under the helper.
        let peak = try XCTUnwrap(states.first { $0.running.count == 4 })
        XCTAssertEqual(peak.running.first { $0.id == helpersOwn }?.parentId, helper)
        XCTAssertEqual(BackgroundFormat.nested(peak.running, parent: \.parentId).map { "\($0.depth):\($0.row.id)" },
                       ["0:\(listFolder)", "0:\(helper)", "1:\(helpersOwn)", "0:\(sleep)"],
                       "the helper's own command is listed right under the helper, one step in")
        XCTAssertEqual(L.bgCount(BackgroundCount(peak.running.map(\.kind)), .chinese), "2 个子 agent · 2 个后台命令",
                       "the line counts every row the list shows")

        // A sub-agent's FOREGROUND commands (`sleep 8`, its until-loop) are task_started /
        // task_notification too — they are that sub-agent's tool calls, not tasks of the conversation.
        let everListed = Set(states.flatMap { $0.running.map(\.id) + $0.done.map(\.id) })
        XCTAssertEqual(everListed, [listFolder, helper, sleep, helpersOwn])
        XCTAssertEqual(states.map(\.running.count).max(), 4)

        // Its totals follow its reports, tool by tool.
        let helperTokens = states.compactMap { $0.running.first { $0.id == helper }?.tokens }
        XCTAssertEqual(helperTokens.reduce(into: [Int]()) { if $0.last != $1 { $0.append($1) } },
                       [9866, 10796, 10924, 11909, 12045, 12501])
        XCTAssertEqual(states.compactMap { $0.running.first { $0.id == listFolder }?.activity }.last, "Running sleep 8")
        XCTAssertEqual(states.compactMap { $0.running.first { $0.id == helper }?.toolUses }.max(), 6)

        // Everything ended, in the order it ended, each with what it came back with.
        let end = try XCTUnwrap(states.last)
        XCTAssertTrue(end.running.isEmpty)
        XCTAssertEqual(end.done.map(\.id), [listFolder, helpersOwn, helper, sleep])
        XCTAssertEqual(end.done.map(\.status), Array(repeating: "completed", count: 4))
        XCTAssertEqual(end.done.map(\.kind), [.agent, .command, .agent, .command])
        let first = end.done[0]
        XCTAssertEqual(first.tokens, 10811); XCTAssertEqual(first.toolUses, 2)
        XCTAssertEqual(first.duration, 12.09, accuracy: 0.001, "the engine's own figure, not the phone's clock")
        XCTAssertTrue(first.summary?.hasPrefix("There are 3 entries") ?? false, first.summary ?? "nil")
        XCTAssertEqual(end.done[1].parentId, helper)
        XCTAssertEqual(end.done[1].summary, #"Background command "sleep 25; echo helper-done" completed (exit code 0)"#)
        XCTAssertNil(end.done[1].tokens, "a command has no totals")
        XCTAssertEqual(end.done[2].tokens, 13165); XCTAssertEqual(end.done[2].toolUses, 6)
        XCTAssertEqual(end.done[2].duration, 29.473, accuracy: 0.001)
        XCTAssertTrue(end.done[2].summary?.hasPrefix("helper-done") ?? false)
        XCTAssertEqual(L.bgEnded(completed: 4, failed: 0, stopped: 0, .chinese), "后台已结束:4 个完成")

        // The conversation itself shows the main thread's three calls and four replies:
        // what the sub-agents did inside stays out of the transcript, as before.
        let calls = events.compactMap { e -> String? in if case .toolUse(let c) = e { return c.name } else { return nil } }
        XCTAssertEqual(calls.count, 3, "\(calls)")
        XCTAssertEqual(events.filter { if case .result = $0 { return true } else { return false } }.count, 4)
    }

    func testWhereBackgroundTasksAreOffTheSubagentsStillShow() throws {
        let (states, events) = try replay("claude-subagents-foreground")
        XCTAssertFalse(events.contains { if case .backgroundTasks = $0 { return true } else { return false } },
                       "this stream never sends a pending set — the sub-agents are known from task_started alone")
        let both = try XCTUnwrap(states.first { $0.running.count == 2 })
        XCTAssertEqual(both.running.map(\.description), ["Count the entries", "Read the note"])
        XCTAssertEqual(both.running.map(\.kind), [.agent, .agent])
        XCTAssertEqual(both.running.map(\.foreground), [true, true])
        XCTAssertEqual(L.bgCount(BackgroundCount(both.running.map(\.kind)), .chinese), "2 个子 agent")
        XCTAssertEqual(Set(states.compactMap { $0.running.first { $0.description == "Read the note" }?.activity }),
                       ["Reading note.txt", "Running sleep 4"])

        let end = try XCTUnwrap(states.last)
        XCTAssertTrue(end.running.isEmpty)
        XCTAssertEqual(end.done.map(\.description), ["Read the note", "Count the entries"], "in the order they ended")
        // task_updated ended it; the notification right after brought what it came back with.
        XCTAssertEqual(end.done[0].summary, "hello")
        XCTAssertEqual(end.done[0].tokens, 11544); XCTAssertEqual(end.done[0].toolUses, 2)
        XCTAssertEqual(end.done[0].duration, 6.716, accuracy: 0.001)
        XCTAssertEqual(end.done.map(\.status), ["completed", "completed"])
    }

    /// Codex runs a sub-agent as a thread of its own; pervio-codex-app reports
    /// it in Claude Code's task words. The fixture is what the adapter made of
    /// a real codex 0.169 turn with two sub-agents (capture_tasks.py --only codex).
    func testACodexTurnsSubagentsReadTheSameWay() throws {
        let (states, events) = try replay("codex-subagents", backend: .codex)
        let both = try XCTUnwrap(states.first { $0.running.count == 2 })
        XCTAssertEqual(both.running.map(\.kind), [.agent, .agent])
        XCTAssertTrue(both.running.allSatisfy { !$0.description.isEmpty && !$0.foreground })
        XCTAssertTrue(both.running.allSatisfy { $0.agentType?.contains("gpt-") ?? false },
                      "a Codex sub-agent's badge is the model it runs on: \(both.running.map(\.agentType))")
        XCTAssertEqual(L.bgCount(BackgroundCount(both.running.map(\.kind)), .chinese), "2 个子 agent")
        XCTAssertTrue(states.contains { $0.running.contains { ($0.activity ?? "").hasPrefix("Running ") && ($0.tokens ?? 0) > 10_000 } },
                      "what a sub-agent runs and how much context it holds reach its row")

        let end = try XCTUnwrap(states.last)
        XCTAssertTrue(end.running.isEmpty)
        XCTAssertEqual(Set(end.done.map(\.id)), Set(both.running.map(\.id)))
        XCTAssertEqual(end.done.map(\.status), ["completed", "completed"])
        XCTAssertTrue(end.done.allSatisfy { !($0.summary ?? "").isEmpty && ($0.tokens ?? 0) > 10_000 && $0.duration > 1 })

        // The conversation shows the conversation's own words only: what a
        // sub-agent came back with is in its row, not in the reply.
        let said = events.compactMap { e -> String? in if case .textDelta(let t) = e { return t } else { return nil } }
        XCTAssertFalse(said.isEmpty)
        for back in end.done.compactMap(\.summary) { XCTAssertFalse(said.contains(back), "a sub-agent's words stood in for the reply: \(back)") }
        XCTAssertEqual(events.filter { if case .result = $0 { return true } else { return false } }.count, 1, "one turn, ended once")
        XCTAssertFalse(events.contains { if case .toolUse = $0 { return true } else { return false } },
                       "the sub-agents' commands are not rows of this conversation")
    }

    // MARK: - The rules, one at a time

    private func task(_ id: String, _ kind: BackgroundTask.Kind = .agent, foreground: Bool = false,
                      parent: String? = nil, at: Date = Date(timeIntervalSince1970: 1_000)) -> BackgroundTask {
        BackgroundTask(id: id, description: "task \(id)", startedAt: at, kind: kind, parentId: parent, foreground: foreground)
    }
    private func parse(_ json: String) -> [AgentEvent] { AgentEvent.parse(line: json, backend: .claude) }

    func testAPendingSetDoesNotRemoveASubagentItsToolCallWaitsFor() {
        var b = BackgroundBoard()
        b.apply(.backgroundTaskStarted(task("fg", foreground: true)))
        b.apply(.backgroundTasks([task("bg", .command)]))
        XCTAssertEqual(b.running.map(\.id), ["bg", "fg"], "the set speaks for background tasks only")
        b.apply(.backgroundTasks([]))
        XCTAssertEqual(b.running.map(\.id), ["fg"])
        // …but once the engine moves it to the background, the set is its only word.
        b.apply(.backgroundTaskUpdate(taskId: "fg", status: nil, description: nil, backgrounded: true))
        XCTAssertEqual(b.running.first?.foreground, false)
        b.apply(.backgroundTasks([]))
        XCTAssertTrue(b.running.isEmpty)
    }

    func testOnlyAForegroundSubagentIsTakenFromTaskStarted() {
        var b = BackgroundBoard()
        b.apply(.backgroundTaskStarted(task("cmd", .command, foreground: true)))     // a sub-agent's `sleep 8`
        b.apply(.backgroundTaskStarted(task("bg-agent", .agent, foreground: false))) // the pending set announces it
        XCTAssertTrue(b.running.isEmpty)
        b.apply(.backgroundTaskStarted(task("fg-agent", .agent, foreground: true)))
        b.apply(.backgroundTaskStarted(task("fg-agent", .agent, foreground: true)))  // said twice: listed once
        XCTAssertEqual(b.running.map(\.id), ["fg-agent"])
    }

    func testAnAnsweredTurnLeavesNoForegroundSubagentBehind() {
        var b = BackgroundBoard()
        b.apply(.backgroundTaskStarted(task("fg", foreground: true)))
        b.apply(.backgroundTasks([task("bg", .command)]))
        b.apply(.result(text: "", sessionId: nil, costUSD: nil, isError: false, contextWindow: nil))
        XCTAssertEqual(b.running.map(\.id), ["bg"], "the turn's tool calls have all returned; a background task goes on")
        XCTAssertTrue(b.done.isEmpty, "an ending we never heard of is not reported as one")
    }

    func testEndingsKeepWhatWasKnownAndSayHowItEnded() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var b = BackgroundBoard()
        b.apply(.backgroundTasks([task("a", at: t0), task("c", .command, parent: "a", at: t0), task("k", at: t0)]))
        b.apply(.backgroundTaskProgress(taskId: "a", activity: "Running npm test", usage: .init(tokens: 9000, toolUses: 3, durationMs: 4000)))
        XCTAssertEqual(b.running[0].tokens, 9000); XCTAssertEqual(b.running[0].activity, "Running npm test")
        b.apply(.backgroundTaskProgress(taskId: "a", activity: "", usage: nil), now: t0)
        XCTAssertEqual(b.running[0].activity, "Running npm test", "an empty report changes nothing")
        b.apply(.backgroundTaskProgress(taskId: "nobody", activity: "x", usage: .init(tokens: 1, toolUses: 1, durationMs: 1)))

        // A command: no totals of its own, so the time is the phone's clock.
        b.apply(.backgroundTaskDone(taskId: "c", status: "failed", summary: "  exit code 1\n", usage: nil), now: t0.addingTimeInterval(42))
        XCTAssertEqual(b.done.last, BackgroundTaskRecord(id: "c", description: "task c", duration: 42, status: "failed",
                                                         kind: .command, parentId: "a", summary: "exit code 1"))
        // A sub-agent with no closing totals keeps the ones it last reported.
        b.apply(.backgroundTaskDone(taskId: "a", status: "completed", summary: nil, usage: nil), now: t0.addingTimeInterval(60))
        XCTAssertEqual(b.done.last?.tokens, 9000); XCTAssertEqual(b.done.last?.toolUses, 3); XCTAssertNil(b.done.last?.summary)
        // Stopped: task_updated says "killed", the notification "stopped" — one word in the list.
        b.apply(.backgroundTaskUpdate(taskId: "k", status: "killed", description: nil, backgrounded: nil), now: t0.addingTimeInterval(61))
        XCTAssertEqual(b.done.last?.status, "stopped")
        b.apply(.backgroundTaskDone(taskId: "k", status: "stopped", summary: "stopped by the user", usage: .init(tokens: 500, toolUses: 1, durationMs: 2500)))
        XCTAssertEqual(b.done.map(\.id), ["c", "a", "k"], "the notification after a task_updated adds to its record, not a second one")
        XCTAssertEqual(b.done.last?.summary, "stopped by the user"); XCTAssertEqual(b.done.last?.duration, 2.5)
        XCTAssertTrue(b.running.isEmpty)
        // An ending for something never listed (a sub-agent's foreground command) is nobody's.
        b.apply(.backgroundTaskDone(taskId: "stranger", status: "completed", summary: "x", usage: nil))
        XCTAssertEqual(b.done.count, 3)
        // An ending that brings the engine's own figure uses it — the phone's
        // clock since it first heard of the task says 5:00 here, the task took 9.5 s.
        b.apply(.backgroundTasks([task("u", at: t0)]))
        b.apply(.backgroundTaskDone(taskId: "u", status: "completed", summary: nil, usage: .init(tokens: 7, toolUses: 1, durationMs: 9_500)),
                now: t0.addingTimeInterval(300))
        XCTAssertEqual(b.done.last?.duration, 9.5)
        // "running" / "paused" end nothing.
        b.apply(.backgroundTasks([task("p")]))
        b.apply(.backgroundTaskUpdate(taskId: "p", status: "paused", description: "renamed", backgrounded: nil))
        XCTAssertEqual(b.running.map(\.description), ["renamed"])
    }

    func testASubagentSentAFurtherMessageRunsAgainUnderItsId() {
        var b = BackgroundBoard()
        b.apply(.backgroundTasks([task("a")]))
        b.apply(.backgroundTaskDone(taskId: "a", status: "completed", summary: "first answer", usage: nil))
        b.apply(.backgroundTasks([]))
        XCTAssertEqual(b.done.map(\.id), ["a"])
        b.apply(.backgroundTasks([task("a")]))
        XCTAssertEqual(b.running.map(\.id), ["a"]); XCTAssertTrue(b.done.isEmpty, "running again: not also listed as ended")
        b.apply(.backgroundTaskDone(taskId: "a", status: "completed", summary: "second answer", usage: nil))
        XCTAssertEqual(b.done.map(\.summary), ["second answer"])
    }

    func testAKnownTaskKeepsItsStartAndGainsWhatAnOlderLedgerCouldNotSay() {
        let seeded = Date(timeIntervalSince1970: 500)
        var b = BackgroundBoard(running: [BackgroundTask(id: "a", description: "deploy", startedAt: seeded)])   // kind unknown
        var row = task("a", .agent, at: Date(timeIntervalSince1970: 9_999)); row.agentType = "Explore"
        b.apply(.backgroundTasks([row]))
        XCTAssertEqual(b.running.first?.startedAt, seeded)
        XCTAssertEqual(b.running.first?.kind, .agent); XCTAssertEqual(b.running.first?.agentType, "Explore")
        XCTAssertEqual(b.running.first?.description, "deploy")
    }

    func testWhatTheEngineCallsHousekeepingIsNotATask() {
        let set = #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"w1","task_type":"monitor_ws","description":"live updates","ambient":true},{"task_id":"d1","task_type":"dream","description":"memory"},{"task_id":"","task_type":"local_bash"}]}"#
        guard case .backgroundTasks(let rows)? = parse(set).first else { return XCTFail() }
        XCTAssertEqual(rows.map(\.id), ["d1"], "ambient is left out (the engine: hosts exclude them from activity indicators); a row with no id is no row")
        XCTAssertEqual(rows.first?.kind, .other, "neither a sub-agent nor a command: counted as other, not guessed")
        let quiet = #"{"type":"system","subtype":"task_started","task_id":"m1","task_type":"local_agent","is_backgrounded":false,"skip_transcript":true,"description":"x"}"#
        XCTAssertTrue(parse(quiet).allSatisfy { if case .ignored = $0 { return true } else { return false } })
    }

    /// A line that is not a whole event must not move anything (the 2026-11-22
    /// review): read as an empty set it took every running task off the page,
    /// and an ending with no status was reported as "completed".
    func testADamagedTaskEventChangesNothing() {
        var b = BackgroundBoard()
        b.apply(.backgroundTasks([task("a"), task("c", .command)]))
        for damaged in [#"{"type":"system","subtype":"background_tasks_changed"}"#,
                        #"{"type":"system","subtype":"background_tasks_changed","tasks":"none"}"#,
                        #"{"type":"system","subtype":"task_notification","task_id":"a"}"#,
                        #"{"type":"system","subtype":"task_notification","status":"completed"}"#,
                        #"{"type":"system","subtype":"task_progress","usage":{"total_tokens":5}}"#] {
            for e in parse(damaged) { b.apply(e) }
        }
        XCTAssertEqual(b.running.map(\.id), ["a", "c"]); XCTAssertTrue(b.done.isEmpty)
    }

    func testWordsAndCountsHaveACeiling() {
        let long = String(repeating: "x", count: 5_000)
        let set = #"{"type":"system","subtype":"background_tasks_changed","tasks":["# + (0..<400).map { #"{"task_id":"t\#($0)","task_type":"local_agent","description":"\#(long)","subagent_type":"\#(long)"}"# }.joined(separator: ",") + "]}"
        guard case .backgroundTasks(let rows)? = parse(set).first else { return XCTFail() }
        XCTAssertEqual(rows.count, BackgroundBoard.rowCap)
        XCTAssertEqual(rows.first?.description.count, BackgroundBoard.textCap); XCTAssertEqual(rows.first?.agentType?.count, 80)
        var b = BackgroundBoard()
        for i in 0..<(BackgroundBoard.doneCap + 25) {
            b.apply(.backgroundTasks([task("t\(i)")]))
            b.apply(.backgroundTaskProgress(taskId: "t\(i)", activity: long, usage: nil))
            XCTAssertEqual(b.running.first?.activity?.count, BackgroundBoard.textCap)
            b.apply(.backgroundTaskDone(taskId: "t\(i)", status: "completed", summary: long + long, usage: nil))
        }
        XCTAssertEqual(b.done.count, BackgroundBoard.doneCap, "the latest are kept")
        XCTAssertEqual(b.done.last?.id, "t\(BackgroundBoard.doneCap + 24)"); XCTAssertEqual(b.done.first?.id, "t25")
        XCTAssertEqual(b.done.last?.summary?.count, BackgroundBoard.summaryCap)
    }

    func testTheTaskEventsParseWithTheirFields() {
        let started = #"{"type":"system","subtype":"task_started","task_id":"a7","tool_use_id":"toolu_1","description":"Count the entries","subagent_type":"general-purpose","is_backgrounded":false,"spawn_depth":1,"task_type":"local_agent","prompt":"…"}"#
        guard case .backgroundTaskStarted(let t)? = parse(started).first else { return XCTFail() }
        XCTAssertEqual(t.id, "a7"); XCTAssertEqual(t.kind, .agent); XCTAssertEqual(t.agentType, "general-purpose")
        XCTAssertTrue(t.foreground); XCTAssertNil(t.parentId)
        let owned = #"{"type":"system","subtype":"task_started","task_id":"b4","owned_by_subagent":true,"description":"sleep 25","is_backgrounded":true,"parent_task_id":"a7","task_type":"local_bash"}"#
        guard case .backgroundTaskStarted(let c)? = parse(owned).first else { return XCTFail() }
        XCTAssertEqual(c.kind, .command); XCTAssertEqual(c.parentId, "a7"); XCTAssertFalse(c.foreground)
        let progress = #"{"type":"system","subtype":"task_progress","task_id":"a7","description":"Running ls -la","subagent_type":"general-purpose","usage":{"total_tokens":9871,"tool_uses":1,"duration_ms":1651},"last_tool_name":"Bash"}"#
        guard case .backgroundTaskProgress(let id, let activity, let usage)? = parse(progress).first else { return XCTFail() }
        XCTAssertEqual(id, "a7"); XCTAssertEqual(activity, "Running ls -la")
        XCTAssertEqual(usage, BackgroundTaskUsage(tokens: 9871, toolUses: 1, durationMs: 1651))
        let updated = #"{"type":"system","subtype":"task_updated","task_id":"a7","patch":{"status":"completed","end_time":1795327254171,"is_backgrounded":true}}"#
        guard case .backgroundTaskUpdate(_, let status, let description, let backgrounded)? = parse(updated).first else { return XCTFail() }
        XCTAssertEqual(status, "completed"); XCTAssertNil(description); XCTAssertEqual(backgrounded, true)
        let note = #"{"type":"system","subtype":"task_notification","task_id":"a7","status":"failed","output_file":"","summary":"it broke","usage":{"total_tokens":10811,"tool_uses":2,"duration_ms":12090}}"#
        guard case .backgroundTaskDone(_, let ended, let summary, let totals)? = parse(note).first else { return XCTFail() }
        XCTAssertEqual(ended, "failed"); XCTAssertEqual(summary, "it broke"); XCTAssertEqual(totals?.durationMs, 12090)
        XCTAssertEqual([BackgroundTask.Kind(taskType: "local_agent"), .init(taskType: "remote_agent"), .init(taskType: "in_process_teammate"),
                        .init(taskType: "local_bash"), .init(taskType: "local_workflow"), .init(taskType: "")],
                       [.agent, .agent, .agent, .command, .other, .other])
    }

    // MARK: - How it is said

    func testTokensAreWrittenTheWayClaudeCodeWritesThem() {
        XCTAssertEqual([0, 850, 999, 1000, 9871, 13165, 99_949, 128_400, 999_499, 1_240_000].map(BackgroundFormat.tokens),
                       ["0", "850", "999", "1k", "9.9k", "13.2k", "99.9k", "128k", "999k", "1.2M"])
    }

    func testTheCountLeavesOutWhatThereIsNoneOf() {
        XCTAssertEqual(L.bgCount(BackgroundCount([.agent]), .chinese), "1 个子 agent")
        XCTAssertEqual(L.bgCount(BackgroundCount([.agent]), .english), "1 subagent")
        XCTAssertEqual(L.bgCount(BackgroundCount([.command, .command]), .english), "2 background commands")
        XCTAssertEqual(L.bgCount(BackgroundCount([.other, .agent, .agent, .command]), .chinese), "2 个子 agent · 1 个后台命令 · 1 个其他任务")
        XCTAssertEqual(L.bgBar(BackgroundCount([.agent, .command]), "3:12", .chinese), "1 个子 agent · 1 个后台命令 · 3:12")
        XCTAssertEqual(BackgroundCount([.other, .agent, .agent, .command]).total, 4)
        XCTAssertEqual(L.bgEnded(completed: 2, failed: 1, stopped: 1, .chinese), "后台已结束:2 个完成 · 1 个出错 · 1 个已停止")
        XCTAssertEqual(L.bgEnded(completed: 0, failed: 1, stopped: 0, .english), "Background ended: 1 failed")
    }

    func testNestingNeverLosesARow() {
        let rows = [task("child", .command, parent: "p"), task("p"), task("orphan", .command, parent: "gone"),
                    task("loop-a", parent: "loop-b"), task("loop-b", parent: "loop-a"), task("self", parent: "self"),
                    task("grandchild", .command, parent: "child")]
        let placed = BackgroundFormat.nested(rows, parent: \.parentId).map { "\($0.depth):\($0.row.id)" }
        XCTAssertEqual(placed, ["0:p", "1:child", "2:grandchild", "0:orphan", "0:self", "0:loop-a", "1:loop-b"],
                       "a parent that is not in the list is no parent (Claude Code's own rule); a loop still shows both")
        XCTAssertEqual(Set(placed.map { String($0.split(separator: ":")[1]) }).count, rows.count)
    }

    // MARK: - Through the store

    private func settle(ms: UInt64 = 25, _ done: () -> Bool) async throws {
        for _ in 0..<80 where !done() { try await Task.sleep(nanoseconds: ms * 1_000_000) }
    }
    private let result = AgentEvent.result(text: "", sessionId: "sess-A", costUSD: nil, isError: false, contextWindow: nil)

    func testARunsSubagentsReachTheLineWithTheirTotalsAndEndInTheList() async throws {
        var profile = TestFactory.profile(); profile.runMode = true
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        var agent = task("a1"); agent.agentType = "general-purpose"
        fake.runEvents = [.backgroundTasks([agent, task("b1", .command, parent: "a1")]),
                          .backgroundTaskProgress(taskId: "a1", activity: "Running pytest", usage: .init(tokens: 12045, toolUses: 3, durationMs: 900)),
                          .textDelta("launched"), result]
        fake.runEventsAfterResult = [.backgroundTaskDone(taskId: "b1", status: "completed", summary: "exit code 0", usage: nil),
                                     .backgroundTasks([agent]),
                                     .backgroundTaskUpdate(taskId: "a1", status: "completed", description: nil, backgrounded: nil),
                                     .backgroundTaskDone(taskId: "a1", status: "completed", summary: "review done",
                                                         usage: .init(tokens: 13165, toolUses: 6, durationMs: 29_473)),
                                     .backgroundTasks([]), .textDelta("review done"), result]
        fake.runEventsAfterResultDelayMs = 400
        let s = ChatStore(profile: profile, secret: "secret", resumeSessionId: "sess-A", ssh: fake)
        await s.connect()
        let turn = Task { await s.send("review it") }
        try await settle { s.lingeringRunId != nil }
        XCTAssertEqual(s.backgroundTasks.map(\.id), ["a1", "b1"])
        XCTAssertEqual(s.backgroundTasks.first?.tokens, 12045); XCTAssertEqual(s.backgroundTasks.first?.activity, "Running pytest")
        XCTAssertEqual(L.bgCount(BackgroundCount(s.backgroundTasks.map(\.kind)), .chinese), "1 个子 agent · 1 个后台命令")
        try await settle { s.backgroundTasks.isEmpty && s.backgroundDone.count == 2 }
        XCTAssertEqual(s.backgroundDone.map(\.id), ["b1", "a1"])
        XCTAssertEqual(s.backgroundDone.last?.tokens, 13165); XCTAssertEqual(s.backgroundDone.last?.summary, "review done")
        XCTAssertEqual(s.backgroundDone.last?.duration ?? 0, 29.473, accuracy: 0.001)
        s.stop(); turn.cancel()
    }

    func testOneTaskIsStoppedOnItsOwnThroughTheLivingRun() async throws {
        var profile = TestFactory.profile(); profile.runMode = true
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.backgroundTasks([task("a1"), task("c1", .command)]), .textDelta("launched"), result]
        // What the engine says once it has stopped the task (Claude Code 2.1.322, measured).
        fake.runEventsAfterResult = [.backgroundTaskUpdate(taskId: "a1", status: "killed", description: nil, backgrounded: nil),
                                     .backgroundTaskDone(taskId: "a1", status: "stopped", summary: "task a1", usage: nil),
                                     .backgroundTasks([task("c1", .command)])]
        fake.runEventsAfterResultDelayMs = 700
        let s = ChatStore(profile: profile, secret: "secret", resumeSessionId: "sess-A", ssh: fake)
        await s.connect()
        let turn = Task { await s.send("go") }
        try await settle { s.lingeringRunId != nil }
        XCTAssertTrue(s.canStopBackgroundTasks, "a living Claude run: there is an input to ask through")
        await s.stopBackgroundTask("a1")
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("stopTask") }, ["stopTask run-1 a1"], "that task of that run, nothing else")
        XCTAssertFalse(fake.calls.contains("stopRun"), "the run itself is not stopped")
        XCTAssertEqual(s.stoppingTasks, ["a1"])
        XCTAssertEqual(s.backgroundTasks.map(\.id), ["a1", "c1"], "the row stays until the ENGINE says it ended")
        await s.stopBackgroundTask("a1")
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("stopTask") }.count, 1, "asked once, however often the key is tapped")
        try await settle(ms: 50) { s.backgroundDone.contains { $0.id == "a1" } }
        XCTAssertEqual(s.backgroundDone.first { $0.id == "a1" }?.status, "stopped")
        XCTAssertEqual(s.backgroundTasks.map(\.id), ["c1"], "the other task goes on")
        XCTAssertTrue(s.stoppingTasks.isEmpty)
        // The run has let go meanwhile: said so, and the row is not left "stopping".
        fake.stopTaskError = NSError(domain: "test", code: 4)
        await s.stopBackgroundTask("c1")
        XCTAssertTrue(s.stoppingTasks.isEmpty)
        XCTAssertEqual(s.messages.last?.role, .system)
        XCTAssertTrue(s.messages.last?.text.contains("task c1") ?? false, s.messages.last?.text ?? "nil")
        s.stop(); turn.cancel()
    }

    func testWhereOneTaskCannotBeStoppedNoKeyIsOffered() async throws {
        // A Chat turn: its process has no input left to write to.
        let chat = FakeSSH()
        chat.chatEvents([.backgroundTasks([task("a1")]), .textDelta("x"), result])
        chat.pauseChat(before: 1)
        let c = ChatStore(profile: TestFactory.profile(), secret: "secret", resumeSessionId: "sess-A", ssh: chat)
        await c.connect()
        let turn = Task { await c.send("look") }
        await chat.awaitChatPaused()
        try await settle { !c.backgroundTasks.isEmpty }
        XCTAssertFalse(c.canStopBackgroundTasks)
        await c.stopBackgroundTask("a1")
        XCTAssertFalse(chat.calls.contains { $0.hasPrefix("stopTask") })
        chat.releaseChat(); await turn.value
        // A Codex run: its sub-agent can be interrupted, but its main agent then waits on (measured) — not offered.
        var profile = TestFactory.profile(); profile.runMode = true; profile.backend = .codex
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.backgroundTasks([task("a1")]), .textDelta("launched"), result]
        let s = ChatStore(profile: profile, secret: "secret", resumeSessionId: "sess-A", ssh: fake)
        await s.connect()
        let run = Task { await s.send("go") }
        try await settle { s.lingeringRunId != nil }
        XCTAssertFalse(s.canStopBackgroundTasks)
        s.stop(); run.cancel()
    }

    // MARK: - Coming back to the conversation

    func testWhatEndedIsKeptPerComputerAndConversationAndNotForLong() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "bgdone-\(UUID().uuidString)"))
        let mac = UUID(), other = UUID(), t0 = Date(timeIntervalSince1970: 2_000_000)
        let records = (0..<60).map { BackgroundTaskRecord(id: "t\($0)", description: "task \($0)", duration: 3, status: "completed",
                                                          kind: .agent, agentType: "Explore", tokens: 900, toolUses: 2,
                                                          summary: String(repeating: "s", count: 3_000)) }
        BackgroundDoneShelf.save(records, profile: mac, session: "sess-1", now: t0, defaults: d)
        let back = BackgroundDoneShelf.load(profile: mac, session: "sess-1", now: t0.addingTimeInterval(600), defaults: d)
        XCTAssertEqual(back.map(\.id), records.suffix(BackgroundDoneShelf.keep).map(\.id), "the latest ones")
        XCTAssertEqual(back.last?.agentType, "Explore"); XCTAssertEqual(back.last?.tokens, 900); XCTAssertEqual(back.last?.kind, .agent)
        XCTAssertEqual(back.last?.summary?.count, BackgroundDoneShelf.summaryKeep)
        XCTAssertTrue(BackgroundDoneShelf.load(profile: other, session: "sess-1", now: t0, defaults: d).isEmpty,
                      "another saved computer's conversation of the same id is another conversation")
        XCTAssertTrue(BackgroundDoneShelf.load(profile: mac, session: "sess-2", now: t0, defaults: d).isEmpty)
        XCTAssertTrue(BackgroundDoneShelf.load(profile: mac, session: "sess-1", now: t0.addingTimeInterval(13 * 3600), defaults: d).isEmpty,
                      "half a day on, a turn may have been sent from somewhere else: not shown")
        XCTAssertNil(d.data(forKey: BackgroundDoneShelf.key(profile: mac, session: "sess-1")), "…and not kept either")
        BackgroundDoneShelf.save(records, profile: mac, session: "sess-1", now: t0, defaults: d)
        BackgroundDoneShelf.save([], profile: mac, session: "sess-1", now: t0, defaults: d)
        XCTAssertNil(d.data(forKey: BackgroundDoneShelf.key(profile: mac, session: "sess-1")), "nothing ended is nothing stored")
    }

    func testLeavingAndComingBackStillShowsWhatEndedUntilTheNextTurn() async throws {
        var profile = TestFactory.profile(); profile.runMode = true
        let sid = "sess-shelf-\(UUID().uuidString.prefix(8))"
        defer { BackgroundDoneShelf.forget(profile: profile.id, session: sid) }
        // (The engine's result names the conversation: this one keeps its id.)
        let result = AgentEvent.result(text: "", sessionId: sid, costUSD: nil, isError: false, contextWindow: nil)
        let fake = FakeSSH()
        fake.runTailStaysOpen = true
        fake.runEvents = [.backgroundTasks([task("a1")]), .textDelta("launched"), result]
        fake.runEventsAfterResult = [.backgroundTaskDone(taskId: "a1", status: "completed", summary: "review done",
                                                         usage: .init(tokens: 13165, toolUses: 6, durationMs: 29_473)),
                                     .backgroundTasks([])]
        fake.runEventsAfterResultDelayMs = 200
        let s = ChatStore(profile: profile, secret: "secret", resumeSessionId: sid, ssh: fake)
        await s.connect()
        let turn = Task { await s.send("review it") }
        try await settle { s.backgroundDone.count == 1 }
        s.stop(); turn.cancel()

        // Left, and opened again: a store of its own, as the page makes one.
        let again = ChatStore(profile: profile, secret: "secret", resumeSessionId: sid, ssh: FakeSSH())
        XCTAssertEqual(again.backgroundDone.map(\.id), ["a1"], "the row is still there")
        XCTAssertEqual(again.backgroundDone.first?.summary, "review done"); XCTAssertEqual(again.backgroundDone.first?.tokens, 13165)
        XCTAssertTrue(again.backgroundTasks.isEmpty)
        var elsewhere = profile; elsewhere.id = UUID()
        XCTAssertTrue(ChatStore(profile: elsewhere, secret: "secret", resumeSessionId: sid, ssh: FakeSSH()).backgroundDone.isEmpty,
                      "not on another saved computer that happens to have a conversation of this id")

        // The next turn from here is a new one: forgotten, on the page and on the shelf.
        let next = FakeSSH()
        next.runTailStaysOpen = true
        next.runEvents = [.textDelta("ok"), result]
        let third = ChatStore(profile: profile, secret: "secret", resumeSessionId: sid, ssh: next)
        await third.connect()
        let t2 = Task { await third.send("and now?") }
        try await settle { third.messages.last?.text == "ok" }
        XCTAssertTrue(third.backgroundDone.isEmpty)
        XCTAssertTrue(ChatStore(profile: profile, secret: "secret", resumeSessionId: sid, ssh: FakeSSH()).backgroundDone.isEmpty)
        third.stop(); t2.cancel()
    }

    func testReopeningARunRestoresEachTaskAsWhatItIs() async throws {
        var profile = TestFactory.profile(); profile.runMode = true
        let fake = FakeSSH()
        fake.runsJSON = #"[{"runId":"run-9","sessionId":"sess-A","dir":"/w","preview":"p","started":1,"state":"running","bytes":4321,"replied":true,"accepting":true,"turnFrom":4321,"background":[{"taskId":"a1","description":"Review the diff","startedAt":1792500000,"taskType":"local_agent","agentType":"general-purpose","tokens":12045,"toolUses":3,"activity":"Running pytest"},{"taskId":"b1","description":"pytest -q","startedAt":1792500005,"taskType":"local_bash","parent":"a1"},{"taskId":"w1","description":"live updates","startedAt":1792500006,"taskType":"monitor_ws","ambient":true}]}]"#
        fake.runTailStaysOpen = true
        fake.runEvents = []
        let s = ChatStore(profile: profile, secret: "secret", resumeSessionId: "sess-A", ssh: fake)
        let opening = Task { await s.start() }
        try await settle { s.lingeringRunId == "run-9" }
        XCTAssertEqual(s.backgroundTasks.map(\.id), ["a1", "b1"], "the housekeeping row is not shown")
        XCTAssertEqual(s.backgroundTasks.map(\.kind), [.agent, .command])
        let a = try XCTUnwrap(s.backgroundTasks.first)
        XCTAssertEqual(a.agentType, "general-purpose"); XCTAssertEqual(a.tokens, 12045); XCTAssertEqual(a.toolUses, 3)
        XCTAssertEqual(a.activity, "Running pytest"); XCTAssertEqual(a.startedAt, Date(timeIntervalSince1970: 1_792_500_000))
        XCTAssertEqual(s.backgroundTasks.last?.parentId, "a1")
        s.stop(); opening.cancel()
    }

    func testAChatTurnCountsItsSubagentsWhileItLastsAndTakesThemWithIt() async throws {
        let fake = FakeSSH()                                    // Chat mode: the turn is one stream, one process
        fake.chatEvents([.backgroundTaskStarted(task("fg", foreground: true)),
                         .backgroundTaskProgress(taskId: "fg", activity: "Reading a.swift", usage: .init(tokens: 4000, toolUses: 1, durationMs: 800)),
                         .backgroundTaskDone(taskId: "fg", status: "completed", summary: "read", usage: nil),
                         .backgroundTasks([task("left", .command)]),         // still going when the process ends
                         .textDelta("done"), result])
        fake.pauseChat(before: 2)
        let s = ChatStore(profile: TestFactory.profile(), secret: "secret", resumeSessionId: "sess-A", ssh: fake)
        await s.connect()
        let turn = Task { await s.send("look") }
        await fake.awaitChatPaused()
        try await settle { s.backgroundTasks.first?.tokens != nil }      // what was yielded before the pause, taken in
        XCTAssertEqual(s.backgroundTasks.map(\.id), ["fg"], "a sub-agent of a chat turn is counted too")
        XCTAssertEqual(s.backgroundTasks.first?.tokens, 4000)
        fake.releaseChat()
        await turn.value
        XCTAssertTrue(s.backgroundTasks.isEmpty, "the turn's process ended with its stream: nothing runs, whatever it had left going")
        XCTAssertEqual(s.backgroundDone.map(\.summary), ["read"], "what ended stays listed under the reply")
        XCTAssertEqual(s.messages.last?.text, "done")
        fake.chatEvents([.textDelta("again"), result])
        await s.send("once more")
        XCTAssertTrue(s.backgroundDone.isEmpty, "the next turn starts clean")
    }
}
