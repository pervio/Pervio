import XCTest
@testable import Pervio

/// The model menu comes from the Mac's paper (`pervio-orchestrate models`),
/// cached per phone, with the built-in lists as the floor. Pins: builtins are
/// the floor; a paper overrides and persists; junk changes nothing; a partial
/// paper touches only its own section; tiers keep a fixed, meaningful order.
@MainActor
final class ModelMenuStoreTests: XCTestCase {
    private let suiteName = "ModelMenuStoreTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let paper = #"""
    {"v":1,"tiers":{"fast":"claude-haiku-4-5-20251001","balanced":"claude-sonnet-5","flagship":"claude-opus-5","frontier":"claude-fable-5-1"},
     "chat":{"claude":[{"id":"claude-opus-5","note":"recommended"},{"id":"claude-fable-5-1","note":"most capable"}],
             "codex":[{"id":"gpt-5.6-sol","note":"default"},{"id":"gpt-6-astra","note":"new"}],
             "cursor":[{"id":"auto","note":"Cursor picks"},{"id":"composer-2.5","note":"Composer 2.5"}],
             "recommended":"claude-opus-5"}}
    """#

    /// Codex's rows carry the levels and default codex's own table lists (2026-10-18).
    func testCodexRowsCarryTheirOwnLevelsAndDefault() {
        let s = ModelMenuStore(defaults: defaults)
        let paper = "{\"v\":1,\"chat\":{\"codex\":["
            + "{\"id\":\"gpt-6.1-sol\",\"note\":\"GPT-6.1-Sol · the config default\",\"efforts\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\",\"ultra\"],\"defaultEffort\":\"low\"},"
            + "{\"id\":\"gpt-6-luna\",\"note\":\"GPT-6-Luna\",\"efforts\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\"],\"defaultEffort\":\"medium\"},"
            + "{\"id\":\"gpt-old\",\"note\":\"from an older server\"}]}}"
        XCTAssertTrue(s.apply(Data(paper.utf8)))
        let sol = s.codex.first { $0.value == "gpt-6.1-sol" }
        XCTAssertEqual(sol?.efforts, ["low", "medium", "high", "xhigh", "max", "ultra"])
        XCTAssertEqual(sol?.defaultEffort, "low")
        XCTAssertEqual(s.codex.first { $0.value == "gpt-old" }?.efforts, [], "a row without levels claims none")
        XCTAssertEqual(s.codex.first?.value, "", "the config-default row still leads the menu")
    }

    func testThePaperCarriesSpeedTiersClaudeLevelsAndTheMacsDefaults() {
        let s = ModelMenuStore(defaults: defaults)
        let paper = "{\"v\":1,\"chat\":{\"codex\":["
            + "{\"id\":\"gpt-6.1-sol\",\"note\":\"sol\",\"efforts\":[\"low\"],\"defaultEffort\":\"low\",\"fast\":{\"id\":\"priority\",\"name\":\"Fast\",\"description\":\"2x speed, increased usage\"}},"
            + "{\"id\":\"gpt-plain\",\"note\":\"plain\"}],"
            + "\"claudeEfforts\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\",\"turbo\"],\"codexServiceTier\":\"priority\",\"codexDefaultModel\":\"gpt-6.1-sol\"}}"
        XCTAssertTrue(s.apply(Data(paper.utf8)))
        XCTAssertEqual(s.codex.first { $0.value == "gpt-6.1-sol" }?.fast?.description, "2x speed, increased usage")
        XCTAssertNil(s.codex.first { $0.value == "gpt-plain" }?.fast)
        XCTAssertEqual(s.claudeEfforts.map(\.value), ["", "low", "medium", "high", "xhigh", "max", "turbo", "ultracode"])
        XCTAssertEqual(s.codexServiceTier, "priority"); XCTAssertEqual(s.codexDefaultModel, "gpt-6.1-sol")
        let again = ModelMenuStore(defaults: defaults)
        XCTAssertEqual(again.claudeEfforts.count, 8, "the cached paper restores the levels on the next launch")
        XCTAssertEqual(again.codexServiceTier, "priority")
    }

    func testBuiltinsAreTheFloor() {
        let s = ModelMenuStore(defaults: defaults)
        XCTAssertEqual(s.claude.first?.value, "claude-opus-5")
        XCTAssertTrue(s.codex.contains { $0.value == "gpt-6-astra" }, "astra is a pick even before any server answers")
        XCTAssertEqual(s.tiers.map(\.value), ["frontier", "flagship", "balanced", "fast"])
        XCTAssertEqual(s.recommended, "claude-opus-5")
    }

    func testCursorSectionOfThePaperFeedsItsMenu() {
        let s = ModelMenuStore(defaults: defaults)
        XCTAssertEqual(s.cursor.first?.value, "", "the floor opens with auto (empty)")
        XCTAssertTrue(s.apply(Data(paper.utf8)))
        XCTAssertEqual(s.cursor.map(\.value), ["", "composer-2.5"], "auto folds into the empty entry; the rest follow")
        XCTAssertTrue(s.cursor[1].label.contains("Composer"))
    }

    func testAPaperOverridesAndPersists() {
        let s = ModelMenuStore(defaults: defaults)
        XCTAssertTrue(s.apply(Data(paper.utf8)))
        XCTAssertEqual(s.claude.map(\.value), ["claude-opus-5", "claude-fable-5-1", ""],
                       "the paper's list plus the account-default tail")
        XCTAssertEqual(s.claude[1].label, "claude-fable-5-1 — most capable")
        XCTAssertEqual(s.codex.map(\.value), ["", "gpt-5.6-sol", "gpt-6-astra"],
                       "codex keeps its config-default head")
        XCTAssertEqual(s.tiers.map(\.value), ["frontier", "flagship", "balanced", "fast"],
                       "tier order is fixed regardless of the JSON's key order")
        XCTAssertEqual(s.tiers[1].label, "flagship — today: claude-opus-5")
        let reborn = ModelMenuStore(defaults: defaults)
        XCTAssertEqual(reborn.codex.map(\.value), ["", "gpt-5.6-sol", "gpt-6-astra"],
                       "the cached paper survives a relaunch")
    }

    func testJunkChangesNothing() {
        let s = ModelMenuStore(defaults: defaults)
        let before = s.claude.map(\.value)
        XCTAssertFalse(s.apply(Data("not json".utf8)))
        XCTAssertFalse(s.apply(Data(#"{"tiers":{},"chat":{"claude":[]}}"#.utf8)), "empty sections are not a menu")
        XCTAssertEqual(s.claude.map(\.value), before)
        XCTAssertNil(defaults.data(forKey: "pervio.modelMenu.v1"), "junk is never cached")
    }

    func testAPartialPaperTouchesOnlyItsSection() {
        let s = ModelMenuStore(defaults: defaults)
        let claudeBefore = s.claude.map(\.value)
        XCTAssertTrue(s.apply(Data(#"{"chat":{"codex":[{"id":"gpt-7","note":""}]}}"#.utf8)))
        XCTAssertEqual(s.codex.map(\.value), ["", "gpt-7"])
        XCTAssertEqual(s.codex[1].label, "gpt-7", "no note → bare id")
        XCTAssertEqual(s.claude.map(\.value), claudeBefore, "claude untouched by a codex-only paper")
    }
}
