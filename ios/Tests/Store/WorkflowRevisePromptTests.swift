import XCTest
@testable import Pervio

/// The build picker's revise prompt (2026-08-31): picking an existing template
/// prefills a compact instruction that sends the agent to the REAL file instead
/// of pasting a stale copy. These pin its load-bearing lines in both languages.
final class WorkflowRevisePromptTests: XCTestCase {

    func testChineseCarriesTheContract() {
        let t = WorkflowBuilderPrompt.revise(name: "论文晨报", file: "paper-digest.json",
                                             for: .chinese)
        XCTAssertTrue(t.contains("论文晨报"))
        XCTAssertTrue(t.contains("~/.pervio/templates/paper-digest.json"))
        XCTAssertTrue(t.contains("cat"), "must read the real file first")
        XCTAssertTrue(t.contains("{{ref}}"), "the #1 footgun stays pinned")
        XCTAssertTrue(t.contains("templates list"), "verification is mandatory")
        XCTAssertTrue(t.hasSuffix("我的需求:"), "ends where the user types")
    }

    func testEnglishCarriesTheSameContract() {
        let t = WorkflowBuilderPrompt.revise(name: "Digest", file: "paper-digest.json",
                                             for: .english)
        XCTAssertTrue(t.contains("Digest"))
        XCTAssertTrue(t.contains("~/.pervio/templates/paper-digest.json"))
        XCTAssertTrue(t.contains("cat"))
        XCTAssertTrue(t.contains("{{ref}}"))
        XCTAssertTrue(t.contains("templates list"))
        XCTAssertTrue(t.hasSuffix("My request: "))
    }

    func testScratchPromptUnchangedByTheFeature() {
        // The picker's "start from scratch" row rides the original builder
        // prompt; this guards against the revise addition mangling it.
        XCTAssertTrue(WorkflowBuilderPrompt.textZH.contains("~/.pervio/templates/"))
        XCTAssertTrue(WorkflowBuilderPrompt.textZH.hasSuffix("我的需求:"))
    }
}
