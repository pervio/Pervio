import SwiftUI
import UIKit
import SwiftMath

/// LaTeX math for chat/report text, "typeset — never transliterate": the stored
/// message keeps its original characters, and rendering draws the real formula
/// the way VS Code's math panes do. GPT-family models emit `\[ … \]` display
/// blocks and `\( … \)` / `$ … $` inline spans; Claude mostly writes plain
/// prose, which is why this gap only surfaced on codex chats (2026-09-13).
///
/// Anything SwiftMath cannot parse falls back to the raw source text — a wrong
/// formula must degrade to what the model actually said, never to a blank.
enum MathText {

    // MARK: - Detection (pure functions, unit-tested)

    /// The whole (trimmed) line is one single-line display formula:
    /// `\[ … \]` or `$$ … $$`. Returns the inner LaTeX, or nil.
    static func displayFormula(line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for (open, close) in [("\\[", "\\]"), ("$$", "$$")] {
            if t.hasPrefix(open), t.hasSuffix(close), t.count > open.count + close.count {
                let inner = String(t.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty { return inner }
            }
        }
        return nil
    }

    /// A line that OPENS a multi-line display block: exactly `\[` or `$$`.
    static func opensDisplay(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t == "\\[" || t == "$$"
    }

    /// A line that CLOSES a multi-line display block: exactly `\]` or `$$`.
    static func closesDisplay(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t == "\\]" || t == "$$"
    }

    /// One inline math span found in prose.
    struct InlineSpan {
        let range: Range<String.Index>   // includes the delimiters
        let latex: String                // inner LaTeX, delimiters stripped
    }

    /// Inline spans in one prose run: `\( … \)` always counts; `$ … $` only
    /// when the body looks like math — a currency line ("咖啡 $5 和 $8") must
    /// never be eaten. Spans never cross newlines, and anything inside a
    /// `markdown code span` stays literal (this runs on RAW markdown, before
    /// the markdown parser gets to see it).
    static func inlineSpans(in s: String) -> [InlineSpan] {
        var out: [InlineSpan] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "`" {   // jump over `code spans` — their $/\( are literal
                let after = s.index(after: i)
                if let close = s[after...].firstIndex(of: "`") {
                    i = s.index(after: close); continue
                }
            }
            if let span = matchDelimited(s, from: i, open: "\\(", close: "\\)", requireMathy: false)
                ?? matchDelimited(s, from: i, open: "$", close: "$", requireMathy: true) {
                out.append(span)
                i = span.range.upperBound
            } else {
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func matchDelimited(_ s: String, from: String.Index,
                                       open: String, close: String,
                                       requireMathy: Bool) -> InlineSpan? {
        guard s[from...].hasPrefix(open) else { return nil }
        let bodyStart = s.index(from, offsetBy: open.count)
        // `$$` is a display fence, not an inline span — reject a doubled dollar
        // on EITHER side of the opening delimiter.
        if open == "$" {
            if bodyStart < s.endIndex, s[bodyStart] == "$" { return nil }
            if from > s.startIndex, s[s.index(before: from)] == "$" { return nil }
        }
        guard let closeRange = s.range(of: close, range: bodyStart..<s.endIndex) else { return nil }
        let body = String(s[bodyStart..<closeRange.lowerBound])
        guard !body.isEmpty, !body.contains("\n"), body.count <= 120 else { return nil }
        if requireMathy {
            // Edges must not be whitespace ("$ 5 和 8 $" is prose, "$x$" is math)…
            guard let f = body.first, let l = body.last,
                  !f.isWhitespace, !l.isWhitespace else { return nil }
            // …and a bare number is money, not math ("$100"): demand a letter,
            // a backslash command, or an operator that only math would carry.
            let mathy = body.contains("\\") || body.contains("^") || body.contains("_")
                || body.contains("=") || body.contains(where: { $0.isLetter })
            guard mathy else { return nil }
        }
        return InlineSpan(range: from..<closeRange.upperBound, latex: body)
    }

    // MARK: - Typesetting

    /// Chat is dark-mode-locked (PervioApp .preferredColorScheme(.dark)), so one
    /// color serves every surface.
    private static let inkColor = UIColor.label

    private static let imageMemo = NSCache<NSString, UIImage>()

    /// The typeset formula, or nil when SwiftMath can't parse it (caller shows
    /// the raw source instead). Memoized — the transcript re-renders constantly.
    /// Model LaTeX → the dialect SwiftMath parses. Models reach for amsmath
    /// habits SwiftMath lacks — `\bigl(…\bigr)` sizing, `\operatorname{}`,
    /// `\dfrac` — and each one failed the WHOLE formula into raw source
    /// (2026-10-12: V^*=\arg\max … P\bigl(…\bigr)). Pure textual mapping to
    /// the supported equivalents; the source message is never altered.
    static func normalized(_ latex: String) -> String {
        var s = latex
        for (a, b) in [("\\Biggl", "\\left"), ("\\biggl", "\\left"), ("\\Bigl", "\\left"), ("\\bigl", "\\left"),
                       ("\\Biggr", "\\right"), ("\\biggr", "\\right"), ("\\Bigr", "\\right"), ("\\bigr", "\\right"),
                       ("\\Bigg", ""), ("\\bigg", ""), ("\\Big", ""), ("\\big", ""),
                       ("\\operatorname*{", "\\mathrm{"), ("\\operatorname{", "\\mathrm{"),
                       ("\\dfrac", "\\frac"), ("\\tfrac", "\\frac"),
                       ("\\displaystyle", ""), ("\\textstyle", ""),
                       ("\\boldsymbol{", "\\mathbf{"), ("\\textbf{", "\\mathbf{"), ("\\textit{", "\\mathit{")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s
    }

    static func image(latex raw: String, fontSize: CGFloat, display: Bool) -> UIImage? {
        let latex = normalized(raw)
        let key = "\(display ? "D" : "T")|\(fontSize)|\(latex)" as NSString
        if let hit = imageMemo.object(forKey: key) { return hit }
        let image: UIImage?
        if let parts = chunks(latex), parts.contains(where: { $0.isText }) {
            image = composite(parts, fontSize: fontSize, display: display)
        } else {
            image = pure(latex, fontSize: fontSize, display: display)
        }
        guard let image, image.size.width > 0 else { return nil }
        imageMemo.setObject(image, forKey: key)
        return image
    }

    /// One SwiftMath render, the whole formula.
    private static func pure(_ latex: String, fontSize: CGFloat, display: Bool) -> UIImage? {
        let renderer = MTMathImage(latex: latex, fontSize: fontSize,
                                   textColor: inkColor,
                                   labelMode: display ? .display : .text,
                                   textAlignment: .left)
        let (error, image) = renderer.asImage()
        guard error == nil, let image else { return nil }
        return image
    }

    // MARK: - CJK inside \text{…}: a hybrid render
    //
    // SwiftMath ships math fonts only — no CJK glyphs — so `\text{读者正确理解目标}`
    // rendered as a silent GAP (2026-10-12, seen in a probe). Dropping words from
    // a formula is worse than showing source, so a formula with non-ASCII text
    // is cut at its top-level \text{…} groups: the math pieces go through
    // SwiftMath, the text pieces through the system font, and the pieces are
    // set on one shared baseline. `\left`/`\right` cannot pair across a cut,
    // so a split formula uses plain delimiters. A non-ASCII \text nested inside
    // braces (a subscript, a fraction) cannot be cut cleanly → nil → raw source.

    struct Chunk: Equatable { let text: String; let isText: Bool }

    static func chunks(_ latex: String) -> [Chunk]? {
        var out: [Chunk] = []
        var math = ""
        var depth = 0
        var i = latex.startIndex
        func flushMath() {
            let m = math.trimmingCharacters(in: .whitespaces)
            if !m.isEmpty { out.append(Chunk(text: m, isText: false)) }
            math = ""
        }
        while i < latex.endIndex {
            let c = latex[i]
            if c == "\\" {
                // an escaped brace is literal; a \text{ at depth 0 may become a cut
                let rest = latex[i...]
                if rest.hasPrefix("\\text{") {
                    let open = latex.index(i, offsetBy: 6)
                    guard let close = matchingBrace(in: latex, from: open) else { return nil }
                    let body = String(latex[open..<close])
                    let hasNonASCII = body.unicodeScalars.contains { $0.value > 0x7F }
                    if hasNonASCII {
                        if depth != 0 { return nil }
                        flushMath()
                        out.append(Chunk(text: body, isText: true))
                    } else {
                        math += String(latex[i...close])   // ASCII \text stays math
                    }
                    i = latex.index(after: close)
                    continue
                }
                let next = latex.index(after: i)
                if next < latex.endIndex { math.append(c); math.append(latex[next]); i = latex.index(after: next); continue }
            } else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1 }
            math.append(c)
            i = latex.index(after: i)
        }
        flushMath()
        return out
    }

    /// Index of the `}` closing the group that starts right after `from`.
    private static func matchingBrace(in s: String, from: String.Index) -> String.Index? {
        var depth = 1
        var i = from
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" { i = s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex; continue }
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1; if depth == 0 { return i } }
            i = s.index(after: i)
        }
        return nil
    }

    private static func composite(_ parts: [Chunk], fontSize: CGFloat, display: Bool) -> UIImage? {
        struct Piece { let draw: (CGContext, CGFloat, CGFloat) -> Void; let ascent: CGFloat; let descent: CGFloat; let width: CGFloat }
        var pieces: [Piece] = []
        let textFont = UIFont.systemFont(ofSize: fontSize)
        for part in parts {
            if part.isText {
                let attr = NSAttributedString(string: part.text, attributes: [.font: textFont, .foregroundColor: inkColor])
                let w = ceil(attr.size().width)
                pieces.append(Piece(draw: { _, x, baseline in attr.draw(at: CGPoint(x: x, y: baseline - textFont.ascender)) },
                                    ascent: textFont.ascender, descent: -textFont.descender, width: w))
            } else {
                // A cut formula cannot pair \left…\right across pieces: plain delimiters.
                let latex = part.text.replacingOccurrences(of: "\\left", with: "").replacingOccurrences(of: "\\right", with: "")
                let label = MTMathUILabel()
                label.fontSize = fontSize
                label.textColor = inkColor
                label.labelMode = display ? .display : .text
                label.contentInsets = .zero
                label.latex = latex
                label.frame = CGRect(origin: .zero, size: label.intrinsicContentSize)
                label.layoutSubviews()
                guard let dl = label.displayList else { return nil }
                // Metrics from the label's layout; pixels from MTMathImage (its
                // rasteriser is upright — layer.render(in:) came out mirrored).
                // MTMathImage centres the line in an image whose height is
                // max(ascent+descent, fontSize/2), baseline at `descent` above
                // the centred line's bottom — reproduce that to find the baseline.
                let (asc, desc) = (dl.ascent, dl.descent)
                let renderer = MTMathImage(latex: latex, fontSize: fontSize, textColor: inkColor,
                                           labelMode: display ? .display : .text, textAlignment: .left)
                let (err, img) = renderer.asImage()
                guard err == nil, let img, img.size.width > 0 else { return nil }
                let line = max(asc + desc, fontSize / 2)
                let baselineFromBottom = (img.size.height - line) / 2 + desc
                pieces.append(Piece(draw: { _, x, baseline in
                    img.draw(at: CGPoint(x: x, y: baseline - (img.size.height - baselineFromBottom)))
                }, ascent: asc, descent: desc, width: img.size.width))
            }
        }
        let ascent = pieces.map(\.ascent).max() ?? 0
        let descent = pieces.map(\.descent).max() ?? 0
        let width = pieces.map(\.width).reduce(0, +)
        guard width > 0, ascent + descent > 0 else { return nil }
        let size = CGSize(width: ceil(width), height: ceil(ascent + descent))
        let format = UIGraphicsImageRendererFormat(); format.scale = 0   // device scale
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            var x: CGFloat = 0
            for p in pieces { p.draw(ctx.cgContext, x, ascent); x += p.width }
        }
    }
}

// MARK: - Display block view

/// One display formula on its own row: centered, horizontally scrollable when
/// wider than the bubble, raw monospace source when the LaTeX doesn't parse.
struct MathBlockView: View {
    let latex: String

    var body: some View {
        if let img = MathText.image(latex: latex, fontSize: 19, display: true) {
            ScrollView(.horizontal, showsIndicators: false) {
                Image(uiImage: img)
                    .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            Text(latex)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
