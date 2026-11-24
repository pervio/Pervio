import XCTest
@testable import Pervio

/// Math rendering never alters the source — it only decides which spans get
/// typeset. These pin the DECISIONS (what counts as math, what stays prose),
/// the streaming fallback, and that code fences always win.
final class MathTextTests: XCTestCase {

    // MARK: display blocks → segments

    private func kinds(_ text: String) -> [String] {
        RichMessageText.parse(text).map {
            switch $0 {
            case .prose: return "prose"
            case .code: return "code"
            case .math: return "math"
            }
        }
    }

    private func firstMath(_ text: String) -> String? {
        for seg in RichMessageText.parse(text) {
            if case .math(let latex) = seg { return latex }
        }
        return nil
    }

    func testMultiLineDisplayBlockBecomesOneMathSegment() {
        let msg = "它大致为:\n\\[\n\\text{mean}\\pm1.96\\frac{\\text{SD}}{\\sqrt n}\n\\]\n所以样本越多。"
        XCTAssertEqual(kinds(msg), ["prose", "math", "prose"])
        XCTAssertEqual(firstMath(msg), "\\text{mean}\\pm1.96\\frac{\\text{SD}}{\\sqrt n}",
                       "the source characters must survive verbatim")
    }

    func testSingleLineDisplayFormsBothStyles() {
        XCTAssertEqual(kinds("\\[ E=mc^2 \\]"), ["math"])
        XCTAssertEqual(kinds("$$ E=mc^2 $$"), ["math"])
        XCTAssertEqual(firstMath("$$E=mc^2$$"), "E=mc^2")
    }

    func testDollarFencedMultiLineBlock() {
        XCTAssertEqual(kinds("前文\n$$\n\\mathrm{var}=0.00719^2\n$$\n后文"),
                       ["prose", "math", "prose"])
    }

    func testUnterminatedMathStaysProseWhileStreaming() {
        // The closing fence hasn't streamed in yet — show the raw source, and
        // NEVER swallow the lines.
        let partial = "它大致为:\n\\[\n\\text{mean}\\pm1.96"
        XCTAssertEqual(kinds(partial), ["prose"])
        if case .prose(let p)? = RichMessageText.parse(partial).first {
            XCTAssertTrue(p.contains("\\text{mean}"), "raw formula lines must remain visible")
        }
    }

    func testCodeFenceBeatsMathFence() {
        let msg = "```latex\n\\[\nx^2\n\\]\n```"
        XCTAssertEqual(kinds(msg), ["code"], "math inside a code fence is code")
    }

    // MARK: inline span detection

    private func spans(_ s: String) -> [String] { MathText.inlineSpans(in: s).map(\.latex) }

    func testInlineParenSpansAlwaysCount() {
        XCTAssertEqual(spans("样本量 \\(n\\) 增大后 \\(\\sqrt n\\) 变大"), ["n", "\\sqrt n"])
    }

    func testDollarSpansNeedToLookLikeMath() {
        XCTAssertEqual(spans("误差是 $x^2$ 和 $\\sigma$"), ["x^2", "\\sigma"])
        XCTAssertEqual(spans("$a_i$ 与 $b_j$"), ["a_i", "b_j"])
    }

    func testCurrencyIsNeverEaten() {
        XCTAssertEqual(spans("咖啡 $5 和 $8 一杯"), [], "spaces at span edges = prose")
        XCTAssertEqual(spans("总价 $100"), [], "no closing dollar")
        XCTAssertEqual(spans("$100 加 $200"), [], "digits-only span is money, not math")
    }

    func testInlineCodeSpanShieldsItsDollars() {
        XCTAssertEqual(spans("用 `$PATH$` 变量"), [], "inside `code` stays literal")
    }

    func testDisplayFenceIsNotAnInlineSpan() {
        XCTAssertEqual(spans("$$x$$"), [], "$$ belongs to the display parser")
    }

    // MARK: typesetting (SwiftMath really linked and parsing)

    /// amsmath habits models reach for must not fail the whole formula.
    func testDialectBridgeRendersModelLatex() {
        let formula = #"V^*=\arg\max_{V\in\mathcal F(D)} P\bigl(\text{reader gets }I\mid \operatorname{render}(D,V),C\bigr)"#
        XCTAssertNotNil(MathText.image(latex: formula, fontSize: 19, display: true),
                        "\\bigl/\\bigr/\\operatorname must be bridged, not fail the render")
        XCTAssertNotNil(MathText.image(latex: #"\dfrac{a}{b}\,\operatorname*{argmax}_x f(x)"#, fontSize: 17, display: true))
        XCTAssertEqual(MathText.normalized(#"\bigl(x\bigr)"#), #"\left(x\right)"#)
    }

    /// Visual probes: written to /private/tmp so a human (or Claude) can look
    /// at the actual pixels — CJK inside \text has no glyphs in the bundled math
    /// fonts, and only eyes can tell tofu from text.
    func testVisualProbesWriteToTmp() throws {
        let full = #"V^*=\arg\max_{V\in\mathcal F(D)} P\bigl(\text{读者正确理解目标 }I\mid \operatorname{render}(D,V),C\bigr)"#
        let cjk = MathText.image(latex: full, fontSize: 19, display: true)
        let ascii = MathText.image(latex: #"x^2 + \frac{\text{SD}}{\sqrt n}"#, fontSize: 19, display: true)
        // The app is dark-locked, so the ink is white: composite onto a dark
        // ground or the probe reads as a blank white rectangle.
        for (name, img) in [("pv-math-cjk", cjk), ("pv-math-ascii", ascii)] {
            guard let img else { continue }
            let size = CGSize(width: img.size.width + 24, height: img.size.height + 24)
            let composed = UIGraphicsImageRenderer(size: size).image { ctx in
                UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1).setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                img.draw(at: CGPoint(x: 12, y: 12))
            }
            try composed.pngData()?.write(to: URL(fileURLWithPath: "/private/tmp/\(name).png"))
        }
        XCTAssertNotNil(ascii)
    }

    /// CJK inside \text{…} is cut out for the system font; everything else stays math.
    func testChunksCutOnlyAtTopLevelNonASCIIText() {
        let f = #"V^*=\arg\max_{V} P\left(\text{读者理解 }I\mid \mathrm{render}(D,V),C\right)"#
        let parts = MathText.chunks(f)
        XCTAssertEqual(parts?.map(\.isText), [false, true, false])
        XCTAssertEqual(parts?[1].text, "读者理解 ")
        XCTAssertEqual(MathText.chunks(#"x + \text{SD}"#)?.map(\.isText), [false], "ASCII \\text stays inside the math")
        XCTAssertNil(MathText.chunks(#"\max_{\text{中文}} x"#), "a nested CJK \\text cannot be cut cleanly → source fallback")
        XCTAssertNotNil(MathText.image(latex: f, fontSize: 19, display: true), "the hybrid render produces an image")
    }

    func testTypesetProducesAnImageAndFallbackReturnsNil() {
        XCTAssertNotNil(MathText.image(latex: "\\frac{a}{b}", fontSize: 17, display: true))
        XCTAssertNotNil(MathText.image(latex: "x^2", fontSize: 15, display: false))
        XCTAssertNil(MathText.image(latex: "\\frac{a}{", fontSize: 17, display: true),
                     "unparseable LaTeX must return nil so the caller shows the raw source")
    }
}
