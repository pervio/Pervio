import XCTest
@testable import Pervio

/// Codex's Fast switch (2026-10-19): the tier comes from codex's own table per
/// model, the switch starts from the Mac's config, a flip is per conversation
/// and rides as --service-tier.
@MainActor
final class CodexSpeedTests: XCTestCase {
    private let sol = CodexModelOption(value: "gpt-6.1-sol", label: "sol", fast: CodexFastTier(id: "priority", name: "Fast", description: "2x speed, increased usage"))
    private let plain = CodexModelOption(value: "gpt-plain", label: "plain")

    func testTheTierFollowsTheModelOrTheMacsDefaultModel() {
        XCTAssertEqual(CodexSpeed.tier(model: "gpt-6.1-sol", menu: [sol, plain], defaultModel: "")?.description, "2x speed, increased usage")
        XCTAssertNil(CodexSpeed.tier(model: "gpt-plain", menu: [sol, plain], defaultModel: "gpt-6.1-sol"), "a model with no tier shows no switch")
        XCTAssertEqual(CodexSpeed.tier(model: "", menu: [sol, plain], defaultModel: "gpt-6.1-sol")?.id, "priority", "unset model = the Mac's config model")
        XCTAssertNil(CodexSpeed.tier(model: "", menu: [sol, plain], defaultModel: ""), "nothing to go on")
    }

    func testTheSwitchStartsFromTheMacAndAFlipWins() {
        var p = TestFactory.profile(); p.backend = .codex
        XCTAssertTrue(CodexSpeed.isFast(p, macTier: "priority"), "the Mac runs Fast, nothing chosen: on")
        XCTAssertFalse(CodexSpeed.isFast(p, macTier: ""), "the Mac runs standard: off")
        p.codexServiceTier = "default"
        XCTAssertFalse(CodexSpeed.isFast(p, macTier: "priority"), "switched off here beats the Mac's Fast")
        p.codexServiceTier = "priority"
        XCTAssertTrue(CodexSpeed.isFast(p, macTier: ""), "switched on here beats the Mac's standard")
    }

    func testTheWireCarriesTheTierOnlyWhenChosen() throws {
        let svc = SSHService()
        var p = TestFactory.profile(); p.backend = .codex
        XCTAssertFalse(svc.buildChatCommand(profile: p, prompt: "hi", resume: nil, approveSid: nil, pervioContext: false).contains("--service-tier"))
        p.codexServiceTier = "priority"
        XCTAssertTrue(svc.buildChatCommand(profile: p, prompt: "hi", resume: nil, approveSid: nil, pervioContext: false).contains("--service-tier 'priority'"))
        XCTAssertTrue(svc.buildStartRunCommand(profile: p, prompt: "hi", resume: nil, pervioContext: false).contains("--service-tier 'priority'"))
        let back = try JSONDecoder().decode(ConvParams.self, from: JSONEncoder().encode(ConvParams(p)))
        var q = TestFactory.profile(); back.apply(to: &q)
        XCTAssertEqual(q.codexServiceTier, "priority", "remembered per conversation")
    }

    func testClaudeLevelsMenuFromTheCLIsList() {
        let rows = EffortOption.menu(levels: ["low", "medium", "high", "xhigh", "max", "turbo"])
        XCTAssertEqual(rows.map(\.value), ["", "low", "medium", "high", "xhigh", "max", "turbo", "ultracode"], "Default first, Pervio's ultracode last")
        XCTAssertEqual(rows.first { $0.value == "xhigh" }?.label, "Extra high", "a known level keeps its name")
        XCTAssertEqual(rows.first { $0.value == "turbo" }?.label, "Turbo", "a level the CLI added is shown capitalised")
    }
}
