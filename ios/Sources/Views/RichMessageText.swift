import SwiftUI
import UIKit

/// Main-thread memo for the pure String→render functions below (markdown parse,
/// attributed-string build, syntax highlight). SwiftUI re-evaluates view bodies
/// constantly — and the transcript's non-lazy VStack lays out every row on each
/// pass — so without this the same text was re-parsed/re-highlighted many times
/// per load, which made opening a long conversation stutter. NSCache auto-evicts
/// under memory pressure.
private final class RenderMemo<T> {
    private final class Box { let v: T; init(_ v: T) { self.v = v } }
    private let cache = NSCache<NSString, Box>()
    init(limit: Int = 512) { cache.countLimit = limit }
    func callAsFunction(_ key: String, _ make: () -> T) -> T {
        if let hit = cache.object(forKey: key as NSString) { return hit.v }
        let v = make(); cache.setObject(Box(v), forKey: key as NSString); return v
    }
}

/// Renders an assistant message: prose as block-level Markdown (headings, lists,
/// quotes, rules, plus inline bold/italic/`code`/links) and fenced ```code```
/// blocks as syntax-highlighted, horizontally-scrollable, copyable blocks.
struct RichMessageText: View {
    let text: String
    /// While the turn is still streaming we skip syntax highlighting (rendering
    /// plain monospace) to avoid re-running the regex passes on every token —
    /// the full highlight runs once the turn completes.
    var streaming: Bool = false
    /// Report typography, opted into by the report surfaces only (archive reader,
    /// workflow monitor) — NEVER by chat, so chat bubbles cannot regress. Reports
    /// are heading-rich machine-written markdown; this mode pulls the heading
    /// scale apart, sits each ## section on a faint card, renders bare-URL lines
    /// as tappable chips and `A · B · C` data lines as small secondary mono type.
    var reportStyle: Bool = false
    /// Presentation contract, from a workflow spec's `display`/`actions`. The
    /// defaults keep every existing call site (chat) rendering exactly as before.
    /// Level-2 headings to fold behind a disclosure.
    var collapseSections: [String] = []
    /// Action bindings: text matching an action's regex gets a visible tap-menu
    /// icon at the end of its line (long-press stays with system text selection).
    var actions: [WorkflowAction] = []
    /// Receives the fully-built server command when a menu item is picked.
    var onAction: ((String) -> Void)? = nil

    var body: some View {
        let compiled = CompiledAction.compile(actions)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let s):
                    ProseText(raw: s, report: reportStyle,
                              collapseSections: collapseSections,
                              actions: compiled, onAction: onAction)
                case .code(let language, let content):
                    CodeBlockView(language: language, content: content, highlight: !streaming)
                case .math(let latex):
                    MathBlockView(latex: latex)
                }
            }
        }
    }

    enum Segment {
        case prose(String)
        case code(language: String, content: String)
        case math(String)   // display LaTeX (\[…\] / $$…$$), delimiters stripped
    }

    /// Split on fenced code blocks and display-math blocks. An unterminated
    /// fence (still streaming) is emitted as a code block so it renders nicely
    /// mid-stream; an unterminated math block flushes back as PROSE — while the
    /// formula is still streaming in, the raw source shows, and the typeset
    /// block appears the moment the closing fence lands.
    private static let segmentMemo = RenderMemo<[Segment]>()
    static func parse(_ text: String) -> [Segment] { Self.segmentMemo(text) { parseSegments(text) } }
    private static func parseSegments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [String] = []
        var code: [String] = []
        var math: [String] = []   // raw lines incl. the opening fence, for the prose fallback
        var inCode = false
        var inMath = false
        var language = ""

        func flushProse() {
            let joined = prose.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.prose(joined))
            }
            prose.removeAll()
        }
        func flushCode() {
            segments.append(.code(language: language, content: code.joined(separator: "\n")))
            code.removeAll()
            language = ""
        }

        for line in text.components(separatedBy: "\n") {
            if inMath {
                if MathText.closesDisplay(line) {
                    let latex = math.dropFirst().joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if latex.isEmpty { prose.append(contentsOf: math + [line]) }
                    else { flushProse(); segments.append(.math(latex)) }
                    math.removeAll(); inMath = false
                } else {
                    math.append(line)
                }
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    flushCode(); inCode = false
                } else {
                    flushProse(); inCode = true
                    language = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                }
            } else if inCode {
                code.append(line)
            } else if let latex = MathText.displayFormula(line: line) {
                flushProse(); segments.append(.math(latex))
            } else if MathText.opensDisplay(line) {
                math = [line]; inMath = true
            } else {
                prose.append(line)
            }
        }
        if inCode { flushCode() }
        else {
            if inMath { prose.append(contentsOf: math) }   // still streaming → raw
            flushProse()
        }
        return segments
    }
}

// MARK: - Prose (block-level Markdown)

private struct ProseText: View {
    let raw: String
    var report: Bool = false
    var collapseSections: [String] = []
    var actions: [CompiledAction] = []
    var onAction: ((String) -> Void)? = nil

    var body: some View {
        // Collapse is applied OUTSIDE the parse memo (cheap O(blocks) pass): the
        // memo stays keyed on raw alone, so the same text rendered in chat (no
        // sections) and in a report (sections set) can never poison each other.
        let parsed = MarkdownBlock.parse(raw)
        let blocks = collapseSections.isEmpty
            ? parsed : MarkdownBlock.collapsed(parsed, sections: collapseSections)
        // Report surfaces always take the sectioned block path. In practice this
        // changes nothing about selection: every real report carries <details> or
        // actions, which force block-by-block below anyway — but sectioning must
        // be deterministic, not dependent on which blocks an issue happens to have.
        if report {
            ReportProse(blocks: blocks, actions: actions, onAction: onAction)
        }
        // A table needs the SwiftUI Grid, <details> needs a DisclosureGroup and an
        // image needs AsyncImage, so those (rare) runs render block-by-block.
        // Everything else renders as ONE
        // selectable UITextView, so you can drag-select across the whole answer
        // (paragraphs + list items) in a single gesture — and a single stable view
        // doesn't jump the way many re-measuring ones did. An action hit also
        // forces the block path: one UITextView can't host per-block menus.
        else if blocks.contains(where: {
            switch $0 { case .table, .details, .image: return true; default: return false }
        }) || (!actions.isEmpty && MarkdownBlock.anyActionHit(blocks, actions)) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    block.view(actions: actions, onAction: onAction)
                }
            }
            .textSelection(.enabled)
        } else {
            SelectableText(attributed: Self.attributedMemo(raw) { MarkdownRenderer.attributed(blocks) })
        }
    }

    private static let attributedMemo = RenderMemo<NSAttributedString>()
}

// MARK: - Report prose (sectioned, card-backed)

/// Report-form prose: the same blocks, grouped into sections at level-≤2
/// headings, each ##-led section on a faint `Palette.surface` card so the eye
/// can chunk a long report while scrolling. No new colors, no ornaments — the
/// card is the only added surface, and it reads the existing palette.
private struct ReportProse: View {
    let blocks: [MarkdownBlock]
    var actions: [CompiledAction] = []
    var onAction: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(MarkdownBlock.reportSections(blocks).enumerated()),
                    id: \.offset) { _, section in
                if section.card {
                    sectionBody(section)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Palette.surface.opacity(0.55),
                                    in: RoundedRectangle(cornerRadius: 14))
                } else {
                    sectionBody(section)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func sectionBody(_ section: MarkdownBlock.ReportSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(section.blocks.enumerated()), id: \.offset) { i, block in
                block.view(actions: actions, onAction: onAction,
                           report: true, first: i == 0)
            }
        }
    }
}

/// A report paragraph, classified line-by-line so the two machine-written
/// shapes that dominate digests get their own typography:
///  - a line that IS a bare URL → a tappable chip labelled `owner/name`
///    (github) or the domain — same destination, just not a raw URL wall;
///  - a short `Rust · ⭐9,336 · +2,524 今日` data line → small secondary
///    monospaced type, so metadata stops competing with prose;
///  - a whole-line `<!-- … -->` template marker → hidden (it's plumbing).
/// Runs of normal lines stay merged into ONE Text so wrapping and selection
/// match the ordinary renderer.
struct ReportParagraphView: View {
    let text: String

    var body: some View {
        let pieces = Self.piecesMemo(text) { Self.pieces(text) }
        if pieces.isEmpty {
            EmptyView()                        // marker-only paragraph: no gap
        } else if pieces.count == 1, case .text(let s) = pieces[0] {
            Text(mdInline(s))
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    switch piece {
                    case .text(let s):
                        Text(mdInline(s))
                    case .link(let url, let label):
                        Link(destination: url) {
                            Text(label)
                                .font(.footnote.weight(.medium).monospaced())
                                .lineLimit(1)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                    case .data(let s):
                        Text(mdInline(s))
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    enum Piece {
        case text(String)
        case link(URL, String)
        case data(String)
    }

    private static let piecesMemo = RenderMemo<[Piece]>()

    static func pieces(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var run: [String] = []
        func flushRun() {
            if !run.isEmpty { out.append(.text(run.joined(separator: "\n"))); run.removeAll() }
        }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("<!--"), t.hasSuffix("-->") {
                continue                       // whole-line template marker
            } else if let url = bareURL(t) {
                flushRun(); out.append(.link(url, linkLabel(url)))
            } else if isDataLine(t) {
                flushRun(); out.append(.data(t))
            } else {
                run.append(line)
            }
        }
        flushRun()
        return out
    }

    /// The line is nothing but one URL → that URL. Anything else (prose with an
    /// embedded link, trailing words) is left alone — chips only replace lines
    /// that were pure link plumbing to begin with.
    static func bareURL(_ trimmed: String) -> URL? {
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"),
              !trimmed.contains(" "), !trimmed.contains("\t"),
              let url = URL(string: trimmed), url.host != nil else { return nil }
        return url
    }

    /// Chip label: `owner/name` for github repo URLs, the bare domain otherwise.
    static func linkLabel(_ url: URL) -> String {
        var host = url.host ?? ""
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        if host == "github.com" {
            let segs = url.path.split(separator: "/").prefix(2)
            if segs.count == 2 { return segs.joined(separator: "/") }
        }
        return host.isEmpty ? url.absoluteString : host
    }

    /// A "data line": short, `·`-separated, carries digits, no sentence-ending
    /// punctuation, no links. Deliberately conservative — a miss just renders as
    /// normal prose, a false hit would shrink real prose.
    static func isDataLine(_ trimmed: String) -> Bool {
        guard trimmed.contains(" · "), trimmed.count <= 64,
              trimmed.rangeOfCharacter(from: .decimalDigits) != nil,
              !trimmed.contains("http"), !trimmed.contains("]("),
              !trimmed.contains("。") else { return false }
        return true
    }
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case list(ordered: Bool, start: Int, items: [String])
    case quote(String)
    case rule
    case paragraph(String)
    case table(headers: [String], rows: [[String]])
    /// A standalone `![alt](url)` line. Only minted for https://arxiv.org/ URLs
    /// (defense in depth with the server's own allowlist) — anything else stays
    /// a plain paragraph. alt doubles as the caption line under the image.
    case image(alt: String, url: URL)
    // Arrays box their elements, so the self-reference needs no `indirect`.
    case details(summary: String, blocks: [MarkdownBlock])

    @ViewBuilder var view: some View { view(actions: [], onAction: nil) }

    /// The block's view, with the actions tap-menu icon appended to whatever
    /// piece of it matches an action regex. A list appends per ITEM (one row can
    /// carry one paper's menu while the next row carries another's); a details
    /// block passes the actions down so a collapsed section keeps its menus.
    ///
    /// `report` (default false → chat renders EXACTLY as before) switches to the
    /// report typography; `first` marks a section's leading block so its heading
    /// doesn't stack its own top padding onto the card's.
    @ViewBuilder func view(actions: [CompiledAction], onAction: ((String) -> Void)?,
                           report: Bool = false, first: Bool = false) -> some View {
        switch self {
        case .heading(let level, let text):
            HeadingText(text: mdInline(text),
                        size: report ? Self.reportHeadingSize(level) : Self.headingSize(level))
                .padding(.top, Self.headingTopPad(level, report: report, first: first))
                .reportActionMenu(text: text, actions: actions, onAction: onAction)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: report ? 7 : 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    Self.listRow(marker: ordered ? "\(start + i)." : "•", item: item,
                                 actions: actions, onAction: onAction)
                }
            }
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.5)).frame(width: 3)
                Text(mdInline(text)).foregroundStyle(.secondary)
            }
            .reportActionMenu(text: text, actions: actions, onAction: onAction)
        case .rule:
            Divider().padding(.vertical, 2)
        case .paragraph(let text):
            if report {
                ReportParagraphView(text: text)
                    .reportActionMenu(text: text, actions: actions, onAction: onAction)
            } else {
                Text(mdInline(text))
                    .reportActionMenu(text: text, actions: actions, onAction: onAction)
            }
        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)
                .reportActionMenu(text: Self.tableText(headers, rows),
                                  actions: actions, onAction: onAction)
        case .image(let alt, let url):
            MarkdownImageView(alt: alt, url: url)
        case .details(let summary, let blocks):
            MarkdownDetailsView(summary: summary, blocks: blocks,
                                actions: actions, onAction: onAction, report: report)
        }
    }

    /// One list row: its marker, its text, and the rating menu that hangs off
    /// THAT row's text. Extracted from the `.list` case above — its only caller
    /// — because a `ForEach`'s content closure cannot be walked by a test, and
    /// "the icon is really attached, and really fed this item's text" is exactly
    /// what ReportMenuAttachmentTests has to be able to see.
    static func listRow(marker: String, item: String, actions: [CompiledAction],
                        onAction: ((String) -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.body.monospacedDigit()).foregroundStyle(.secondary)
            Text(mdInline(item))
            ReportActionMenuIcon(text: item, actions: actions, onAction: onAction)
        }
    }

    /// One string per table for action matching (first hit wins, like any block).
    static func tableText(_ headers: [String], _ rows: [[String]]) -> String {
        (headers + rows.flatMap { $0 }).joined(separator: " ")
    }

    /// One place a rating menu can hang: the exact string a block hands to the
    /// action regexes, and which piece of the report it belongs to. The same
    /// contract is rendered on the Mac by server/bin/pervio-view as a
    /// `<span class="acts">` button group, so this list — its length AND its
    /// order — is a cross-screen agreement, frozen in
    /// ios/Tests/Fixtures/reports/actions-contract.json.
    struct ActionTarget: Equatable {
        enum Kind: String { case heading, listItem, quote, paragraph, table }
        let kind: Kind
        let text: String
    }

    /// Every text these blocks offer to the action regexes, in document order —
    /// list items individually, `<details>` bodies recursively, rules never.
    /// The single source for "where can a rating button appear": `view(...)`
    /// hangs `ReportActionMenuIcon` off exactly these strings, and
    /// `anyActionHit` below is just "does any of them hit".
    static func actionTargets(_ blocks: [MarkdownBlock]) -> [ActionTarget] {
        var out: [ActionTarget] = []
        for b in blocks {
            switch b {
            case .heading(_, let t):     out.append(ActionTarget(kind: .heading, text: t))
            case .paragraph(let t):      out.append(ActionTarget(kind: .paragraph, text: t))
            case .quote(let t):          out.append(ActionTarget(kind: .quote, text: t))
            case .list(_, _, let items): out += items.map { ActionTarget(kind: .listItem, text: $0) }
            case .table(let h, let r):   out.append(ActionTarget(kind: .table, text: tableText(h, r)))
            case .image:                 break   // a figure offers no rating text
            case .details(_, let inner): out += actionTargets(inner)
            case .rule:                  continue
            }
        }
        return out
    }

    /// The action hit for each target that has one, in document order — the
    /// phone's half of the button-group contract.
    static func actionHits(_ blocks: [MarkdownBlock], _ actions: [CompiledAction])
        -> [(target: ActionTarget, hit: (action: CompiledAction, groups: [String]))] {
        guard !actions.isEmpty else { return [] }
        return actionTargets(blocks).compactMap { t in
            CompiledAction.firstHit(in: t.text, actions).map { (t, $0) }
        }
    }

    /// True when any of these blocks' texts (list items and collapsed details
    /// included) hits an action regex — the signal that this prose run must
    /// render block-by-block so the menus have views to attach to.
    static func anyActionHit(_ blocks: [MarkdownBlock], _ actions: [CompiledAction]) -> Bool {
        guard !actions.isEmpty else { return false }
        return actionTargets(blocks).contains {
            CompiledAction.firstHit(in: $0.text, actions) != nil
        }
    }

    /// Point size and weight per heading level, at the phone's own text size;
    /// HeadingText scales the size to the person's step (Settings).
    static func headingSize(_ level: Int) -> (CGFloat, Font.Weight) {
        switch level {
        case 1:  return (22, .bold)
        case 2:  return (18, .semibold)
        case 3:  return (16, .semibold)
        default: return (14, .semibold)
        }
    }

    /// Report heading scale: one size step wider apart than chat's, so the
    /// masthead / section / entry levels read at a glance while scrolling.
    /// (Chat keeps `headingFont` untouched — the zero-regression line.)
    static func reportHeadingSize(_ level: Int) -> (CGFloat, Font.Weight) {
        switch level {
        case 1:  return (24, .bold)
        case 2:  return (19, .semibold)
        case 3:  return (17, .semibold)
        default: return (15, .semibold)
        }
    }

    /// Heading top padding. Chat: the historical 8/2. Report: more air above a
    /// heading (structure breathes), except a section's FIRST block, where the
    /// card's own padding already provides the separation.
    static func headingTopPad(_ level: Int, report: Bool, first: Bool) -> CGFloat {
        guard report else { return level <= 2 ? 8 : 2 }
        if first { return 0 }
        switch level {
        case 1, 2: return 12
        case 3:    return 10
        default:   return 8
        }
    }

    /// One report section: the blocks from one level-≤2 heading up to the next.
    /// `card` marks the ##-led groups that sit on the faint card background.
    struct ReportSection {
        let card: Bool
        let blocks: [MarkdownBlock]
    }

    /// Group blocks into report sections: a new group opens at every level-1/2
    /// heading; ##-led groups get the card treatment, the preamble and #-led
    /// groups render plain (masthead). A `---` rule touching a section boundary
    /// is dropped — the hand-drawn separator's job is now done by the card gap,
    /// and keeping both would double-rule every section. Rules WITHIN a section
    /// stay.
    static func reportSections(_ blocks: [MarkdownBlock]) -> [ReportSection] {
        var out: [ReportSection] = []
        var run: [MarkdownBlock] = []
        var card = false
        func flush() {
            while case .rule? = run.first { run.removeFirst() }
            while case .rule? = run.last { run.removeLast() }
            if !run.isEmpty { out.append(ReportSection(card: card, blocks: run)) }
            run = []
        }
        for block in blocks {
            if case .heading(let level, _) = block, level <= 2 {
                flush()
                card = (level == 2)
            } else if case .details = block, card, case .rule? = run.last {
                // A `---` + `<details>` tail inside a ## section is a
                // document-level appendix (the daily's "scanned but not
                // picked" fold), not part of the entry above it — the rule
                // says so in the source. Pop it out of the card.
                flush()
                card = false
            }
            run.append(block)
        }
        flush()
        return out
    }

    /// Group lines into block elements. Pure raw→blocks (the memo must stay keyed
    /// on raw alone); collapse is a separate post-pass the caller opts into.
    private static let blockMemo = RenderMemo<[MarkdownBlock]>()
    static func parse(_ raw: String) -> [MarkdownBlock] { Self.blockMemo(raw) { parseBlocks(raw) } }

    /// `![alt](url)` filling the WHOLE line, url on the arxiv.org allowlist.
    /// Pure + static so a unit test pins the exact acceptance rule.
    static func imageLine(_ trimmed: String) -> (alt: String, url: URL)? {
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")"),
              let mid = trimmed.range(of: "](") else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<mid.lowerBound])
        let urlStr = String(trimmed[mid.upperBound..<trimmed.index(before: trimmed.endIndex)])
        guard urlStr.hasPrefix("https://arxiv.org/"), !alt.contains("]"),
              let url = URL(string: urlStr) else { return nil }
        return (alt, url)
    }

    /// Reports ship as PLAIN markdown (a phone renderer may lag the template —
    /// raw <details> tags once leaked onto the screen verbatim), so the collapse
    /// interaction lives here in the viewer: each level-2 section whose heading
    /// is in `sections` (the spec's display.collapseSections) folds behind a
    /// disclosure. A section with no list items is left alone.
    static func collapsed(_ blocks: [MarkdownBlock], sections: [String]) -> [MarkdownBlock] {
        guard !sections.isEmpty else { return blocks }
        var out: [MarkdownBlock] = []
        var i = 0
        while i < blocks.count {
            let block = blocks[i]
            out.append(block)
            guard case .heading(let l, let t) = block, l == 2,
                  sections.contains(t.trimmingCharacters(in: .whitespaces)) else {
                i += 1; continue
            }
            var end = blocks.count
            for j in (i + 1)..<blocks.count {
                if case .heading(let hl, _) = blocks[j], hl <= 2 { end = j; break }
            }
            let inner = Array(blocks[(i + 1)..<end])
            // Compat-layer guard rail: collapseSections is the LEGACY fold hint —
            // new templates fold their own content with literal <details> in the
            // markdown. A spec migrating between the two can carry both, and
            // wrapping a section whose body already parsed a .details block would
            // nest fold-inside-fold. Skip such a section (its own fold wins); old
            // issues with no details still get this viewer-side fold.
            guard !inner.contains(where: {
                if case .details = $0 { return true } else { return false }
            }) else { i += 1; continue }
            let count = inner.reduce(0) { n, b in
                if case .list(_, _, let items) = b { return n + items.count } else { return n }
            }
            guard count > 0 else { i += 1; continue }
            out.append(.details(summary: L.expandEntries(count), blocks: inner))
            i = end
        }
        return out
    }
    private static func parseBlocks(_ raw: String, allowDetails: Bool = true) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var para: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []
        var numbersStart = 1            // the source number of the run's first item
        var quotes: [String] = []

        func flushPara() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para.removeAll() }
        }
        func flushBullets() {
            if !bullets.isEmpty { blocks.append(.list(ordered: false, start: 1, items: bullets)); bullets.removeAll() }
        }
        func flushNumbers() {
            if !numbers.isEmpty {
                blocks.append(.list(ordered: true, start: numbersStart, items: numbers))
                numbers.removeAll(); numbersStart = 1
            }
        }
        func flushQuotes() {
            if !quotes.isEmpty { blocks.append(.quote(quotes.joined(separator: "\n"))); quotes.removeAll() }
        }
        func flushAll() { flushPara(); flushBullets(); flushNumbers(); flushQuotes() }

        let lines = raw.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Table: a header row with '|' whose next line is a |---|:--:| separator
            // with the same column count. Body = following '|' rows.
            if trimmed.contains("|"), i + 1 < lines.count,
               Self.isTableSeparator(lines[i + 1]),
               Self.tableCells(trimmed).count == Self.tableCells(lines[i + 1]).count {
                let headers = Self.tableCells(trimmed)
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|") else { break }
                    rows.append(Self.tableCells(t))
                    j += 1
                }
                flushAll(); blocks.append(.table(headers: headers, rows: rows))
                i = j; continue
            }

            // Collapsible details: a strict lowercase `<details>` alone on its line,
            // an optional single-line `<summary>…</summary>`, body lines, `</details>`.
            // A missing close tag swallows to end-of-text and still renders (treated
            // as closed). `j` only moves forward and ends ≥ i + 1, so no input can
            // stall the loop. Nesting is unsupported: the body re-parses with
            // `allowDetails: false`, so an inner `<details>` falls out as a paragraph.
            // Standalone image line: the digest's 方法图 (author's own figure,
            // extracted server-side). Whole-line matches only; non-arxiv URLs
            // fall through and render as visible text — never as a tap target.
            if let img = Self.imageLine(trimmed) {
                flushAll(); blocks.append(.image(alt: img.alt, url: img.url))
                i += 1; continue
            }

            if allowDetails, trimmed == "<details>" {
                flushAll()
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                var summary = L.detailsDefaultSummary()
                if j < lines.count,
                   let s = Self.summaryText(lines[j].trimmingCharacters(in: .whitespaces)) {
                    if !s.isEmpty { summary = s }
                    j += 1
                }
                var inner: [String] = []
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces) != "</details>" {
                    inner.append(lines[j]); j += 1
                }
                if j < lines.count { j += 1 }   // consume the close tag when present
                blocks.append(.details(summary: summary,
                                       blocks: parseBlocks(inner.joined(separator: "\n"),
                                                           allowDetails: false)))
                i = j; continue
            }

            if trimmed.isEmpty {
                flushAll(); i += 1; continue
            }
            // Horizontal rule: ---, ***, ___ (3+ of the same marker char)
            if trimmed.count >= 3, Set(trimmed).count == 1,
               let first = trimmed.first, "-*_".contains(first) {
                flushAll(); blocks.append(.rule); i += 1; continue
            }
            // Heading: # .. ######
            if let h = Self.heading(trimmed) {
                flushAll(); blocks.append(.heading(level: h.0, text: h.1)); i += 1; continue
            }
            // Bullet list: -, *, +
            if let item = Self.bulletItem(trimmed) {
                flushPara(); flushNumbers(); flushQuotes(); bullets.append(item); i += 1; continue
            }
            // Numbered list: 1. 2) ... — keep the SOURCE number so an item split off
            // by a continuation paragraph still shows its real ordinal (not "1.").
            if let item = Self.numberedItem(trimmed) {
                flushPara(); flushBullets(); flushQuotes()
                if numbers.isEmpty { numbersStart = item.0 }
                numbers.append(item.1); i += 1; continue
            }
            // Quote: >
            if trimmed.hasPrefix(">") {
                flushPara(); flushBullets(); flushNumbers()
                quotes.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1; continue
            }
            // Paragraph line
            flushBullets(); flushNumbers(); flushQuotes(); para.append(line); i += 1
        }
        flushAll()
        return blocks
    }

    /// Cells of a table row, with the outer pipes dropped and each cell trimmed.
    static func tableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// True if `line` is a markdown table separator row, e.g. |---|:--:|---|.
    static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        for c in cells {
            guard !c.isEmpty, c.contains("-"),
                  c.allSatisfy({ $0 == "-" || $0 == ":" }) else { return false }
        }
        return true
    }

    private static func heading(_ s: String) -> (Int, String)? {
        var level = 0
        for ch in s { if ch == "#" { level += 1 } else { break } }
        guard level >= 1, level <= 6, s.count > level,
              s[s.index(s.startIndex, offsetBy: level)] == " " else { return nil }
        let text = String(s.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func bulletItem(_ s: String) -> String? {
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            return String(s.dropFirst(marker.count))
        }
        return nil
    }

    private static func numberedItem(_ s: String) -> (Int, String)? {
        var digits = ""
        for ch in s { if ch.isNumber { digits.append(ch) } else { break } }
        guard !digits.isEmpty, let n = Int(digits) else { return nil }
        let rest = s.dropFirst(digits.count)
        guard let sep = rest.first, sep == "." || sep == ")" else { return nil }
        let after = rest.dropFirst()
        guard after.first == " " else { return nil }
        return (n, String(after.dropFirst()))
    }

    /// `<summary>…</summary>` alone on one (trimmed) line → its inner text, else nil.
    private static func summaryText(_ s: String) -> String? {
        guard s.hasPrefix("<summary>"), s.hasSuffix("</summary>"),
              s.count >= "<summary></summary>".count else { return nil }
        return String(s.dropFirst("<summary>".count).dropLast("</summary>".count))
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Inline Markdown (bold, italic, inline `code`, links) for one block of text.
func mdInline(_ s: String) -> AttributedString {
    var a = (try? AttributedString(
        markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(s)
    // Accent color alone reads as decoration, not affordance (user couldn't tell
    // paper titles were tappable) — underline is the one universal link signal.
    // Scheme allowlist (2026-08-22 audit): this text is REMOTE content (digests,
    // reports, model replies), and a link here lands verbatim in UITextView's
    // .link attribute with no other filter anywhere — so a hostile
    // [tap](tel://…) or third-party-app scheme would launch on tap. http(s) and
    // mailto stay links; anything else renders as plain text.
    for run in a.runs {
        guard var url = run.link else { continue }
        // A bare server path (`/Users/…`, `~/…`) becomes a pervio-file: link the
        // phone can open as a preview (ServerFilePreview) — a model routinely
        // links its outputs that way and the link used to be dead on the phone.
        if let server = ServerFileLink.rewrite(url) { url = server; a[run.range].link = server }
        if let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", ServerFileLink.scheme].contains(scheme) {
            a[run.range].underlineStyle = .single
        } else {
            a[run.range].link = nil
        }
    }
    return a
}

/// Renders a whole prose run (headings, paragraphs, lists, quotes) into ONE
/// NSAttributedString with concrete fonts + paragraph styles, so a single UITextView
/// can show it and let you drag-select across the entire answer.
private enum MarkdownRenderer {
    static func attributed(_ blocks: [MarkdownBlock], color: UIColor = .label) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (idx, block) in blocks.enumerated() {
            let isLast = idx == blocks.count - 1
            let nl = { if !isLast { out.append(NSAttributedString(string: "\n")) } }
            switch block {
            case .heading(let level, let text):
                out.append(styled(inline(text, base: headingFont(level), color: color),
                                  base: headingFont(level),
                                  spacingBefore: idx == 0 ? 0 : 8, spacingAfter: 2))
                nl()
            case .paragraph(let text):
                out.append(styled(inline(text, base: body, color: color), base: body,
                                  spacingAfter: isLast ? 0 : 9))
                nl()
            case .image(let alt, let url):
                // The selectable-text lane can't host a live image; represent the
                // figure as its caption LINK so drag-select and chat contexts
                // still carry something meaningful. The report lane renders the
                // real image via MarkdownBlock.view.
                out.append(styled(inline("[\(alt.isEmpty ? "方法图" : alt)](\(url.absoluteString))",
                                         base: body, color: color),
                           base: body, spacingAfter: isLast ? 0 : 9))
                nl()
            case .list(let ordered, let start, let items):
                let style = NSMutableParagraphStyle()
                style.headIndent = 20
                style.tabStops = [NSTextTab(textAlignment: .left, location: 20)]
                style.paragraphSpacing = 3
                let lh = uniformLineHeight(for: body)
                style.minimumLineHeight = lh; style.maximumLineHeight = lh
                for (j, item) in items.enumerated() {
                    let line = NSMutableAttributedString(
                        string: (ordered ? "\(start + j)." : "•") + "\t",
                        attributes: [.font: body, .foregroundColor: UIColor.secondaryLabel])
                    line.append(inline(item, base: body, color: color))
                    line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                    out.append(line)
                    if !(j == items.count - 1 && isLast) { out.append(NSAttributedString(string: "\n")) }
                }
            case .quote(let text):
                let style = NSMutableParagraphStyle()
                style.headIndent = 14; style.firstLineHeadIndent = 14
                style.paragraphSpacing = isLast ? 0 : 9
                let lh = uniformLineHeight(for: body)
                style.minimumLineHeight = lh; style.maximumLineHeight = lh
                let a = NSMutableAttributedString(attributedString: inline(text, base: body, color: .secondaryLabel))
                a.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: a.length))
                out.append(a)
                nl()
            case .rule:
                out.append(NSAttributedString(string: "──────\n", attributes: [
                    .font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.tertiaryLabel]))
            case .table(let headers, let rows):
                let text = ([headers] + rows).map { $0.joined(separator: "  |  ") }.joined(separator: "\n")
                out.append(inline(text, base: .monospacedSystemFont(ofSize: 12, weight: .regular), color: color))
                nl()
            case .details(let summary, let blocks):
                // Unreachable from ProseText (a .details run takes the per-block view
                // path), but stay lossless: summary line, then the body expanded.
                out.append(styled(inline(summary, base: body, color: .secondaryLabel),
                                  base: body, spacingAfter: 4))
                out.append(NSAttributedString(string: "\n"))
                out.append(attributed(blocks, color: color))
                nl()
            }
        }
        return out
    }

    private static var body: UIFont { .preferredFont(forTextStyle: .body) }

    private static func headingFont(_ level: Int) -> UIFont {
        switch level {
        case 1:  return .systemFont(ofSize: 22, weight: .bold)
        case 2:  return .systemFont(ofSize: 18, weight: .semibold)
        case 3:  return .systemFont(ofSize: 16, weight: .semibold)
        default: return .systemFont(ofSize: 14, weight: .semibold)
        }
    }

    private static func styled(_ a: NSAttributedString, base: UIFont, spacingBefore: CGFloat = 0,
                               spacingAfter: CGFloat = 0) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.lineSpacing = 2
        // Pin a uniform line height so a wrapped line that happens to contain inline
        // `code` or **bold** (taller fonts) doesn't gain extra leading and make the
        // line spacing look uneven within one paragraph.
        let lh = uniformLineHeight(for: base)
        style.minimumLineHeight = lh
        style.maximumLineHeight = lh
        let m = NSMutableAttributedString(attributedString: a)
        m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
        return m
    }

    /// A line height tall enough for the base font AND inline monospace at the same
    /// point size, so every line is the same height no matter which inline fonts it
    /// mixes — the cure for the uneven spacing of mixed-font runs.
    private static func uniformLineHeight(for base: UIFont) -> CGFloat {
        let mono = UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
        return ceil(max(base.lineHeight, mono.lineHeight))
    }

    /// Inline markdown (bold/italic/`code`/links) → NSAttributedString with fonts.
    private static func inline(_ s: String, base: UIFont, color: UIColor) -> NSAttributedString {
        // Inline math must be lifted out BEFORE the markdown parse: CommonMark
        // eats `\(` as an escape and reads `$a_i$ 与 $b_j$` as italics, mangling
        // the formula's source. Each span becomes a U+FFFC placeholder here and
        // is swapped for its typeset image (or its raw source, if SwiftMath
        // can't parse it) after the attributed string is built.
        let spans = MathText.inlineSpans(in: s)
        var text = ""
        var pending: [(latex: String, original: String)] = []
        var cursor = s.startIndex
        for span in spans {
            text += s[cursor..<span.range.lowerBound]
            text += "\u{FFFC}"
            pending.append((span.latex, String(s[span.range])))
            cursor = span.range.upperBound
        }
        text += s[cursor...]
        let rendered = inlineMarkdown(text, base: base, color: color)
        if pending.isEmpty { return rendered }
        let out = NSMutableAttributedString(attributedString: rendered)
        // An attachment IS a U+FFFC character too, so each search must start
        // past the previous swap — searching from 0 re-found the first image
        // every time and stacked every formula into that one slot (2026-10-12:
        // "其中 ℱ(D) 是数据, 是目标 insight, 是设计…" — three symbols blank).
        var searchFrom = 0
        for item in pending {
            let ns = out.string as NSString
            let r = ns.range(of: "\u{FFFC}", range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            guard r.location != NSNotFound else { break }
            searchFrom = r.location + 1
            if let img = MathText.image(latex: item.latex, fontSize: base.pointSize, display: false) {
                let att = NSTextAttachment(image: img)
                // Center the formula on the surrounding line's cap height so
                // descenders (fractions, subscripts) hang naturally.
                att.bounds = CGRect(x: 0, y: (base.capHeight - img.size.height) / 2,
                                    width: img.size.width, height: img.size.height)
                out.replaceCharacters(in: r, with: NSAttributedString(attachment: att))
            } else {
                out.replaceCharacters(in: r, with: NSAttributedString(
                    string: item.original,
                    attributes: [.font: UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular),
                                 .foregroundColor: color]))
            }
        }
        return out
    }

    private static func inlineMarkdown(_ s: String, base: UIFont, color: UIColor) -> NSAttributedString {
        guard let attr = try? AttributedString(
            markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: s, attributes: [.font: base, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in attr.runs {
            let piece = String(attr[run.range].characters)
            var font = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
                } else {
                    var traits = base.fontDescriptor.symbolicTraits
                    if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                    if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                    if let d = base.fontDescriptor.withSymbolicTraits(traits) {
                        font = UIFont(descriptor: d, size: base.pointSize)
                    }
                }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let link = run.link {
                attrs[.link] = ServerFileLink.rewrite(link) ?? link   // server paths open on the phone
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}

// MARK: - Table

/// A markdown table rendered as an aligned, horizontally-scrollable grid.
private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, cell in
                        Text(mdInline(cell)).font(.footnote.weight(.semibold))
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(mdInline(cell)).font(.footnote)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 0.5))
    }
}

// MARK: - Details (collapsible)

/// A `<details>`/`<summary>` run rendered as a collapsed-by-default disclosure —
/// same look as the transcript's "Thinking" disclosure. Carries the actions down
/// so items inside a collapsed section keep their tap menus.
private struct MarkdownDetailsView: View {
    let summary: String
    let blocks: [MarkdownBlock]
    var actions: [CompiledAction] = []
    var onAction: ((String) -> Void)? = nil
    /// Report mode flows down so folded content gets the same treatment as the
    /// rest of the report, and the summary line steps up to .footnote — one
    /// uniform fold style whether the fold came from literal <details> in the
    /// markdown or the legacy collapseSections hint (both land here).
    var report: Bool = false
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    block.view(actions: actions, onAction: onAction, report: report)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Text(mdInline(summary))
                .font(report ? .footnote.weight(.medium) : .caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }
}

// MARK: - Report actions (spec `actions` → visible tap menus)

/// A spec `actions` entry with its regex compiled once. Entries with an invalid
/// pattern, no pattern, or an empty menu are silently dropped — a bad template
/// must never crash the viewer.
struct CompiledAction {
    let regex: NSRegularExpression
    let menu: [String]
    let run: String

    /// NSRegularExpression is immutable/thread-safe, so compiles are memoized by
    /// pattern (SwiftUI re-evaluates bodies constantly).
    private static let regexMemo = RenderMemo<NSRegularExpression?>()

    static func compile(_ actions: [WorkflowAction]) -> [CompiledAction] {
        actions.compactMap { a in
            guard !a.match.isEmpty, !a.menu.isEmpty, !a.run.isEmpty,
                  let re = regexMemo(a.match, { try? NSRegularExpression(pattern: a.match) })
            else { return nil }
            return CompiledAction(regex: re, menu: a.menu, run: a.run)
        }
    }

    /// The first action whose regex hits `text`, with the capture groups of its
    /// first match (unmatched optional groups come back as "").
    static func firstHit(in text: String, _ actions: [CompiledAction])
        -> (action: CompiledAction, groups: [String])? {
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for a in actions {
            guard let m = a.regex.firstMatch(in: text, options: [], range: range) else { continue }
            var groups: [String] = []
            for gi in 1..<max(m.numberOfRanges, 1) {
                if let r = Range(m.range(at: gi), in: text) {
                    groups.append(String(text[r]))
                } else {
                    groups.append("")
                }
            }
            return (a, groups)
        }
        return nil
    }
}

/// Builds the server command for one picked menu item. Kept as a plain,
/// UI-free enum so the quoting logic is reviewable/testable in isolation.
enum ActionCommand {
    /// `s` as ONE literal shell word: single-quoted, embedded single quotes
    /// escaped as '\'' (close, escaped quote, reopen). Defense in depth — the
    /// capture groups are already regex-constrained and choices come from the
    /// template's menu whitelist, but every substituted value gets quoted anyway.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Substitute {1}…{9} (capture groups) and {choice} into `run`. Placeholders
    /// must be written BARE in the template — quoting is this function's job.
    /// Single left-to-right pass over the template only: substituted values are
    /// never rescanned, so data containing "{choice}" or "{1}" stays data.
    static func build(run: String, groups: [String], choice: String) -> String {
        var out = ""
        var i = run.startIndex
        while i < run.endIndex {
            if run[i] == "{" {
                if run[i...].hasPrefix("{choice}") {
                    out += shellQuote(choice)
                    i = run.index(i, offsetBy: "{choice}".count)
                    continue
                }
                let ni = run.index(after: i)
                if ni < run.endIndex, let d = run[ni].wholeNumberValue, (1...9).contains(d),
                   case let ci = run.index(after: ni), ci < run.endIndex, run[ci] == "}" {
                    out += shellQuote(d <= groups.count ? groups[d - 1] : "")
                    i = run.index(after: ci)
                    continue
                }
            }
            out.append(run[i])
            i = run.index(after: i)
        }
        return out
    }
}

/// The visible entry point for a report action: a small tap-triggered Menu at
/// the end of a matched heading/row. Replaces the old `.contextMenu` binding,
/// whose long-press swallowed the system's long-press text selection
/// (user-confirmed regression) — a tap opens the menu, long-press stays with
/// selection. Renders nothing when `text` hits no action or there is no
/// handler, so unmatched rows lay out exactly as before.
private struct ReportActionMenuIcon: View {
    let text: String
    let actions: [CompiledAction]
    let onAction: ((String) -> Void)?

    var body: some View {
        if let onAction, !actions.isEmpty,
           let hit = CompiledAction.firstHit(in: text, actions) {
            Menu {
                ForEach(Array(hit.action.menu.enumerated()), id: \.offset) { _, choice in
                    Button(choice) {
                        onAction(ActionCommand.build(run: hit.action.run,
                                                     groups: hit.groups, choice: choice))
                    }
                }
            } label: {
                // A visible pill, not a glyph lost in the text: at .caption size
                // the entry point was invisible (user: 根本看不到) and far below
                // any sane tap target.
                Image(systemName: "hand.thumbsup")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
            }
            .contentShape(Capsule())
            // fixedSize: wrapping body text must never squeeze the icon away;
            // selection off keeps drag-select from grabbing the button.
            .fixedSize()
            .textSelection(.disabled)
        }
    }
}

private extension View {
    /// Append the visible action-menu icon after this view, baseline-aligned,
    /// when `text` hits an action's regex (first hit wins; its capture groups
    /// feed the command). No hit, no actions, or no handler → the view is
    /// returned untouched.
    @ViewBuilder func reportActionMenu(text: String, actions: [CompiledAction],
                                       onAction: ((String) -> Void)?) -> some View {
        if onAction != nil, !actions.isEmpty,
           CompiledAction.firstHit(in: text, actions) != nil {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                self
                ReportActionMenuIcon(text: text, actions: actions, onAction: onAction)
            }
        } else {
            self
        }
    }
}

// MARK: - Code block (syntax-highlighted)

private struct CodeBlockView: View {
    let language: String
    let content: String
    var highlight: Bool = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = content
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                codeText
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }

    @ViewBuilder private var codeText: some View {
        if highlight {
            Text(SyntaxHighlighter.highlight(content))
        } else {
            // Mid-stream: plain monospace, no per-token regex storm.
            Text(content).font(.system(.footnote, design: .monospaced))
        }
    }
}

/// A tiny, dependency-free, language-agnostic highlighter: it colors strings,
/// comments, numbers and a broad keyword set with a Tokyo-Night-ish palette.
/// Not a full parser — good enough to make code readable at a glance.
enum SyntaxHighlighter {
    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
    private static let base    = rgb(0xC0, 0xCA, 0xF5)
    private static let keyword = rgb(0xBB, 0x9A, 0xF7)   // purple
    private static let string  = rgb(0x9E, 0xCE, 0x6A)   // green
    private static let comment = rgb(0x56, 0x5F, 0x89)   // muted gray
    private static let number  = rgb(0xFF, 0x9E, 0x64)   // orange

    private static let keywords =
        "func|let|var|const|if|else|elif|for|while|return|class|struct|enum|protocol|extension|" +
        "import|from|def|lambda|self|super|public|private|internal|fileprivate|static|final|guard|" +
        "switch|case|default|break|continue|in|is|as|do|try|catch|throw|throws|rethrows|async|await|" +
        "new|delete|function|typeof|interface|type|namespace|void|int|float|double|bool|boolean|" +
        "string|char|long|short|true|false|nil|null|None|True|False|undefined|and|or|not|with|yield|" +
        "assert|pass|raise|except|finally|then|begin|end|fn|use|impl|trait|where|match|mut|pub|unsafe"

    private static let memo = RenderMemo<AttributedString>()
    static func highlight(_ code: String) -> AttributedString { Self.memo(code) { highlightImpl(code) } }
    private static func highlightImpl(_ code: String) -> AttributedString {
        let ns = NSMutableAttributedString(string: code, attributes: [
            .foregroundColor: base,
            .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        ])
        let full = NSRange(code.startIndex..., in: code)

        func color(_ pattern: String, _ ui: UIColor, _ opts: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return }
            for m in re.matches(in: code, range: full) {
                ns.addAttribute(.foregroundColor, value: ui, range: m.range)
            }
        }

        // Order matters: later passes override earlier ones inside their ranges.
        color("\\b(\(keywords))\\b", keyword)
        color("\\b\\d[\\d_]*(\\.\\d+)?([eE][+-]?\\d+)?\\b", number)
        color("\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`", string)
        color("//[^\\n]*", comment)
        color("/\\*[\\s\\S]*?\\*/", comment)
        // python/shell line comments — only `# ` / `#!` / a lone `#` at line start,
        // so Swift `#selector`, C `#include`, CSS `#fff` aren't painted as comments.
        color("^[ \\t]*#(?= |!|$)[^\\n]*", comment, [.anchorsMatchLines])

        return AttributedString(ns)
    }
}


/// The digest's embedded method figure. Loads lazily, caps its height (paper
/// figures are often enormous), and on ANY failure collapses to nothing — a
/// broken-image icon in a published issue would be worse than no figure, and
/// the server already HEAD-verified the URL once at publish time.
struct MarkdownImageView: View {
    let alt: String
    let url: URL
    @State private var image: UIImage?
    @State private var fastLaneMissed = false
    @State private var zoomed = false

    var body: some View {
        Group {
            if let image {
                figure(Image(uiImage: image))
            } else if fastLaneMissed {
                // Lanes 1-2 (phone cache / SSH from the Mac's publish-time
                // cache) came up empty — fall back to fetching arxiv directly.
                // Slow networks spin here; that's the lane this fallback is.
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        figure(img)
                            .task {
                                // Stash the bitmap so tap-to-zoom works on the
                                // fallback lane too (SwiftUI's Image won't hand
                                // its bitmap back; refetch hits the URL cache).
                                if image == nil,
                                   let (d, _) = try? await URLSession.shared.data(from: url) {
                                    image = UIImage(data: d)
                                }
                            }
                    case .empty: placeholder
                    default: EmptyView()
                    }
                }
            } else {
                placeholder
            }
        }
        .task(id: url) {
            image = nil; fastLaneMissed = false
            if let id = FigureStore.paperId(from: url),
               let cached = await FigureStore.shared.image(for: id) {
                image = cached
            } else {
                fastLaneMissed = true
            }
        }
    }

    private func figure(_ img: Image) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            img.resizable().scaledToFit()
                .frame(maxHeight: 260)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if !alt.isEmpty {
                Text(alt).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            // Zoom needs the decoded bitmap; the fast lanes stash it in `image`,
            // and the direct-URL fallback path re-lands it here on first tap.
            if image != nil { zoomed = true }
        }
        .fullScreenCover(isPresented: $zoomed) {
            if let image {
                ZoomableFigureViewer(image: image, caption: alt)
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.08))
            .frame(height: 120)
            .overlay(ProgressView().controlSize(.small))
    }
}

/// A markdown heading whose point size follows the person's text size step
/// (Settings): the level's size at the phone's setting, times the step's factor.
private struct HeadingText: View {
    let text: AttributedString
    let size: (CGFloat, Font.Weight)
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Text(text).font(.system(size: size.0 * TypeScale.factor(for: typeSize), weight: size.1))
    }
}
