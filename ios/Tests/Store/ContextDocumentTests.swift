import XCTest
@testable import Pervio

/// The exported context document carries its bearings (2026-10-17): the
/// count, the range it holds (numbered turns), the one command that pages any
/// other window on the Mac, and the raw files — and when it has to cut, it
/// keeps the LATEST turns and says so in the range.
@MainActor
final class ContextDocumentTests: XCTestCase {
    private func turns(_ n: Int, size: Int = 10) throws -> [TranscriptTurn] {
        let pairs = (1...n).map { i -> (String, String) in
            (i % 2 == 1 ? "user" : "assistant", String(repeating: i % 2 == 1 ? "q" : "a", count: size) + "\(i)")
        }
        return try JSONDecoder().decode([TranscriptTurn].self, from: Data(TestFactory.transcriptJSON(pairs).utf8))
    }

    func testBearingsAndThePagingCommand() throws {
        let w = TurnsWindow(total: 120, from: 81, to: 120, files: ["/Users/me/.claude/projects/-x/s.jsonl"], turns: try turns(40))
        let doc = ChatStore.contextDocument(projectPath: "/Users/me/proj", sessionId: "sid-1", backend: .claude,
                                            window: w, launcher: "/Users/me/.pervio/bin/pervio-sessions", byteCap: 300_000, language: .chinese)
        XCTAssertTrue(doc.contains("共 120 条消息;本文档含第 81–120 条"), doc.prefix(400).description)
        XCTAssertTrue(doc.contains("/Users/me/.pervio/bin/pervio-sessions turns --dir '/Users/me/proj' --session 'sid-1' --from 1 --limit 200 --text"), doc.prefix(600).description)
        XCTAssertTrue(doc.contains("/Users/me/.claude/projects/-x/s.jsonl"))
        XCTAssertTrue(doc.contains("#81 [用户]") && doc.contains("#120 [助手]"), "turns are numbered by their place in the conversation")
        let codex = ChatStore.contextDocument(projectPath: "/p", sessionId: "t", backend: .codex,
                                              window: w, launcher: "L", byteCap: 300_000, language: .english)
        XCTAssertTrue(codex.contains("--backend codex --from 1 --limit 200 --text"), "codex windows page with the backend flag")
        XCTAssertTrue(codex.contains("has 120 turns in all; this document holds turns 81-120"))
    }

    func testACutKeepsTheLatestTurnsAndSaysSo() throws {
        let w = TurnsWindow(total: 10, from: 1, to: 10, files: [], turns: try turns(10, size: 100))
        let doc = ChatStore.contextDocument(projectPath: "/p", sessionId: "s", backend: .claude,
                                            window: w, launcher: "L", byteCap: 450, language: .english)
        XCTAssertFalse(doc.contains("#1 [user]"), "the oldest turns go first")
        XCTAssertTrue(doc.contains("#10 [assistant]"), "the latest turn stays")
        let range = doc.components(separatedBy: "this document holds turns ")[1].prefix(6)
        XCTAssertTrue(range.hasSuffix("-10") || range.contains("-10"), "the range says where the kept part starts: \(range)")
        XCTAssertFalse(doc.contains("holds turns 1-10"))
    }
}
