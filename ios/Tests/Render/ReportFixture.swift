import Foundation
import XCTest
@testable import Pervio

/// Index that FAILS the test instead of killing the process.
///
/// These suites are run against DELIBERATELY BROKEN copies of the renderer
/// (mutation proofs). A broken parser returns a shorter array, and a plain
/// `xs[0]` then traps: SIGTRAP kills the test host, which is Pervio.app, and
/// macOS puts a "Pervio 意外退出" dialog on the user's screen. A mutant is
/// supposed to turn an assertion red — silently, in the log. Use `try xs.at(i)`
/// anywhere the index depends on what the renderer produced.
extension Array {
    func at(_ i: Int,
            file: StaticString = #filePath, line: UInt = #line) throws -> Element {
        try XCTUnwrap(indices.contains(i) ? self[i] : nil,
                      "index \(i) is out of range — the renderer produced \(count) element(s)",
                      file: file, line: line)
    }
}

/// Loads ios/Tests/Fixtures/reports/* — REAL published issues, copied verbatim
/// out of ~/.pervio/papers/archive and ~/.pervio/github/archive, plus the REAL
/// `actions` spec the 论文晨报 schedule ships and the server-side button-group
/// contract generated from them by
/// ios/Tests/Fixtures/reports/make_actions_contract.py.
///
/// Nothing in this directory is hand-written markdown: these are the bytes the
/// agents actually wrote on those mornings, which is the point — the renderer
/// has to survive what the generators really emit, not what we imagine.
enum ReportFixture {

    private final class BundleToken {}

    /// The real published issues, and what each one is for:
    /// `papers-2026-07-18` is the long one (66 scorable papers),
    /// `papers-2026-08-04` the near-empty "no new papers" one,
    /// `papers-2026-08-06` the fully-shaped one (masthead, quote, folds),
    /// `github-*` the one with bare-link chips and data lines.
    static let realArchives = ["papers-2026-07-18", "papers-2026-08-04",
                               "papers-2026-08-06", "github-2026-08-04"]

    /// A report mirroring the hostile one server/tests/test_view.py renders for
    /// its C group — same adversary on both screens. NOT a real archive.
    static let hostile = "hostile-injection"

    /// Also not an archive: the published issues only ever hang a rating menu
    /// off a heading, a list item or a paragraph, so the phone↔Mac agreement
    /// about a QUOTE or a bare-URL chip line was never exercised by anything.
    /// This issue carries the shipped action in every block kind both
    /// renderers have.
    static let sampler = "kinds-sampler"

    /// Everything the server-side contract covers.
    static let all = realArchives + [hostile, sampler]

    static func markdown(_ name: String,
                         file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "md") else {
            XCTFail("report fixture \(name).md is missing from the test bundle",
                    file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func json(_ name: String,
                             file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("""
                fixture \(name).json is missing from the test bundle — regenerate:
                python3 ios/Tests/Fixtures/reports/make_actions_contract.py
                """, file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    /// The publication's real `actions` (arxiv abs link → 👍/👎/少看/多看).
    static func actions(file: StaticString = #filePath, line: UInt = #line) throws -> [WorkflowAction] {
        try JSONDecoder().decode([WorkflowAction].self, from: json("actions", file: file, line: line))
    }

    // MARK: - the server's half of the contract

    struct Contract: Decodable {
        let actions: [WorkflowAction]
        let compiledActionCount: Int
        let reports: [String: Report]
        /// What the Mac draws for a report whose capture groups can start with
        /// `-` — see ReportActionSafetyTests.
        let argvSafety: ArgvSafety
        /// What the Mac's `_compile_actions` keeps out of a degenerate spec.
        let compileCases: [CompileCase]
        /// A markdown table — a construct only the phone has a block for.
        let tableCase: SyntheticCase
        /// Two adjacent whole-line arxiv URLs — a construct the Mac splits into
        /// two chips and the phone keeps as one paragraph.
        let bareURLRunCase: SyntheticCase

        /// One hand-built report the Mac rendered: what its parser made of it,
        /// and every button group it drew. For the constructs no archived issue
        /// happens to contain, where the two renderers are known to differ.
        struct SyntheticCase: Decodable {
            let markdown: String
            /// The Mac's block kinds for it (`h`/`p`/`chip` — it has no table).
            let blockKinds: [String]
            let buttonGroups: [ButtonGroup]
            let buttonGroupCount: Int
            let rawSpanCount: Int
        }

        struct CompileCase: Decodable {
            let label: String
            let actions: [WorkflowAction]
            /// How many of them survived pervio-view's compile.
            let keptCount: Int
        }

        struct Report: Decodable {
            let buttonGroups: [ButtonGroup]
            let buttonGroupCount: Int
            let rawSpanCount: Int
        }

        struct ArgvSafety: Decodable {
            /// The adversarial report, byte-for-byte as the server rendered it.
            let markdown: String
            /// …with this action spec, not the publication's.
            let actions: [WorkflowAction]
            /// Blocks whose text the server's regex HIT.
            let regexHitCount: Int
            let regexHitGroups: [[String]]
            /// …of which the server actually drew buttons for.
            let buttonGroups: [ButtonGroup]
            let buttonGroupCount: Int
            let rawSpanCount: Int
        }

        struct ButtonGroup: Decodable {
            /// Which action fired (index into `actions`).
            let action: Int
            /// The menu labels pervio-view actually drew as `<button>`s.
            let buttons: [String]
            /// The regex capture groups — the paper id the button will score.
            let groups: [String]
            /// heading | listItem | paragraph | quote — the place on the page.
            let kind: String
            let element: String
            let ownerTextPrefix: String
        }
    }

    static func contract(file: StaticString = #filePath, line: UInt = #line) throws -> Contract {
        try JSONDecoder().decode(Contract.self,
                                 from: json("actions-contract", file: file, line: line))
    }

    // MARK: - the phone's half

    /// The blocks the app parses one issue into, taking the SAME path
    /// `RichMessageText` takes: fenced-code segmentation first, then block
    /// parsing of each prose run.
    static func blocks(_ markdown: String) -> [MarkdownBlock] {
        RichMessageText.parse(markdown).flatMap { segment -> [MarkdownBlock] in
            if case .prose(let s) = segment { return MarkdownBlock.parse(s) }
            return []
        }
    }

    /// One rating menu the phone would draw: where it hangs, which paper it
    /// scores, and the menu it opens.
    struct PhoneHit: Equatable {
        let kind: String
        let groups: [String]
        let menu: [String]
    }

    /// Every rating menu the phone draws for an issue, in document order.
    /// Derived from `MarkdownBlock.actionHits`, the same list the renderer's
    /// `anyActionHit` gate and per-block `ReportActionMenuIcon` read.
    static func phoneHits(_ markdown: String, _ actions: [WorkflowAction],
                          collapseSections: [String] = []) -> [PhoneHit] {
        let compiled = CompiledAction.compile(actions)
        var blocks = blocks(markdown)
        if !collapseSections.isEmpty {
            blocks = MarkdownBlock.collapsed(blocks, sections: collapseSections)
        }
        return MarkdownBlock.actionHits(blocks, compiled).map {
            PhoneHit(kind: $0.target.kind.rawValue, groups: $0.hit.groups,
                     menu: $0.hit.action.menu)
        }
    }
}

// MARK: - test-only block introspection

extension MarkdownBlock {
    /// A short tag per block, so a structure assertion reads as the shape of
    /// the document rather than as a wall of pattern matches.
    var testKind: String {
        switch self {
        case .heading(let l, _): return "h\(l)"
        case .list(let ordered, _, let items): return "\(ordered ? "ol" : "ul")(\(items.count))"
        case .quote:             return "quote"
        case .rule:              return "rule"
        case .paragraph:         return "p"
        case .table(_, let r):   return "table(\(r.count))"
        case .image:             return "img"
        case .details(_, let b): return "details(\(b.count))"
        }
    }

    var testText: String {
        switch self {
        case .heading(_, let t):     return t
        case .list(_, _, let items): return items.joined(separator: "\n")
        case .quote(let t):          return t
        case .rule:                  return ""
        case .paragraph(let t):      return t
        case .table(let h, let r):   return MarkdownBlock.tableText(h, r)
        case .image(let alt, _):     return alt
        case .details(let s, _):     return s
        }
    }

    var testDetailsBlocks: [MarkdownBlock]? {
        if case .details(_, let b) = self { return b }
        return nil
    }
}
