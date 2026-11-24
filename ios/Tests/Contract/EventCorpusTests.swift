import XCTest
@testable import Pervio

/// Feeds `AgentEvent.parse` the REAL event streams in ios/Tests/Fixtures/events —
/// byte-for-byte copies of server/tests/corpus, which are the verbatim stdout of
/// real `claude` and `codex` turns (captured by server/tests/capture_corpus.py,
/// redacted only in the values its header lists).
///
/// Everything the app knows about these two wire formats used to be checked against
/// JSON we wrote ourselves, so the tests could only ever confirm our own
/// assumptions. These run against what the CLIs actually emit — including the parts
/// we did NOT anticipate (claude's `rate_limit_event`, `system/thinking_tokens` and
/// `signature_delta`; codex's item-level `error`), which is the whole point.
final class EventCorpusTests: XCTestCase {

    // MARK: - loading

    private final class BundleToken {}

    /// One corpus file, split into lines, already parsed by the shipping parser.
    private func events(_ name: String, _ backend: AgentBackend,
                        file: StaticString = #filePath, line: UInt = #line) throws -> [AgentEvent] {
        try lines(name, file: file, line: line)
            .flatMap { AgentEvent.parse(line: $0, backend: backend) }
    }

    private func lines(_ name: String,
                       file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "jsonl") else {
            XCTFail("event corpus \(name).jsonl is missing from the test bundle — "
                    + "re-sync: python3 server/tests/capture_corpus.py --rescrub",
                    file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - shorthands over the enum (it is deliberately not Equatable)

    private func textDeltas(_ evs: [AgentEvent]) -> [String] {
        evs.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }
    }
    private func thinkingDeltas(_ evs: [AgentEvent]) -> [String] {
        evs.compactMap { if case .thinkingDelta(let t) = $0 { return t } else { return nil } }
    }
    private func toolUses(_ evs: [AgentEvent]) -> [ToolCall] {
        evs.compactMap { if case .toolUse(let c) = $0 { return c } else { return nil } }
    }
    private func toolResults(_ evs: [AgentEvent]) -> [(String, String)] {
        evs.compactMap {
            if case .toolResult(let id, let t) = $0 { return (id, t) } else { return nil }
        }
    }
    private func contextUsages(_ evs: [AgentEvent]) -> [Int] {
        evs.compactMap { if case .contextUsage(let n) = $0 { return n } else { return nil } }
    }
    private func initialized(_ evs: [AgentEvent]) -> (String, String?)? {
        for e in evs { if case .initialized(let sid, let m) = e { return (sid, m) } }
        return nil
    }
    private func results(_ evs: [AgentEvent]) -> [(String, String?, Double?, Bool, Int?)] {
        evs.compactMap {
            if case .result(let t, let s, let c, let e, let w) = $0 { return (t, s, c, e, w) }
            return nil
        }
    }
    private func permissionRequests(_ evs: [AgentEvent]) -> [(String, ToolCall)] {
        evs.compactMap {
            if case .permissionRequest(let id, let c) = $0 { return (id, c) } else { return nil }
        }
    }
    private func streamErrors(_ evs: [AgentEvent]) -> [String] {
        evs.compactMap { if case .streamError(let m) = $0 { return m } else { return nil } }
    }

    private let sid = "00000000-0000-4000-8000-000000000001"   // every capture's redacted id

    // MARK: - claude: a plain turn, end to end

    func testClaudeTextStreamParsesInitTextAndResult() throws {
        let evs = try events("claude-text", .claude)

        let ini = try XCTUnwrap(initialized(evs), "system/init must open the stream")
        XCTAssertEqual(ini.0, sid)
        XCTAssertEqual(ini.1, "claude-haiku-4-5-20251001")     // the cheap tier we paid for

        // Deltas are SHARDS: the point of --include-partial-messages. Assert the
        // stream really was chunked, and that concatenating it rebuilds the answer.
        let deltas = textDeltas(evs)
        XCTAssertFalse(deltas.isEmpty, "no text_delta reached the parser")
        XCTAssertTrue(deltas.joined().contains("The corpus is alive."), deltas.joined())

        // Context fullness comes from the per-request assistant usage, never from
        // the turn-cumulative `result` usage.
        let ctx = contextUsages(evs)
        XCTAssertFalse(ctx.isEmpty)
        XCTAssertTrue(ctx.allSatisfy { $0 > 0 })

        let res = results(evs)
        XCTAssertEqual(res.count, 1, "exactly one terminal result")
        XCTAssertEqual(res[0].0, "The corpus is alive.")
        XCTAssertEqual(res[0].1, sid)
        XCTAssertEqual(res[0].3, false)                        // isError
        XCTAssertGreaterThan(try XCTUnwrap(res[0].2), 0)       // real money changed hands
        XCTAssertGreaterThan(try XCTUnwrap(res[0].4), 0)       // contextWindow from modelUsage
    }

    /// Event types this build of the CLI emits that the parser has never heard of
    /// (`rate_limit_event`, `system/thinking_tokens`) must fall through as
    /// `.ignored` — not crash, and not invent a bubble.
    func testClaudeUnknownEventTypesAreIgnoredNotInvented() throws {
        let raw = try lines("claude-text")
        let unknown = raw.filter { $0.contains("\"rate_limit_event\"") || $0.contains("thinking_tokens") }
        XCTAssertFalse(unknown.isEmpty, "the corpus should still contain the unknown types")
        for line in unknown {
            let evs = AgentEvent.parse(line: line, backend: .claude)
            XCTAssertTrue(evs.allSatisfy { if case .ignored = $0 { return true } else { return false } },
                          "an unrecognised claude event produced a real event: \(line.prefix(80))")
        }
    }

    // MARK: - claude: thinking

    func testClaudeThinkingStreamProducesThinkingShardsOnly() throws {
        let evs = try events("claude-think", .claude)
        let think = thinkingDeltas(evs)
        XCTAssertFalse(think.isEmpty, "no thinking_delta reached the parser")
        XCTAssertGreaterThan(think.joined().count, 20)
        // signature_delta rides the same content_block_delta envelope and must NOT
        // be mistaken for thinking text.
        XCTAssertFalse(think.joined().contains("signature"))
        XCTAssertTrue(textDeltas(evs).joined().contains("28"))   // the real answer
    }

    // MARK: - claude: tools

    func testClaudeToolStreamCarriesCallsAndResults() throws {
        let evs = try events("claude-tools", .claude)

        let tools = toolUses(evs)
        XCTAssertEqual(tools.map(\.name), ["Write", "Read"])

        let write = try XCTUnwrap(tools.first)
        XCTAssertEqual(write.filePath, "/home/pervio/work/note.txt")
        XCTAssertEqual(write.content, "corpus")                 // Write's payload
        XCTAssertEqual(write.label, "Write  .../work/note.txt")   // last two path segments
        XCTAssertTrue(write.hasDetail)
        XCTAssertTrue(write.toolUseId?.hasPrefix("toolu_") ?? false)

        // Tool results echo back on user-role lines; each must find its call by id.
        let ids = Set(tools.compactMap(\.toolUseId))
        let answers = toolResults(evs)
        XCTAssertFalse(answers.isEmpty)
        XCTAssertTrue(answers.allSatisfy { ids.contains($0.0) },
                      "a tool_result referenced an id no tool_use ever announced")
        XCTAssertTrue(answers.contains { $0.1.contains("corpus") },
                      "the Read result should echo the file's line")

        XCTAssertEqual(results(evs).first?.0, "done")
    }

    // MARK: - claude: plan mode

    func testClaudePlanStreamProducesTheExitPlanModeChip() throws {
        let evs = try events("claude-plan", .claude)
        let plan = try XCTUnwrap(toolUses(evs).first { $0.name == "ExitPlanMode" },
                                 "no ExitPlanMode call in a plan-mode turn")
        // The chip is labelled by what tapping it does, byte-identical to
        // pervio-sessions' _tool_label, so live and reloaded turns render the same.
        XCTAssertEqual(plan.label, "Plan ready · tap to review")
        XCTAssertEqual(plan.content?.isEmpty, false, "the plan text must ride on the call")
        XCTAssertTrue(plan.canShowDetail)
    }

    // MARK: - claude: approvals (no codex twin exists — codex exec cannot ask)

    func testClaudeApprovalStreamSurfacesTheBlockedToolAndItsDenial() throws {
        let evs = try events("claude-approval", .claude)

        let reqs = permissionRequests(evs)
        XCTAssertEqual(reqs.count, 1, "the blocked Write must reach the phone exactly once")
        let (rid, call) = reqs[0]
        XCTAssertFalse(rid.isEmpty)
        XCTAssertEqual(call.name, "Write")
        XCTAssertEqual(call.filePath, "/home/pervio/work/approved.txt")
        XCTAssertEqual(call.content, "ok")

        // pervio-approve's resolution line and pervio-hb's heartbeat share the channel;
        // neither may become a bubble. The resolution is an event since 2026-10-19
        // (it dismisses a request a reopened run replays), still never text.
        for line in try lines("claude-approval")
        where line.contains("permission_resolved") || line.contains("\"heartbeat\"") {
            XCTAssertTrue(AgentEvent.parse(line: line, backend: .claude)
                .allSatisfy { switch $0 { case .ignored, .permissionResolved: return true; default: return false } },
                          "channel bookkeeping leaked into the transcript: \(line.prefix(60))")
        }

        // The turn still ends normally — a denial is not a stream error.
        let res = try XCTUnwrap(results(evs).first)
        XCTAssertEqual(res.3, false)
        XCTAssertFalse(res.0.isEmpty)
    }

    // MARK: - claude / codex: the failing turn (twins)

    func testClaudeErrorStreamMarksTheResultAsAnError() throws {
        let evs = try events("claude-error", .claude)
        let res = try XCTUnwrap(results(evs).first)
        XCTAssertTrue(res.3, "is_error must survive; subtype is still \"success\" here")
        XCTAssertTrue(res.0.contains("claude-nope-9"), res.0)
        XCTAssertEqual(res.1, sid)
    }

    func testCodexErrorStreamSurfacesBothTheErrorAndTheFailedTurn() throws {
        let evs = try events("codex-error", .codex)
        XCTAssertEqual(streamErrors(evs).count, 1)
        XCTAssertTrue(streamErrors(evs)[0].contains("gpt-nope-9"), streamErrors(evs)[0])
        let res = try XCTUnwrap(results(evs).first)
        XCTAssertTrue(res.3, "turn.failed must arrive as an error result")
        XCTAssertNil(res.2, "codex exec reports no cost")
    }

    /// Characterisation, not endorsement: this build of codex also reports failures
    /// as `item.completed` with `item.type == "error"`, and `parseCodex` has no case
    /// for it, so the item is dropped. Harmless here (the top-level `error` +
    /// `turn.failed` still reach the user), but the corpus proves the shape exists —
    /// if the day comes when an item-level error arrives ALONE, this test is the
    /// pointer to the gap.
    func testCodexItemLevelErrorIsCurrentlyDropped() throws {
        let line = try XCTUnwrap(try lines("codex-error")
            .first { $0.contains("\"type\":\"error\"") && $0.contains("item") },
                                 "the corpus no longer contains an item-level codex error")
        let evs = AgentEvent.parse(line: line, backend: .codex)
        XCTAssertTrue(evs.allSatisfy { if case .ignored = $0 { return true } else { return false } },
                      "behaviour changed — update this test and check ChatStore handles it")
    }

    // MARK: - codex: the thread/turn/item envelope

    func testCodexTextStreamParsesThreadAndTurn() throws {
        let evs = try events("codex-text", .codex)

        let ini = try XCTUnwrap(initialized(evs))
        XCTAssertEqual(ini.0, sid, "thread_id is codex's resume key")
        XCTAssertNil(ini.1, "codex reports no model on thread.started")

        // Codex does not stream: the whole message lands in ONE textDelta.
        let deltas = textDeltas(evs)
        XCTAssertEqual(deltas.count, 1)
        XCTAssertTrue(deltas[0].contains("The corpus is alive."), deltas[0])

        // Usage arrives once, at turn end (input alone — codex's input_tokens
        // already contains the cached prefix), unlike claude's per-message.
        let ctx = contextUsages(evs)
        XCTAssertEqual(ctx.count, 1)
        XCTAssertGreaterThan(ctx[0], 0)

        let res = try XCTUnwrap(results(evs).first)
        XCTAssertEqual(res.0, "", "text already arrived as a delta; result must not blank it")
        XCTAssertEqual(res.3, false)
        XCTAssertNil(res.2)
    }

    /// Codex `input_tokens` already INCLUDES the cached prefix — unlike claude,
    /// whose input_tokens EXCLUDES cache reads/writes. Verified on a real rollout
    /// (2026-08-09 19:06, ~/.codex/sessions): last_token_usage input=153745,
    /// cached=150272, output=2318, total=156063 — exactly input + output, so
    /// cached ⊆ input. Summing input+cached therefore double-counts the cache:
    /// this corpus turn (input 12080, cached 5504) would report 17584, and that
    /// real session reported 304017 against its model's 258400 window (>117%).
    func testCodexContextUsageIsInputTokensAloneNotInputPlusCached() throws {
        let ctx = contextUsages(try events("codex-text", .codex))
        XCTAssertEqual(ctx, [12080],
                       "codex input_tokens includes cached_input_tokens — adding "
                       + "them double-counts the cached prefix")
    }

    func testCodexToolStreamMapsCommandAndFileChangeOntoToolChips() throws {
        let evs = try events("codex-tools", .codex)
        let tools = toolUses(evs)

        let bash = try XCTUnwrap(tools.first { $0.name == "Bash" },
                                 "command_execution must become a Bash chip")
        XCTAssertTrue(bash.command?.contains("note.txt") ?? false, bash.command ?? "nil")
        XCTAssertTrue(bash.label.hasPrefix("Bash  "))

        let edit = try XCTUnwrap(tools.first { $0.name == "Write" || $0.name == "Edit" },
                                 "file_change must become a Write/Edit chip")
        XCTAssertEqual(edit.filePath?.hasSuffix("note.txt"), true, edit.filePath ?? "nil")
        XCTAssertTrue(edit.label.contains("note.txt"))

        // item.started and item.completed reuse one id — only .completed may emit,
        // or every codex tool would draw two chips.
        let startedIds = try lines("codex-tools").filter { $0.contains("\"item.started\"") }
        XCTAssertFalse(startedIds.isEmpty, "the corpus should contain item.started lines")
        for line in startedIds {
            XCTAssertTrue(AgentEvent.parse(line: line, backend: .codex)
                .allSatisfy { if case .ignored = $0 { return true } else { return false } },
                          "item.started produced a duplicate chip")
        }
    }

    // MARK: - robustness across the whole corpus

    /// Every line of every real stream must parse without trapping, on BOTH
    /// backends — the app picks the parser from the profile, and a mismatched
    /// profile (or a resumed conversation whose backend changed) must degrade to
    /// silence rather than crash.
    func testEveryCorpusLineIsSafeUnderEitherParser() throws {
        let names = ["claude-text", "claude-think", "claude-tools", "claude-plan",
                     "claude-approval", "claude-error", "codex-text", "codex-tools", "codex-error"]
        for name in names {
            let all = try lines(name)
            XCTAssertFalse(all.isEmpty, "\(name) is empty")
            for line in all {
                _ = AgentEvent.parse(line: line, backend: .claude)
                _ = AgentEvent.parse(line: line, backend: .codex)
            }
            // …and reading a claude stream with the codex parser yields nothing real —
            // except the approval line, which is one shape on purpose: pervio-approve
            // (Claude) and pervio-codex-app (Codex) both put {type:"permission_request",
            // request_id, tool_use_id, tool_name, input} on the stream, and one sheet
            // answers it, so the codex parser reading claude's is right, not invented.
            if name.hasPrefix("claude") {
                let crossed = all.flatMap { AgentEvent.parse(line: $0, backend: .codex) }
                XCTAssertTrue(crossed.allSatisfy {
                    switch $0 {
                    case .ignored, .permissionRequest, .permissionResolved: return true
                    default: return false
                    }
                }, "\(name): the codex parser invented events from a claude stream")
                if name == "claude-approval" {
                    XCTAssertTrue(crossed.contains { if case .permissionRequest = $0 { return true } else { return false } },
                                  "the approval line is the one thing both parsers must agree on")
                }
            }
        }
    }

    /// Blank lines and torn lines happen on a real SSH channel (the LineAssembler
    /// can hand us a fragment when a turn is killed mid-write). Derive them from
    /// REAL lines rather than inventing malformed JSON.
    func testTruncatedAndBlankLinesProduceNoEvents() throws {
        let real = try XCTUnwrap(try lines("claude-tools").first { $0.contains("tool_use") })
        for backend in [AgentBackend.claude, .codex] {
            XCTAssertTrue(AgentEvent.parse(line: "", backend: backend).isEmpty)
            XCTAssertTrue(AgentEvent.parse(line: "   \t ", backend: backend).isEmpty)
            XCTAssertTrue(AgentEvent.parse(line: String(real.prefix(real.count / 2)),
                                           backend: backend).isEmpty)
        }
    }
}
