import XCTest
@testable import Pervio

/// The market on a Mac that lacks an engine: a template whose steps need it
/// is greyed with the reason, not subscribed into a daily failure. Pins: with
/// nothing known nothing is blocked; a claude-only template on a codex-only
/// Mac is blocked and says why; a codex template there is live.
@MainActor
final class MarketEngineGateTests: XCTestCase {
    private var savedLang: Any?
    override func setUp() {
        super.setUp()
        savedLang = UserDefaults.standard.object(forKey: PromptLanguage.defaultsKey)
        UserDefaults.standard.set("zh", forKey: PromptLanguage.defaultsKey)
    }
    override func tearDown() {
        if let savedLang { UserDefaults.standard.set(savedLang, forKey: PromptLanguage.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: PromptLanguage.defaultsKey) }
        super.tearDown()
    }

    private func item(_ id: String, _ backend: AgentBackend) -> WorkflowMarketItem {
        var step = WorkflowStep(id: "digest", backend: backend, prompt: "写日报")
        step.publishEnabled = true
        var spec = WorkflowSpec()
        spec.name = id
        spec.dir = "~"
        spec.steps = [step]
        return WorkflowMarketItem(id: id, title: id, author: "t", summary: "", tags: [], spec: spec)
    }

    func testNothingKnownBlocksNothing() {
        let m = WorkflowMarketServerState(profile: TestFactory.profile(), secret: "s",
                                          makeSSH: { FakeSSH() })
        m.engines = nil
        XCTAssertNil(m.blockedLabel(item("a", .claude)))
        XCTAssertNil(m.subscriptionNote(item("a", .claude)))
    }

    func testAClaudeTemplateOnACodexOnlyMacIsGreyedWithTheReason() {
        let m = WorkflowMarketServerState(profile: TestFactory.profile(), secret: "s",
                                          makeSSH: { FakeSSH() })
        m.engines = EngineProbe(claude: "", codex: "/opt/homebrew/bin/codex", tmux: "")
        XCTAssertEqual(m.missingEngine(item("a", .claude)), .claude)
        XCTAssertEqual(m.blockedLabel(item("a", .claude)), "没装 claude")
        XCTAssertTrue(m.subscriptionNote(item("a", .claude))?.contains("没装 claude") == true)
        XCTAssertNil(m.blockedLabel(item("b", .codex)), "the engine that IS there stays live")
        XCTAssertNil(m.subscriptionNote(item("b", .codex)))
    }
}
