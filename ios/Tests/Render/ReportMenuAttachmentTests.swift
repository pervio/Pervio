import SwiftUI
import XCTest
@testable import Pervio

/// B2, the step between the contract and the screen.
///
/// `ReportActionContractTests` compares `MarkdownBlock.actionHits` — a helper —
/// with the button groups pervio-view really draws. That is only worth
/// something if the helper describes the RENDERER: if `view(actions:onAction:)`
/// ever stopped hanging `ReportActionMenuIcon` off a heading, every count in
/// that file would still match, the contract would still say "agreed", and the
/// 必读 papers would silently lose their 👍 on the phone.
///
/// So this file walks the view values the renderer actually builds and reads
/// back the text handed to each rating menu. `Mirror` cannot enter a `ForEach`
/// content closure, so list rows are built through `MarkdownBlock.listRow` —
/// the `.list` case's only helper — and everything else is taken straight from
/// `view(actions:onAction:report:)`. A `<details>` body is walked block by
/// block, the way `MarkdownDetailsView` renders it when expanded.
final class ReportMenuAttachmentTests: XCTestCase {

    // MARK: - reading the built view tree

    /// The `text` of every `ReportActionMenuIcon` inside a built view value, in
    /// tree order. Depth-capped: SwiftUI view values are deep but finite, and a
    /// runaway walk would be a hang, not a failure.
    private func menuTexts(_ value: Any, depth: Int = 0) -> [String] {
        guard depth < 24 else { return [] }
        if String(describing: type(of: value)).hasPrefix("ReportActionMenuIcon") {
            for child in Mirror(reflecting: value).children where child.label == "text" {
                return [child.value as? String ?? "<icon text is not a String>"]
            }
            return ["<icon with no text property>"]
        }
        return Mirror(reflecting: value).children.flatMap { menuTexts($0.value, depth: depth + 1) }
    }

    /// Every text the RENDERER feeds to a rating menu, in document order —
    /// built the way `ReportProse` builds a report.
    private func renderedMenuTexts(_ blocks: [MarkdownBlock],
                                   _ actions: [CompiledAction]) -> [String] {
        var out: [String] = []
        for block in blocks {
            switch block {
            case .details(_, let inner):
                out += renderedMenuTexts(inner, actions)
            case .list(let ordered, let start, let items):
                for (i, item) in items.enumerated() {
                    out += menuTexts(MarkdownBlock.listRow(
                        marker: ordered ? "\(start + i)." : "•", item: item,
                        actions: actions, onAction: { _ in }))
                }
            default:
                out += menuTexts(block.view(actions: actions, onAction: { _ in }, report: true))
            }
        }
        return out
    }

    /// The walk itself has to be able to see an icon, and to see its absence —
    /// otherwise every assertion below is "found nothing, twice".
    func testTheWalkSeesAnIconAndItsAbsence() throws {
        let actions = CompiledAction.compile(try ReportFixture.actions())
        let hitting = MarkdownBlock.heading(level: 3,
                                            text: "[标题](https://arxiv.org/abs/2608.04788)")
        XCTAssertEqual(menuTexts(hitting.view(actions: actions, onAction: { _ in }, report: true)),
                       ["[标题](https://arxiv.org/abs/2608.04788)"])
        let missing = MarkdownBlock.heading(level: 3, text: "没有链接的标题")
        XCTAssertEqual(menuTexts(missing.view(actions: actions, onAction: { _ in }, report: true)),
                       [], "an unmatched heading must render no menu at all")
        // No handler → no menu anywhere, matched or not (chat's shape).
        XCTAssertEqual(menuTexts(hitting.view(actions: actions, onAction: nil, report: true)), [])
        // A list row always carries the icon (it decides for itself), and it is
        // fed THAT row's text.
        XCTAssertEqual(menuTexts(MarkdownBlock.listRow(marker: "•", item: "一行",
                                                       actions: actions, onAction: { _ in })),
                       ["一行"])
    }

    // MARK: - the renderer and the contract helper describe the same screen

    /// On every frozen issue: the menus the renderer builds, filtered to the
    /// ones that actually match, are exactly the hits the contract file
    /// compares against pervio-view — same texts, same order, same count.
    func testEveryContractHitIsAMenuTheRendererReallyBuilds() throws {
        let actions = CompiledAction.compile(try ReportFixture.actions())
        var total = 0
        for name in ReportFixture.all {
            let blocks = ReportFixture.blocks(try ReportFixture.markdown(name))
            let rendered = renderedMenuTexts(blocks, actions)
            let visible = rendered.filter { CompiledAction.firstHit(in: $0, actions) != nil }
            let contract = MarkdownBlock.actionHits(blocks, actions).map(\.target.text)
            XCTAssertEqual(visible, contract,
                           "\(name): the renderer's menus and actionHits disagree")
            // Nothing is fed to a menu that actionTargets does not know about —
            // the reverse direction, which catches a menu attached to text the
            // contract never accounted for.
            let known = Set(MarkdownBlock.actionTargets(blocks).map(\.text))
            XCTAssertTrue(Set(rendered).isSubset(of: known),
                          "\(name): a menu is fed text no action target claims: "
                          + (rendered.first { !known.contains($0) } ?? ""))
            total += visible.count
        }
        XCTAssertEqual(total, 94, "the renderer built a different number of rating menus "
                       + "than the 94 button groups pervio-view draws")
    }

    /// Per block kind, on the real issues — so "94 agreed" cannot be 94 menus
    /// all hanging off one kind of block while another kind lost its own.
    func testMenusAreBuiltForEveryKindOfBlockTheContractClaims() throws {
        let actions = CompiledAction.compile(try ReportFixture.actions())
        var byKind: [String: Int] = [:]
        for name in ReportFixture.all {
            let blocks = ReportFixture.blocks(try ReportFixture.markdown(name))
            for hit in MarkdownBlock.actionHits(blocks, actions) {
                byKind[hit.target.kind.rawValue, default: 0] += 1
            }
        }
        XCTAssertEqual(byKind, ["heading": 5, "listItem": 82, "paragraph": 6, "quote": 1],
                       "the shape of the frozen issues changed")

        // A heading and a list item both really build a menu — the two kinds
        // the digests use — and so do the kinds no archive happens to use yet.
        let hitting = "[t](https://arxiv.org/abs/2608.04788)"
        XCTAssertEqual(renderedMenuTexts([.heading(level: 3, text: hitting)], actions), [hitting])
        XCTAssertEqual(renderedMenuTexts([.list(ordered: false, start: 1, items: [hitting])],
                                         actions), [hitting])
        XCTAssertEqual(renderedMenuTexts([.quote(hitting)], actions), [hitting])
        XCTAssertEqual(renderedMenuTexts([.paragraph(hitting)], actions), [hitting])
        XCTAssertEqual(renderedMenuTexts([.table(headers: ["a"], rows: [[hitting]])], actions),
                       ["a \(hitting)"])
        XCTAssertEqual(renderedMenuTexts([.details(summary: "s",
                                                   blocks: [.heading(level: 3, text: hitting)])],
                                         actions), [hitting],
                       "a folded paper must still build its menu")
    }

    /// Chat is not a report surface, but it takes the same `view` path with
    /// `report: false`. A menu must attach there identically — the archive
    /// reader and the workflow monitor differ only in typography.
    func testChatTypographyDoesNotChangeWhereAMenuAttaches() throws {
        let actions = CompiledAction.compile(try ReportFixture.actions())
        let blocks = ReportFixture.blocks(try ReportFixture.markdown("papers-2026-08-06"))
        let report = blocks.flatMap {
            menuTexts($0.view(actions: actions, onAction: { _ in }, report: true))
        }
        let chat = blocks.flatMap {
            menuTexts($0.view(actions: actions, onAction: { _ in }, report: false))
        }
        XCTAssertEqual(report, chat)
        XCTAssertFalse(report.isEmpty)
    }
}
