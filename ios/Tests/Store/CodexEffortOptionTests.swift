import XCTest
@testable import Pervio

/// The Codex effort picker shows what the picked model supports — from codex's
/// own table — not a fixed list half of which no current model has (2026-10-18).
final class CodexEffortOptionTests: XCTestCase {
    private let menu = [
        CodexModelOption(value: "", label: "Codex config default (empty)"),
        CodexModelOption(value: "gpt-6.1-sol", label: "GPT-6.1-Sol", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "low"),
        CodexModelOption(value: "gpt-6-luna", label: "GPT-6-Luna", efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "medium"),
        CodexModelOption(value: "gpt-old", label: "older server row"),
    ]

    func testAModelOffersExactlyItsOwnLevelsBehindANamedDefault() {
        let sol = CodexEffortOption.options(for: "gpt-6.1-sol", menu: menu)
        XCTAssertEqual(sol.map(\.value), ["", "low", "medium", "high", "xhigh", "max", "ultra"])
        XCTAssertEqual(sol.first?.label, "Default (Low)", "the default names the model's own default level")
        let luna = CodexEffortOption.options(for: "gpt-6-luna", menu: menu)
        XCTAssertEqual(luna.map(\.value), ["", "low", "medium", "high", "xhigh", "max"], "luna has no ultra")
        XCTAssertEqual(luna.first?.label, "Default (Medium)")
    }

    func testUnknownOrLevellessModelsFallBackToTheWholeEnum() {
        XCTAssertEqual(CodexEffortOption.options(for: "gpt-old", menu: menu).map(\.value), CodexEffortOption.all.map(\.value))
        XCTAssertEqual(CodexEffortOption.options(for: "", menu: menu).map(\.value), CodexEffortOption.all.map(\.value),
                       "the config-default row has no table entry of its own")
        XCTAssertEqual(CodexEffortOption.options(for: "something-typed-by-hand", menu: menu).count, CodexEffortOption.all.count)
    }

    func testTheWholeEnumIsCodexsOwn() {
        XCTAssertEqual(CodexEffortOption.all.map(\.value), ["", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"])
        XCTAssertEqual(CodexEffortOption.label(for: "xhigh"), "Extra high")
        XCTAssertEqual(CodexEffortOption.label(for: "weird"), "weird", "an unknown value shows as itself")
    }
}
