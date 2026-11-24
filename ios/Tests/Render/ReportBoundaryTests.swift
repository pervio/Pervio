import XCTest
@testable import Pervio

/// B4 — the shapes a generator eventually emits at 06:31 with nobody watching:
/// an issue that is empty, one that is nothing but a fold, one that is very
/// long, and the CJK + emoji mix every issue is written in. None may crash,
/// hang, or silently drop content.
final class ReportBoundaryTests: XCTestCase {

    // The zh copy pins in this suite predate the English default flip
    // (2026-09-01): an ABSENT language key used to mean Chinese and now means
    // English. Pin zh explicitly; put the user's real setting back afterwards.
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

    // MARK: - empty / degenerate

    func testEmptyAndBlankReportsParseToNothing() {
        XCTAssertTrue(MarkdownBlock.parse("").isEmpty)
        XCTAssertTrue(MarkdownBlock.parse("\n\n\n").isEmpty)
        XCTAssertTrue(MarkdownBlock.parse("   \n\t\n").isEmpty)
        XCTAssertTrue(RichMessageText.parse("").isEmpty)
        XCTAssertTrue(RichMessageText.parse("   \n  ").isEmpty,
                      "a whitespace-only turn must not render an empty bubble")
        XCTAssertEqual(MarkdownBlock.actionTargets([]), [])
        XCTAssertFalse(MarkdownBlock.anyActionHit([], CompiledAction.compile([])))
    }

    /// The real "no new papers today" issue: it still has to render its
    /// masthead and its 回看 link, and still offer that paper's rating menu.
    func testTheNearEmptyRealIssueStillRendersAndScores() throws {
        let md = try ReportFixture.markdown("papers-2026-08-04")
        let blocks = ReportFixture.blocks(md)
        XCTAssertEqual(blocks.map(\.testKind), ["h1", "p", "p", "p"])
        let hits = ReportFixture.phoneHits(md, try ReportFixture.actions())
        XCTAssertEqual(hits.map(\.groups), [["2607.28576"]])
    }

    // MARK: - only a fold

    func testAReportThatIsNothingButAFold() {
        let blocks = MarkdownBlock.parse("<details>\n<summary>只有折叠</summary>\n\n- 一条\n- 两条\n\n</details>")
        XCTAssertEqual(blocks.map(\.testKind), ["details(1)"])
        guard case .details(let summary, let inner)? = blocks.first else { return XCTFail() }
        XCTAssertEqual(summary, "只有折叠")
        XCTAssertEqual(inner.map(\.testKind), ["ul(2)"])
    }

    /// A fold whose close tag never arrives (a truncated generator) still
    /// renders everything it did write, and terminates.
    func testUnclosedFoldSwallowsToEndAndStillRenders() {
        let blocks = MarkdownBlock.parse("<details>\n<summary>断了</summary>\n\n- 一条\n- 两条")
        XCTAssertEqual(blocks.map(\.testKind), ["details(1)"])
        XCTAssertEqual(blocks.first?.testDetailsBlocks?.map(\.testKind), ["ul(2)"])
    }

    /// A fold with no `<summary>` gets the default label rather than eating the
    /// first body line.
    func testFoldWithoutSummaryKeepsItsBody() {
        let blocks = MarkdownBlock.parse("<details>\n\n- 一条\n\n</details>")
        guard case .details(let summary, let inner)? = blocks.first else {
            return XCTFail("\(blocks.map(\.testKind))")
        }
        XCTAssertEqual(summary, "详情")
        XCTAssertEqual(inner.map(\.testKind), ["ul(1)"])
    }

    /// Nesting is unsupported by contract: the body re-parses with details
    /// disabled, so an inner `<details>` falls out as TEXT instead of recursing.
    /// The inner `</details>` therefore closes the outer fold, and the outer's
    /// own close tag is left over as an orphan — which renders as text, exactly
    /// like `testOrphanCloseTagIsText`. Pinned because it is the shape a
    /// generator that learned to nest would produce.
    func testNestedFoldDoesNotRecurse() throws {
        let blocks = MarkdownBlock.parse(
            "<details>\n<summary>外</summary>\n<details>\n<summary>内</summary>\n里面\n</details>\n</details>")
        XCTAssertEqual(blocks.map(\.testKind), ["details(1)", "p"])
        let inner = try XCTUnwrap(blocks.first?.testDetailsBlocks)
        XCTAssertFalse(inner.contains { $0.testDetailsBlocks != nil },
                       "an inner fold must not nest")
        // Nothing is lost: the inner tags and body are still readable text.
        let i0 = try inner.at(0)
        XCTAssertTrue(i0.testText.contains("<details>"))
        XCTAssertTrue(i0.testText.contains("里面"))
        XCTAssertEqual(try blocks.at(1).testText, "</details>")
    }

    // MARK: - very long

    /// The long real issue (66 scorable papers) parses fully, keeps every one
    /// of its entries, and does so fast enough to sit in a scroll view.
    func testTheLongRealIssueKeepsEveryEntry() throws {
        let md = try ReportFixture.markdown("papers-2026-07-18")
        let blocks = ReportFixture.blocks(md)
        XCTAssertGreaterThan(blocks.count, 20)
        let items = blocks.reduce(0) { n, b in
            if case .list(_, _, let i) = b { return n + i.count } else { return n }
        }
        XCTAssertEqual(items, 74, "every bullet in the issue survived the parse")
        XCTAssertEqual(ReportFixture.phoneHits(md, try ReportFixture.actions()).count, 66)
    }

    /// A pathologically long report (the real issue repeated 40×, ~700KB) must
    /// still parse in well under a second — the parse runs on the main thread
    /// behind a memo, so a quadratic blowup here is a frozen scroll.
    func testAVeryLongReportParsesQuickly() throws {
        let one = try ReportFixture.markdown("papers-2026-07-18")
        let huge = Array(repeating: one, count: 40).joined(separator: "\n\n")
        // ~420k characters (the issue is CJK, so far more bytes than that).
        XCTAssertGreaterThan(huge.count, 400_000)
        let start = Date()
        let blocks = MarkdownBlock.parse(huge)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(blocks.count, 800)
        XCTAssertLessThan(elapsed, 5.0, "parsing a long report took \(elapsed)s")
    }

    /// A line of thousands of `-` is a rule, not a heading or a stall.
    func testDegenerateLinesTerminate() {
        XCTAssertEqual(MarkdownBlock.parse(String(repeating: "-", count: 5000)).map(\.testKind),
                       ["rule"])
        XCTAssertEqual(MarkdownBlock.parse("#######  七级标题").map(\.testKind), ["p"],
                       "there is no h7 — it stays prose")
        XCTAssertEqual(MarkdownBlock.parse("#没有空格").map(\.testKind), ["p"])
    }

    // MARK: - CJK + emoji

    /// Every issue is CJK with emoji and full-width punctuation. The parser
    /// slices strings by Character, so a multi-scalar emoji (⭐️, 👍, ⚠️) must
    /// not split — the classic crash is an index landing mid-grapheme.
    func testCJKAndEmojiMixSurvivesIntact() throws {
        for name in ReportFixture.all {
            let md = try ReportFixture.markdown(name)
            let blocks = ReportFixture.blocks(md)
            XCTAssertFalse(blocks.isEmpty, "\(name) parsed to nothing")
            XCTAssertFalse(blocks.contains { $0.testText.contains("\u{FFFD}") },
                           "\(name): a replacement character appeared — text was cut mid-grapheme")
        }
        // The specific mixes the issues really contain.
        let gh = ReportFixture.blocks(try ReportFixture.markdown("github-2026-08-04"))
        XCTAssertTrue(gh.contains { $0.testText.contains("⭐9,336") })
        let papers = ReportFixture.blocks(try ReportFixture.markdown("papers-2026-08-06"))
        XCTAssertTrue(papers.contains { $0.testText.contains("⚠️") })
        XCTAssertTrue(papers.contains { $0.testText.contains("★4.5") })
    }

    /// Emoji-only and emoji-leading lines classify without crashing.
    func testEmojiOnlyLines() {
        XCTAssertEqual(MarkdownBlock.parse("👍👎⭐️⚠️").map(\.testKind), ["p"])
        XCTAssertEqual(MarkdownBlock.parse("- 👍").map(\.testKind), ["ul(1)"])
        XCTAssertEqual(MarkdownBlock.parse("# 👍 标题").map(\.testKind), ["h1"])
        XCTAssertTrue(ReportParagraphView.isDataLine("Rust · ⭐9,336 · +2,524 今日"))
    }

    // MARK: - the whole render path

    /// Every fixture goes through the segment split too (the fenced-code pass),
    /// and none of them loses its content to it.
    func testSegmentSplitPreservesEveryIssue() throws {
        for name in ReportFixture.all {
            let md = try ReportFixture.markdown(name)
            let segments = RichMessageText.parse(md)
            XCTAssertFalse(segments.isEmpty, "\(name) produced no segments")
            let prose = segments.compactMap { s -> String? in
                if case .prose(let t) = s { return t }
                return nil
            }
            XCTAssertFalse(prose.isEmpty, "\(name) produced no prose segment")
        }
    }

    /// An unterminated code fence (a turn cut mid-stream) still renders as a
    /// code block rather than swallowing the rest of the report.
    func testUnterminatedFenceStillRenders() {
        let segments = RichMessageText.parse("前言\n\n```swift\nlet x = 1")
        // Indexing first would CRASH the whole test bundle if a regression
        // dropped the segment — and a crash takes the suites after it with it
        // (seen while mutation-proving this file). Report instead.
        guard segments.count == 2, case .code(let lang, let content) = segments[1] else {
            return XCTFail("expected prose + code, got \(segments.count) segments")
        }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(content, "let x = 1")
    }
}
