import XCTest
import Combine
@testable import Pervio

/// Re-entering a chat whose background run is still going: the loaded history
/// already shows the reply so far; the run's output is then replayed from byte 0
/// into an off-screen bubble and revealed into the visible one. Two contracts,
/// both broken on 2026-10-15 ("six Bash rows before I left, two when I came
/// back, and the page froze"): the visible bubble never shows FEWER tool rows
/// than it already had, and the replay of thousands of lines is published a
/// handful of times, not once per line.
@MainActor
final class ReattachReplayTests: XCTestCase {

    private func toolUse(_ n: Int) -> [AgentEvent] {
        AgentEvent.parse(line: #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t\#(n)","name":"Bash","input":{"command":"step \#(n)"}}]}}"#,
                         backend: .claude)
            .filter { if case .toolUse = $0 { return true } else { return false } }
    }

    func testReplayNeverShowsFewerToolRowsAndPublishesSparingly() async {
        let fake = FakeSSH()
        fake.script("--session 'sess-1'", TestFactory.transcriptJSON([("user", "q")]))
        fake.script("context --dir", "{}")
        fake.script("pervio-sessions usage", "{}")
        let s = ChatStore(profile: TestFactory.profile(), secret: "s", resumeSessionId: "sess-1", ssh: fake)
        await s.connect()

        // What the transcript loader had already put on screen: the reply's text
        // and six tool rows.
        let text = String(repeating: "明白,你说的是这个问题。", count: 12)
        var loaded = ChatMessage(role: .assistant, text: text)
        loaded.tools = (1...6).map { "Bash step \($0)" }
        s.messages = [.user("q"), loaded]

        // The run's output from byte 0: the same text as deltas (three characters
        // at a time, with a bookkeeping line between), THEN eight tool calls — the
        // text catches up long before the tool rows do.
        var events: [AgentEvent] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            let piece = String(rest.prefix(3)); rest = rest.dropFirst(3)
            events.append(.textDelta(piece)); events.append(.ignored)
        }
        for n in 1...8 { events += toolUse(n) }
        fake.runEvents = events

        var minTools = Int.max
        var publishes = 0
        let sub = s.$messages.dropFirst().sink { msgs in
            publishes += 1
            if let a = msgs.last(where: { $0.role == .assistant }) { minTools = min(minTools, a.tools.count) }
        }
        await s.reattach(to: "run-1")
        sub.cancel()

        XCTAssertGreaterThanOrEqual(minTools, 6, "the bubble showed fewer tool rows than it already had (min \(minTools))")
        XCTAssertEqual(s.messages.last?.tools.count, 8, "the replay's tool rows did not all land")
        XCTAssertEqual(s.messages.last?.text, text)
        XCTAssertLessThan(publishes, 30, "a \(events.count)-line replay was published \(publishes) times")
    }
}
