import XCTest
import SwiftTerm
@testable import Pervio

/// tmux asks the outer terminal for its size when a client attaches (CSI 18 t,
/// CSI 14 t); an answer that lands after tmux stopped waiting is forwarded to
/// the shell as keystrokes (";25;52t … command not found", 2026-10-17). Our
/// terminal view answers those queries with nothing; a stock SwiftTerm view
/// answers them — pinned so the difference is real, not assumed.
@MainActor
final class TerminalQueryTests: XCTestCase {
    private final class Sink: NSObject, TerminalViewDelegate {
        var sent: [UInt8] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }

    private func answer(of view: TerminalView, to query: String) -> String {
        let sink = Sink()
        view.terminalDelegate = sink
        view.feed(text: query)
        return String(decoding: sink.sent, as: UTF8.self)
    }

    func testOurViewAnswersSizeQueriesWithNothingAndTheStockViewAnswers() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        let ours = PervioTerminalView(frame: frame, font: TerminalFont.mono(12))
        let stock = TerminalView(frame: frame, font: TerminalFont.mono(12))
        for q in ["\u{1b}[18t", "\u{1b}[14t", "\u{1b}[19t", "\u{1b}[16t"] {
            XCTAssertEqual(answer(of: ours, to: q), "", "ours must stay silent to \(q.dropFirst())")
        }
        XCTAssertTrue(answer(of: stock, to: "\u{1b}[18t").contains("8;"), "the stock view does answer CSI 18 t — the override is what makes the difference")
        // A query that is not about size still gets its answer (cursor position report).
        XCTAssertTrue(answer(of: ours, to: "\u{1b}[6n").contains("R"), "other queries are untouched")
    }
}
