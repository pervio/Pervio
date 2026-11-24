import XCTest
@testable import Pervio

/// B1 — the block parser against REAL published issues.
///
/// Every assertion here is about the parse RESULT (which block, which level,
/// which text), never about pixels: the failure this guards is a digest that
/// loses information or reads as a wall — a heading that stops being a heading,
/// a fold that stops folding, a list that collapses into prose.
final class ReportStructureTests: XCTestCase {

    // MARK: - heading levels

    /// The 2026-08-06 digest's spine, in order. Read it against the file: a
    /// masthead `#`, the 今日一句 pull quote, `## 必读`, then the first paper's
    /// `###` with its blurb paragraphs, its source quote and the `---` before
    /// the next paper.
    func testDigestSpineParsesInOrder() throws {
        let blocks = ReportFixture.blocks(try ReportFixture.markdown("papers-2026-08-06"))
        XCTAssertEqual(blocks.prefix(10).map(\.testKind),
                       ["h1", "quote", "h2", "h3", "p", "p", "p", "p", "quote", "rule"])
        XCTAssertEqual(blocks.first?.testText, "论文晨报 · 2026-08-06 · 80 篇")
        let b1 = try blocks.at(1), b2 = try blocks.at(2)
        XCTAssertTrue(b1.testText.hasPrefix("今日一句"), b1.testText)
        XCTAssertEqual(b2.testText, "必读")
        // The `###` keeps its markdown link intact — that link is what the
        // rating action matches on, so flattening it here would silently
        // unscore every 必读 paper.
        XCTAssertEqual(try blocks.at(3).testText,
                       "[不改训练目标，两个 Replay 视图把 GRPO 的\"脏信号\"洗干净]"
                       + "(https://arxiv.org/abs/2608.04788)")
    }

    /// Three heading levels, and the counts the issue really has.
    func testHeadingLevelsAreDistinguished() throws {
        let blocks = ReportFixture.blocks(try ReportFixture.markdown("papers-2026-08-06"))
        var levels: [Int: [String]] = [:]
        for b in blocks { if case .heading(let l, let t) = b { levels[l, default: []].append(t) } }
        XCTAssertEqual(levels[1], ["论文晨报 · 2026-08-06 · 80 篇"])
        XCTAssertEqual(levels[2], ["必读", "值得读", "扫过", "趋势"])
        XCTAssertEqual(levels[3]?.count, 3)
        XCTAssertNil(levels[4], "the digest has no #### level")
        // A `#` line that is a heading must not also be mistaken for a data
        // line: the masthead is `论文晨报 · 2026-08-06 · 80 篇`, which matches
        // the `A · B · C` data-line shape exactly. Heading wins.
        XCTAssertEqual(blocks.first?.testKind, "h1")
    }

    // MARK: - lists

    /// 值得读 writes its 6 entries with a blank line between each, so a blank
    /// line ends the run and each entry becomes its own one-item list. The fold
    /// below writes its 11 entries with no blank lines, and those stay one list.
    /// pervio-view flushes on a blank line too, so this is agreed shape, not
    /// drift — what matters is that all 6 entries survive with their link and
    /// their ★ rating, since that link is what the rating button matches on.
    func testListsKeepEveryItem() throws {
        let blocks = ReportFixture.blocks(try ReportFixture.markdown("papers-2026-08-06"))
        let lists = blocks.filter { $0.testKind.hasPrefix("ul") }
        XCTAssertEqual(lists.map(\.testKind), Array(repeating: "ul(1)", count: 6),
                       "值得读's 6 blank-line-separated entries; the other 11 live in the fold")
        let items = lists.flatMap { block -> [String] in
            if case .list(let ordered, let start, let i) = block {
                XCTAssertFalse(ordered)
                XCTAssertEqual(start, 1)
                return i
            }
            return []
        }
        XCTAssertEqual(items.count, 6)
        // Each entry keeps its link, its ★ rating and its trailing summary —
        // the three things the reader actually scans.
        XCTAssertTrue(items.allSatisfy { $0.contains("https://arxiv.org/abs/") })
        XCTAssertTrue(items.allSatisfy { $0.contains("`★") })
        let first = try items.at(0)
        XCTAssertTrue(first.hasPrefix("[免训练 64 位哈希稀疏注意力"), first)
        // The `- ` marker itself never reaches the screen.
        XCTAssertFalse(items.contains { $0.hasPrefix("- ") })
    }

    /// The tight list inside the fold is NOT split: 11 entries, one block.
    func testTightListInsideTheFoldStaysOneList() throws {
        let blocks = ReportFixture.blocks(try ReportFixture.markdown("papers-2026-08-06"))
        let fold = try XCTUnwrap(blocks.compactMap(\.testDetailsBlocks).first)
        XCTAssertEqual(fold.map(\.testKind), ["ul(11)"])
    }

    /// A numbered list keeps the SOURCE ordinal, so an item split off by a
    /// continuation paragraph still shows its real number.
    func testNumberedListKeepsSourceOrdinals() {
        let blocks = MarkdownBlock.parse("3. 第三条\n4. 第四条")
        guard case .list(let ordered, let start, let items)? = blocks.first else {
            return XCTFail("not a list: \(blocks.map(\.testKind))")
        }
        XCTAssertTrue(ordered)
        XCTAssertEqual(start, 3)
        XCTAssertEqual(items, ["第三条", "第四条"])
    }

    // MARK: - quotes

    func testQuotesAreTheirOwnBlockAndDropTheMarker() throws {
        let blocks = ReportFixture.blocks(try ReportFixture.markdown("papers-2026-08-06"))
        let quotes = blocks.filter { $0.testKind == "quote" }
        XCTAssertEqual(quotes.count, 4, "the pull quote plus one source quote per 必读 paper")
        XCTAssertFalse(quotes.contains { $0.testText.hasPrefix(">") },
                       "the `>` marker must not survive into the rendered text")
        let q1 = try quotes.at(1)
        XCTAssertTrue(q1.testText.contains("we identify a confounding issue"), q1.testText)
    }

    // MARK: - <details> folds

    func testDetailsFoldKeepsItsSummaryAndItsItems() throws {
        let blocks = ReportFixture.blocks(try ReportFixture.markdown("papers-2026-08-06"))
        let folds = blocks.filter { $0.testDetailsBlocks != nil }
        XCTAssertEqual(folds.count, 1)
        guard case .details(let summary, let inner)? = folds.first else { return XCTFail() }
        XCTAssertEqual(summary, "展开 11 篇扫过")
        XCTAssertEqual(inner.map(\.testKind), ["ul(11)"],
                       "the fold body is one 11-item list — no line may be dropped or promoted")
        // The tags themselves must never reach the screen as text.
        XCTAssertFalse(blocks.contains { $0.testText.contains("<details>") },
                       "a raw <details> tag leaked into a rendered block")
        XCTAssertFalse(blocks.contains { $0.testText.contains("</summary>") })
    }

    /// The github issue folds too, with a different summary and 10 items —
    /// so the fold is a real parse, not a match on one publication's wording.
    func testTheOtherPublicationFoldsToo() throws {
        let blocks = ReportFixture.blocks(try ReportFixture.markdown("github-2026-08-04"))
        guard let fold = blocks.first(where: { $0.testDetailsBlocks != nil }),
              case .details(let summary, let inner) = fold else {
            return XCTFail("github issue lost its fold")
        }
        XCTAssertEqual(summary, "今日扫过但未入选（10 个）")
        XCTAssertEqual(inner.map(\.testKind), ["ul(10)"])
    }

    // MARK: - data lines and bare-link chips

    /// In the GitHub issue every entry ends with a bare repo URL and a
    /// `Rust · ⭐9,336 · +2,524 今日` metadata line. The report renderer turns
    /// the first into a tappable chip labelled `owner/name` and the second into
    /// small secondary type — if either fell back to prose, the entry would
    /// read as a URL wall with its numbers shouting at body size.
    func testBareLinkBecomesAChipAndTheMetadataLineBecomesData() throws {
        let blocks = ReportFixture.blocks(try ReportFixture.markdown("github-2026-08-04"))
        let para = try XCTUnwrap(blocks.first { $0.testText.contains("github.com/firecrawl") },
                                 "the firecrawl entry vanished")
        let pieces = ReportParagraphView.pieces(para.testText)
        XCTAssertEqual(pieces.count, 2, "expected exactly a chip and a data line")
        guard case .link(let url, let label) = try pieces.at(0) else {
            return XCTFail("first piece is not a link chip: \(pieces)")
        }
        XCTAssertEqual(url.absoluteString, "https://github.com/firecrawl/pdf-inspector")
        XCTAssertEqual(label, "firecrawl/pdf-inspector", "github chips read owner/name")
        guard case .data(let d) = try pieces.at(1) else {
            return XCTFail("second piece is not a data line: \(pieces)")
        }
        XCTAssertEqual(d, "Rust · ⭐9,336 · +2,524 今日")
    }

    /// The data-line rule is deliberately conservative: a miss just renders as
    /// prose, a false hit shrinks real prose. These are the edges that decide it.
    func testDataLineRuleStaysConservative() {
        XCTAssertTrue(ReportParagraphView.isDataLine("Rust · ⭐9,336 · +2,524 今日"))
        XCTAssertFalse(ReportParagraphView.isDataLine("没有中点分隔的一行 9,336"))
        XCTAssertFalse(ReportParagraphView.isDataLine("纯文字 · 没有数字"))
        XCTAssertFalse(ReportParagraphView.isDataLine(
            "https://github.com/a/b · TypeScript · ⭐2,814 · +796 今日"),
                       "a line carrying a link is prose, not a data line")
        XCTAssertFalse(ReportParagraphView.isDataLine("这是一句真正的散文 · 里面有 1 个数字。"),
                       "a sentence-ending 。 means prose")
    }

    /// A chip replaces a line that was pure link plumbing — never a line that
    /// has prose around the URL.
    func testChipsOnlyReplaceWholeLineURLs() {
        XCTAssertNotNil(ReportParagraphView.bareURL("https://github.com/a/b"))
        XCTAssertNil(ReportParagraphView.bareURL("见 https://github.com/a/b"))
        XCTAssertNil(ReportParagraphView.bareURL("https://github.com/a/b 很好"))
        XCTAssertNil(ReportParagraphView.bareURL("ftp://example.com/x"))
        XCTAssertEqual(ReportParagraphView.linkLabel(
            URL(string: "https://www.producthunt.com/products/kiro")!), "producthunt.com")
    }

    /// A whole-line `<!-- … -->` template marker is plumbing and is hidden.
    /// The 2026-08-04 issue really carries one.
    func testTemplateMarkerIsHidden() throws {
        let md = try ReportFixture.markdown("papers-2026-08-04")
        XCTAssertTrue(md.contains("<!-- NO_NEW_PAPERS -->"), "fixture assumption")
        let blocks = ReportFixture.blocks(md)
        let marker = try XCTUnwrap(blocks.first { $0.testText.contains("NO_NEW_PAPERS") })
        XCTAssertTrue(ReportParagraphView.pieces(marker.testText).isEmpty,
                      "the marker must render as nothing, not as visible plumbing")
    }

    // MARK: - report sectioning

    /// `##` sections get the card treatment; the `#` masthead and the preamble
    /// do not — and a `---` touching a boundary is dropped so the card gap is
    /// the only separator.
    func testReportSectionsCardTheLevelTwoGroups() throws {
        let blocks = ReportFixture.blocks(try ReportFixture.markdown("papers-2026-08-06"))
        let sections = MarkdownBlock.reportSections(blocks)
        XCTAssertEqual(sections.first?.card, false, "the masthead is not a card")
        let carded = sections.filter(\.card)
        XCTAssertEqual(carded.count, 4, "必读 / 值得读 / 扫过 / 趋势")
        for s in sections {
            XCTAssertNotEqual(s.blocks.first?.testKind, "rule",
                              "a section must not open on a rule")
            XCTAssertNotEqual(s.blocks.last?.testKind, "rule",
                              "a section must not end on a rule")
        }
        // …and on this issue the LAST rule of a section is the one that does the
        // work: every `---` sits before the next `##`, never after it. Pinned
        // because the loop above would otherwise pass without the leading-rule
        // rule ever running — see the synthetic case below.
        XCTAssertTrue(blocks.contains { $0.testKind == "rule" }, "the issue has rules at all")
    }

    /// Both edges of the rule-stripping, on input built to reach them. No
    /// archived issue opens a run on a `---` (every section opens on its own
    /// heading; only the PREAMBLE can start with a rule), so without this the
    /// "must not open on a rule" assertion above is inert — a mutation that
    /// deletes the leading-rule strip leaves the whole suite green (verified).
    func testARuleAtASectionBoundaryIsDropped() {
        let blocks = MarkdownBlock.parse("""
        ---

        前言

        ---

        ## 必读

        正文

        ---

        ## 趋势

        尾声
        """)
        XCTAssertEqual(blocks.map(\.testKind),
                       ["rule", "p", "rule", "h2", "p", "rule", "h2", "p"],
                       "fixture assumption: rules at both edges of a run")
        let sections = MarkdownBlock.reportSections(blocks)
        XCTAssertEqual(sections.map { $0.blocks.map(\.testKind) },
                       [["p"], ["h2", "p"], ["h2", "p"]],
                       "a `---` touching a section boundary is the card gap's job — "
                       + "keeping both double-rules every section")
        XCTAssertEqual(sections.map(\.card), [false, true, true])
    }

    /// A rule INSIDE a section stays: it is the separator between two papers,
    /// not a boundary ornament. And a `---` written straight after a `##`
    /// heading is inside — the section already opened on the heading. Together
    /// with the test above this says exactly which rules survive.
    func testARuleInsideASectionSurvives() {
        XCTAssertEqual(MarkdownBlock.reportSections(MarkdownBlock.parse(
            "## 必读\n\n甲\n\n---\n\n乙")).map { $0.blocks.map(\.testKind) },
                       [["h2", "p", "rule", "p"]])
        XCTAssertEqual(MarkdownBlock.reportSections(MarkdownBlock.parse(
            "## 必读\n\n---\n\n正文")).map { $0.blocks.map(\.testKind) },
                       [["h2", "rule", "p"]])
    }
    /// 方法图(2026-08-24):a standalone ![alt](url) line becomes an image block
    /// ONLY for arxiv.org URLs — everything else must stay visible text, never a
    /// tap target. Inline images inside a sentence never become blocks at all.
    func testMethodFigure_imageBlockRules() {
        let ok = MarkdownBlock.parse("前文\n![方法图:Overview](https://arxiv.org/html/2608.1v1/x1.png)\n后文")
        XCTAssertTrue(ok.contains { if case .image(let alt, let url) = $0 {
            return alt == "方法图:Overview" && url.host == "arxiv.org" } else { return false } },
            "an arxiv whole-line image must become an image block")

        let evil = MarkdownBlock.parse("![x](https://evil.example.com/x.png)")
        XCTAssertFalse(evil.contains { if case .image = $0 { return true } else { return false } },
            "non-arxiv image lines must NOT become image blocks")
        if case .paragraph(let t)? = evil.first {
            XCTAssertTrue(t.contains("evil.example.com"), "the refused line stays visible as text")
        } else {
            XCTFail("expected the refused image line to fall through as a paragraph")
        }

        let inline = MarkdownBlock.parse("句中 ![图](https://arxiv.org/x.png) 不算")
        XCTAssertFalse(inline.contains { if case .image = $0 { return true } else { return false } },
            "inline images inside a sentence are not blocks")
    }

}
