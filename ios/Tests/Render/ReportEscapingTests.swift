import XCTest
@testable import Pervio

/// B3 — a report is untrusted input. HTML and script fragments an agent wrote
/// (or that a paper abstract smuggled in) must arrive as VISIBLE TEXT, exactly
/// as server/tests/test_view.py's C group requires of the Mac renderer.
///
/// The two screens are checked against the same adversary: this file feeds the
/// phone the same injection block that test_view.py feeds pervio-view.
final class ReportEscapingTests: XCTestCase {

    private func visible(_ s: String) -> String { String(mdInline(s).characters) }

    // MARK: - aligned with pervio-view's C group

    /// C1/C3/C4b/C5: the tags survive as characters. On the Mac that means
    /// `&lt;script&gt;`; on the phone there is no HTML layer at all, so the
    /// requirement is that the inline markdown pass does not eat them.
    func testHTMLAndScriptFragmentsStayVisibleText() throws {
        let md = try ReportFixture.markdown(ReportFixture.hostile)
        let blocks = ReportFixture.blocks(md)
        let injected = try XCTUnwrap(blocks.first { $0.testText.contains("__pwned") },
                                     "the injection block vanished from the parse")
        let shown = visible(injected.testText)
        for fragment in ["<script>window.__pwned=1</script>",
                         "<img src=x onerror=\"alert(1)\">",
                         "<details open onclick=\"alert(2)\">",
                         "<summary onmouseover=\"alert(3)\">",
                         "</details>"] {
            XCTAssertTrue(shown.contains(fragment),
                          "\(fragment) did not survive as visible text — got: \(shown)")
        }
    }

    /// C4b: a forged `<details open onclick=…>` is NOT a disclosure. Only the
    /// bare lowercase `<details>` line opens a fold, on both screens.
    func testForgedDetailsTagDoesNotOpenAFold() throws {
        let blocks = ReportFixture.blocks(try ReportFixture.markdown(ReportFixture.hostile))
        let folds = blocks.compactMap(\.testDetailsBlocks)
        XCTAssertEqual(folds.count, 1, "only the genuine <details> line may fold")
        XCTAssertEqual(try folds.at(0).map(\.testKind), ["ul(1)"], "the 扫过 fold")
        XCTAssertTrue(blocks.contains { $0.testText.contains("<details open onclick=") },
                      "the forged tag must stay in the text, not be consumed as structure")
    }

    /// C5: an orphan `</details>` is text, not a stray close.
    func testOrphanCloseTagIsText() throws {
        let blocks = MarkdownBlock.parse("正文\n</details>\n更多正文")
        XCTAssertEqual(blocks.map(\.testKind), ["p"])
        XCTAssertTrue(try blocks.at(0).testText.contains("</details>"))
    }

    /// C7: raw `< > &` from a heading survive into the rendered characters —
    /// and that heading is also what an action regex would match against.
    func testRawAnglesAndAmpersandSurviveInAHeading() throws {
        let blocks = ReportFixture.blocks(try ReportFixture.markdown(ReportFixture.hostile))
        let heading = try XCTUnwrap(blocks.first { $0.testText.hasPrefix("注入区") })
        XCTAssertEqual(heading.testKind, "h2")
        XCTAssertTrue(visible(heading.testText).contains("evil'\"&<>"),
                      visible(heading.testText))
    }

    /// The injection never becomes a command. Whatever a report smuggles into a
    /// capture group is one shell word by the time it reaches the server.
    func testACaptureGroupCannotBreakOutOfItsShellWord() {
        XCTAssertEqual(ActionCommand.shellQuote("$(touch X);evil'\"&<>"),
                       "'$(touch X);evil'\\''\"&<>'")
        // A value containing a placeholder stays data — one left-to-right pass.
        XCTAssertEqual(ActionCommand.build(run: "cmd --id {1} --v {choice}",
                                           groups: ["{choice}"], choice: "👍"),
                       "cmd --id '{choice}' --v '👍'")
    }

    // MARK: - Scheme allowlist (the former known divergence, closed 2026-08-22)

    /// 2026-08-22: the divergence this test used to PIN is closed — mdInline
    /// now allowlists http/https/mailto exactly so a hostile [tap](tel://…) or
    /// third-party-app scheme in REMOTE content renders as plain text instead
    /// of a live link (the Mac's C6 sanitizer already refused them). The old
    /// inverted pin said: "when a scheme allowlist lands, this test goes red
    /// and should be replaced by the assertion that the link is gone." It
    /// landed. The link is gone. This is that assertion.
    func testHostileSchemesRenderAsPlainTextLegitimateLinksSurvive() {
        func links(_ s: String) -> [String] {
            mdInline(s).runs.compactMap { $0.link?.absoluteString }
        }
        XCTAssertEqual(links("[点我](javascript:alert(4))"), [],
                       "a javascript: link must be stripped to plain text")
        XCTAssertEqual(links("[点我](shortcuts://run-shortcut?name=Wipe)"), [],
                       "a third-party app scheme must be stripped to plain text")
        XCTAssertEqual(links("[点我](file:///etc/passwd)"), [],
                       "a file: link must be stripped to plain text")
        XCTAssertEqual(links("[点我](tel://13800000000)"), [],
                       "a tel: link must be stripped to plain text")
        // The legitimate cases are untouched — and still underlined links.
        XCTAssertEqual(links("[a](https://arxiv.org/abs/2608.04788)"),
                       ["https://arxiv.org/abs/2608.04788"])
        XCTAssertEqual(links("[m](mailto:someone@example.com)"),
                       ["mailto:someone@example.com"])
    }

    /// The Mac accepts a mixed-case scheme as a link chip (its C6c); the phone's
    /// bare-URL rule is lowercase-only, so the same line stays prose. Harmless
    /// today (no rating button rides on it) but pinned so the asymmetry is known.
    func testKnownDivergence_mixedCaseSchemeIsNotAChipOnThePhone() {
        XCTAssertNil(ReportParagraphView.bareURL("HtTpS://Example.COM/Mixed-Case"),
                     "phone rule changed — realign with pervio-view's _bare_url_line")
    }
}
