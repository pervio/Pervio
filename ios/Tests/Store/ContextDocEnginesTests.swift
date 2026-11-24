import XCTest
@testable import Pervio

/// The notes rows of the Context panel show who reads each file as engine
/// marks (2026-10-19).
final class ContextDocEnginesTests: XCTestCase {
    func testWhoReadsWhat() {
        XCTAssertEqual(ContextDocEngines.engines(for: "claude-md"), [.claude])
        XCTAssertEqual(ContextDocEngines.engines(for: "rules"), [.claude])
        XCTAssertEqual(ContextDocEngines.engines(for: "memory"), [.claude])
        XCTAssertEqual(ContextDocEngines.engines(for: "agents-md"), [.codex, .cursor])
        XCTAssertEqual(ContextDocEngines.engines(for: "cursor-rules"), [.cursor])
        XCTAssertEqual(ContextDocEngines.engines(for: "whatever"), [], "an unknown kind shows nothing rather than a wrong mark")
    }
    func testEveryMarkIsAnAssetTheAppCarries() {
        for b in AgentBackend.allCases {
            XCTAssertNotNil(UIImage(named: ContextDocEngines.icon(b)), "missing icon asset for \(b)")
        }
    }
}
