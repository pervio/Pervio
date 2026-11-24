import XCTest
@testable import Pervio

/// The black-bottom bug (2026-08-28): a dropped SSH channel returns a clean
/// prefix of the figure's base64, the prefix decodes, UIImage renders the top
/// rows — and an unvalidated cache then serves the half-figure forever. These
/// pin the format-tail referee that keeps a stump out of the cache.
final class FigureIntegrityTests: XCTestCase {

    private func png(complete: Bool) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        d.append(Data(repeating: 0x41, count: 100))
        if complete {
            d.append(Data([0x00, 0x00, 0x00, 0x00]))
            d.append("IEND".data(using: .ascii)!)
            d.append(Data([0xAE, 0x42, 0x60, 0x82]))
        }
        return d
    }

    private func jpeg(complete: Bool) -> Data {
        var d = Data([0xFF, 0xD8, 0xFF, 0xE0])
        d.append(Data(repeating: 0x42, count: 100))
        if complete { d.append(Data([0xFF, 0xD9])) }
        return d
    }

    func testWholeFilesPass() {
        XCTAssertTrue(FigureStore.looksComplete(png(complete: true)))
        XCTAssertTrue(FigureStore.looksComplete(jpeg(complete: true)))
    }

    func testTruncatedFilesAreRejected() {
        XCTAssertFalse(FigureStore.looksComplete(png(complete: false)))
        XCTAssertFalse(FigureStore.looksComplete(jpeg(complete: false)))
        // A prefix of a whole file is exactly what a dropped channel produces.
        XCTAssertFalse(FigureStore.looksComplete(jpeg(complete: true).prefix(70)))
    }

    func testTinyOrEmptyBlobsAreRejected() {
        XCTAssertFalse(FigureStore.looksComplete(Data()))
        XCTAssertFalse(FigureStore.looksComplete(Data([0xFF, 0xD8, 0xFF, 0xD9])))
    }

    func testUnknownFormatsPassThrough() {
        // gif/webp carry no cheap tail marker; the transfer-layer byte receipt
        // is their referee. looksComplete must not veto what it can't judge.
        var gif = "GIF89a".data(using: .ascii)!
        gif.append(Data(repeating: 0x00, count: 100))
        XCTAssertTrue(FigureStore.looksComplete(gif))
    }
}
