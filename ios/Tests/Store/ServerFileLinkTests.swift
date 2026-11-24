import XCTest
@testable import Pervio

/// A reply that links a file by its Mac path must become a link the phone can
/// open; everything else keeps the existing link rules.
final class ServerFileLinkTests: XCTestCase {

    func testAbsoluteAndHomePathsBecomePervioFileLinks() throws {
        let abs = try XCTUnwrap(ServerFileLink.rewrite(URL(string: "/Users/me/exp/output/comparison.png")!))
        XCTAssertEqual(abs.scheme, ServerFileLink.scheme)
        XCTAssertEqual(ServerFileLink.path(of: abs), "/Users/me/exp/output/comparison.png")

        let home = try XCTUnwrap(ServerFileLink.rewrite(URL(string: "~/notes/plan.pdf")!))
        XCTAssertEqual(ServerFileLink.path(of: home), "~/notes/plan.pdf", "a ~/ path survives the round trip as ~/")
    }

    func testPathsWithSpacesAndCJKRoundTrip() throws {
        // The markdown parser percent-encodes what it must; the path must come back verbatim.
        let encoded = "/Users/me/Documents/Personnel%20pages/%E5%9B%BE%E8%A1%A8.png"
        let url = try XCTUnwrap(ServerFileLink.rewrite(URL(string: encoded)!))
        XCTAssertEqual(ServerFileLink.path(of: url), "/Users/me/Documents/Personnel pages/图表.png")
    }

    func testOtherLinksAreLeftAlone() {
        XCTAssertNil(ServerFileLink.rewrite(URL(string: "https://arxiv.org/abs/2601.00001")!))
        XCTAssertNil(ServerFileLink.rewrite(URL(string: "mailto:a@b.c")!))
        XCTAssertNil(ServerFileLink.rewrite(URL(string: "relative/name.md")!), "a relative name is not a server path")
        XCTAssertNil(ServerFileLink.path(of: URL(string: "https://x.y/z")!))
    }

    @MainActor
    func testInlineMarkdownKeepsTheServerLinkUnderlined() {
        let a = mdInline("先看 [四图对照](/Users/me/out/comparison.png) 和 [官网](https://x.y) 与 [电话](tel://1)")
        var kept: [String] = []
        for run in a.runs {
            if let l = run.link { kept.append(l.scheme ?? "") }
        }
        XCTAssertEqual(kept, [ServerFileLink.scheme, "https"],
                       "the server path stays a link (rewritten), https stays, tel is stripped")
    }
}
