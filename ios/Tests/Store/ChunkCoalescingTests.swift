import XCTest
import Combine
@testable import Pervio

/// A live reply arrives as a few tokens per event, dozens a second; the store
/// used to land every one straight into the @Published bubble, so the whole
/// chat screen re-rendered per few tokens ("the page stutters while it
/// streams", 2026-10-15). Chunks are now gathered and landed ~16 times a
/// second at most — and nothing may be lost or reordered on the way.
@MainActor
final class ChunkCoalescingTests: XCTestCase {

    private func store(_ fake: FakeSSH) -> ChatStore {
        fake.script("--session 'sess-1'", TestFactory.transcriptJSON([("user", "earlier")]))
        fake.script("context --dir", #"{"used": 10, "model": "claude-fable-5"}"#)
        fake.script("pervio-sessions usage", "{}")
        var p = TestFactory.profile()
        p.runMode = false
        return ChatStore(profile: p, secret: "s", resumeSessionId: "sess-1", ssh: fake)
    }

    private func kinds(_ m: ChatMessage?) -> [String] {
        (m?.segments ?? []).map {
            switch $0 {
            case .text: return "text"
            case .thinking: return "thinking"
            default: return "other"
            }
        }
    }

    func testABurstOfChunksLandsCompleteInOrderAndInFewRenders() async {
        let fake = FakeSSH()
        let s = store(fake)
        await s.start()

        let chunks = (0..<200).map { "c\($0) " }
        fake.chatEvents(chunks.map { AgentEvent.textDelta($0) }
                        + [.thinkingDelta("hm"), .thinkingDelta("m"), .textDelta("tail"),
                           .result(text: "done", sessionId: "sess-1", costUSD: nil, isError: false, contextWindow: nil)])
        var publishes = 0
        let sub = s.$messages.dropFirst().sink { _ in publishes += 1 }
        await s.send("hi")
        sub.cancel()

        let reply = s.messages.last { $0.role == .assistant }
        XCTAssertEqual(reply?.text, chunks.joined() + "tail", "every chunk must land, in order")
        XCTAssertEqual(reply?.thinking, "hmm")
        XCTAssertEqual(kinds(reply), ["text", "thinking", "text"],
                       "a chunk of the other kind flushes what is pending first — text / thinking never swap")
        XCTAssertLessThan(publishes, 40, "203 chunks in one burst must not mean 203 re-renders (saw \(publishes))")
    }

    /// Claude Code 2.1 interleaves bookkeeping lines (a `system` thinking-token
    /// tick per few tokens, usage on each assistant message) with the text. Those
    /// parse to .ignored / .contextUsage and must not land the pending chunks —
    /// or the coalescing is defeated and the reply pops out a character at a time.
    func testBookkeepingEventsBetweenChunksDoNotDefeatCoalescing() async {
        let fake = FakeSSH()
        let s = store(fake)
        await s.start()
        var events: [AgentEvent] = []
        for i in 0..<120 {
            events.append(.textDelta("w\(i) "))
            events.append(.ignored)                       // a system thinking_tokens tick
            if i % 10 == 0 { events.append(.contextUsage(1000 + i)) }
        }
        events.append(.result(text: "done", sessionId: "sess-1", costUSD: nil, isError: false, contextWindow: nil))
        fake.chatEvents(events)
        var publishes = 0
        let sub = s.$messages.dropFirst().sink { _ in publishes += 1 }
        await s.send("hi")
        sub.cancel()
        let reply = s.messages.last { $0.role == .assistant }
        XCTAssertEqual(reply?.text, (0..<120).map { "w\($0) " }.joined())
        XCTAssertLessThan(publishes, 40, "bookkeeping events forced a flush per chunk (saw \(publishes) renders for 120 chunks)")
    }

    func testTheTailOfAStreamIsFlushedWhenTheStreamEnds() async {
        let fake = FakeSSH()
        let s = store(fake)
        await s.start()
        // No result event at all (a stream that just closes): the pending text
        // must still land — the loop's defer, not a timer, is what lands it.
        fake.chatEvents([.textDelta("only "), .textDelta("this")])
        await s.send("hi")
        XCTAssertEqual(s.messages.last { $0.role == .assistant }?.text, "only this")
    }
}
