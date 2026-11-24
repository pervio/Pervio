import XCTest
import NIOCore
@testable import Pervio

/// R11: the agent's NDJSON comes back in SSH chunks whose boundaries fall
/// wherever the network put them — including in the MIDDLE of a UTF-8
/// character. `LineAssembler` is the one place those chunks are put back
/// together, so it is the one place that has to survive it.
///
/// Chunks are fed as the real `ByteBuffer`s Citadel hands over (not a
/// test-only entry point), and what comes out is parsed by the real
/// `AgentEvent.parse` — the test asserts what the USER would have seen in the
/// bubble, not an internal detail.
final class StreamChunkingTests: XCTestCase {

    /// One line of a real `pervio-chat` stream: a Chinese text delta. Every
    /// character here is 3 bytes, so almost every byte offset in it is a
    /// boundary that lands inside a character.
    private let deltaLine = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"预算 200 元"}}}"#
    private let deltaText = "预算 200 元"

    /// Feed `text` as two chunks split after byte `n` — one arbitrary network
    /// boundary — and return every line the assembler produced.
    private func lines(_ text: String, splitAfter n: Int) -> [String] {
        var asm = LineAssembler()
        let bytes = Array(text.utf8)
        var out = asm.feed(ByteBuffer(bytes: bytes[0..<n]))
        out += asm.feed(ByteBuffer(bytes: bytes[n...]))
        out += asm.flush()
        return out
    }

    private func textDeltas(_ lines: [String]) -> [String] {
        lines.flatMap { AgentEvent.parse(line: $0) }.compactMap {
            if case .textDelta(let t) = $0 { return t } else { return nil }
        }
    }

    /// The defect itself: a boundary inside a character loses that character's
    /// bytes for good (each half decodes on its own into U+FFFD), so the text
    /// the user reads is not the text the model sent.
    func testR11_multibyteCharacterSplitByAChunkBoundaryArrivesIntact() {
        let wire = deltaLine + "\n"
        let byteCount = Array(wire.utf8).count

        var corrupted: [Int] = []
        for cut in 1..<byteCount where lines(wire, splitAfter: cut) != [deltaLine] {
            corrupted.append(cut)
        }
        XCTAssertEqual(corrupted, [],
                       "chunk boundaries at these byte offsets did not reassemble into the "
                       + "line that was sent — e.g. offset \(corrupted.first ?? -1) produced "
                       + "\(lines(wire, splitAfter: corrupted.first ?? 1))")

        // And the consequence the user sees, through the real event parser: the
        // line still parses as JSON (U+FFFD is legal inside a JSON string), so
        // nothing errors — the reply just silently says something else.
        let midCharacter = Array(wire.utf8).firstIndex(where: { $0 >= 0xC0 }).map { $0 + 1 } ?? 1
        let got = textDeltas(lines(wire, splitAfter: midCharacter))
        XCTAssertEqual(got, [deltaText],
                       "a chunk boundary inside a character silently rewrote the assistant's "
                       + "text: \(got)")
    }

    /// A second line arriving in the same chunk as the tail of the first (the
    /// common case on a fast link) must still come out as two whole lines.
    func testR11_twoLinesInOneChunkBoundarySplitStillArriveWhole() {
        let wire = deltaLine + "\n" + deltaLine + "\n"
        let byteCount = Array(wire.utf8).count
        var wrong: [Int] = []
        for cut in 1..<byteCount where lines(wire, splitAfter: cut) != [deltaLine, deltaLine] {
            wrong.append(cut)
        }
        XCTAssertEqual(wrong, [], "boundaries that lost or merged a line: \(wrong.prefix(8))")
    }

    /// The same root cause with a worse ending: scanning for a newline in a
    /// Swift `String` searches CHARACTERS, and "\r\n" is a single character —
    /// so on a server whose stream is CRLF-terminated the search never matched
    /// and not one line was ever emitted. The whole conversation piled up in the
    /// buffer and came out of `flush()` as one blob at the end: nothing streams
    /// live, and the blob is several JSON objects glued together, which parses
    /// as none of them. That is the silent drop.
    func testR11_crlfTerminatedLinesAreStillSplitIntoLines() {
        var asm = LineAssembler()
        let emitted = asm.feed(ByteBuffer(string: deltaLine + "\r\n" + deltaLine + "\r\n"))
        XCTAssertEqual(emitted.count, 2,
                       "a CRLF stream produced \(emitted.count) lines while it was arriving; "
                       + "flush() then held \(asm.flush())")
        XCTAssertEqual(textDeltas(emitted), [deltaText, deltaText],
                       "nothing reached the bubble from a CRLF stream")
    }

    /// The guard against over-fixing: everything the assembler already did must
    /// keep working exactly as before — ASCII lines, an empty line, a trailing
    /// partial line held until `flush()`, and nothing invented when there is
    /// nothing to emit.
    func testR11_lineSplittingBehaviourIsOtherwiseUnchanged() {
        var asm = LineAssembler()
        XCTAssertEqual(asm.feed(ByteBuffer(string: "{\"a\":1}\n\n{\"b\":2}\n{\"c\"")),
                       ["{\"a\":1}", "", "{\"b\":2}"])
        XCTAssertEqual(asm.feed(ByteBuffer(string: "")), [], "an empty chunk emits nothing")
        XCTAssertEqual(asm.feed(ByteBuffer(string: ":3}")), [],
                       "a line with no newline yet is held, not emitted")
        XCTAssertEqual(asm.flush(), ["{\"c\":3}"], "flush() releases the trailing partial line")
        XCTAssertEqual(asm.flush(), [], "a second flush has nothing left to give")
    }
}
