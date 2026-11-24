import XCTest
@testable import Pervio

/// A page that shows what the Mac says reads it again by itself after a read
/// that could not reach it (2026-11-22, the person: "主页如果连接不上…每次都是
/// 退出app重新进去才能好"). It used to read once and stay on whatever that one
/// read said. The rules are the same on every such page (PageRefresher): a
/// failed read is the one signal — no network watching, no retry key — and
/// the waits are 2, 4, 8, 15, then 30 seconds for as long as the page is shown.
@MainActor
final class PageRefresherTests: XCTestCase {

    private static let noAnswer = PageRefresher.Outcome.unreachable("no answer")

    /// A Mac that answers what the script says, read after read.
    private final class Mac {
        var answers: [PageRefresher.Outcome]
        var then: PageRefresher.Outcome
        private(set) var reads = 0
        /// Reads that never answer (a socket the network dropped without a word).
        var hangFirst = 0
        /// Reads that answer late (seconds), by their number.
        var slow: [Int: Double] = [:]
        init(_ answers: [PageRefresher.Outcome], then: PageRefresher.Outcome = .reached) {
            self.answers = answers; self.then = then
        }
        func read() async -> PageRefresher.Outcome {
            reads += 1
            let n = reads
            let answer = answers.isEmpty ? then : answers.removeFirst()
            if n <= hangFirst {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                return PageRefresherTests.noAnswer
            }
            if let wait = slow[n] { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            return answer
        }
    }

    private func refresher(delays: [TimeInterval] = [0.05, 0.05, 0.05]) -> PageRefresher {
        let r = PageRefresher()
        r.delays = delays
        r.patience = 0.4
        r.resume()                      // the page is on screen
        return r
    }
    private func settle(_ seconds: Double = 2, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testAReadThatCannotReachTheMacIsTriedAgainUntilItDoes() async {
        let mac = Mac([Self.noAnswer, Self.noAnswer, Self.noAnswer])
        let r = refresher()
        r.refresh { await mac.read() }
        await settle { r.retrying }
        XCTAssertTrue(r.retrying, "after a miss the page says it is trying again")
        XCTAssertEqual(r.problem, Self.noAnswer, "…and why, in the read's own words")
        await settle { mac.reads == 4 && !r.retrying }
        XCTAssertEqual(mac.reads, 4, "three misses, then the read that reached it — nobody quit the app")
        XCTAssertFalse(r.retrying)
        XCTAssertNil(r.problem, "the line goes the moment a read gets through")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(mac.reads, 4, "…and once it has answered, nothing keeps asking")
    }

    func testAReadTheMacRefusedIsNotRepeated() async {
        let no = PageRefresher.Outcome.refused("the key was rejected")
        let mac = Mac([no], then: no)
        let r = refresher()
        r.refresh { await mac.read() }
        await settle(0.5) { mac.reads > 1 }
        XCTAssertEqual(mac.reads, 1, "a rejected key is not cured by waiting — and sent again and again it gets an address banned")
        XCTAssertFalse(r.retrying)
        XCTAssertEqual(r.problem, no, "the page says what was refused")
        r.pause(); r.resume()            // away and back: still not a reason to send it again by itself
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mac.reads, 1)
    }

    func testTheWaitsGrowAndTheLastOneRepeatsForAsLongAsThePageIsShown() async {
        let mac = Mac([], then: Self.noAnswer)
        let r = refresher(delays: [0.1, 0.3])
        var times: [Date] = []
        r.refresh { times.append(Date()); return await mac.read() }
        await settle(4) { times.count >= 6 }
        r.pause()
        guard times.count >= 6 else {
            return XCTFail("it gave up by itself after \(times.count) reads: the Mac may be back in an hour")
        }
        let gaps = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }
        XCTAssertEqual(gaps[0], 0.1, accuracy: 0.09)
        for later in gaps[1..<5] { XCTAssertEqual(later, 0.3, accuracy: 0.12, "past the list, the last wait is the one kept") }
    }

    func testEveryFreshReadStartsTheWaitsOver() async {
        // Reached, then lost again: the second losing is waited out from the
        // shortest wait, not from where the first one had got to.
        let mac = Mac([Self.noAnswer, Self.noAnswer, .reached, Self.noAnswer, .reached])
        let r = refresher(delays: [0.05, 2])
        r.refresh { await mac.read() }
        await settle(4) { mac.reads == 3 && r.problem == nil && !r.retrying }
        XCTAssertEqual(mac.reads, 3)
        let again = Date()
        r.refresh()                      // the page is read anew (pulled, come back to)
        await settle(1.5) { mac.reads == 5 && r.problem == nil }
        XCTAssertEqual(mac.reads, 5)
        XCTAssertLessThan(Date().timeIntervalSince(again), 1.2, "its first retry came after the first wait, not the two-second one")
    }

    func testNothingRetriesBehindAnotherPageAndTheWayBackTriesAtOnce() async {
        let mac = Mac([Self.noAnswer, Self.noAnswer])
        let r = refresher(delays: [0.05])
        r.refresh { await mac.read() }
        await settle { r.retrying }
        r.pause()                         // a chat was opened, or the app left
        let reads = mac.reads
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(mac.reads, reads, "no retries while the page is not shown")
        r.resume()
        await settle { !r.retrying && r.problem == nil }
        XCTAssertNil(r.problem, "back on the page, it reads again without being asked")
        XCTAssertGreaterThan(mac.reads, reads)
    }

    /// A read that never answers must not hang the page with it: it counts as
    /// a miss when patience runs out, and the next read goes out.
    func testAReadThatHangsIsLeftBehind() async {
        let mac = Mac([])
        mac.hangFirst = 1
        let r = refresher(delays: [0.05])
        r.refresh { await mac.read() }
        await settle(3) { mac.reads == 2 && r.problem == nil && !r.retrying }
        XCTAssertEqual(mac.reads, 2)
        XCTAssertNil(r.problem)
        XCTAssertFalse(r.retrying)
    }

    /// …and one that was only slow, and gets through after patience ran out,
    /// is believed: the line goes, and the retry that was waiting is not sent.
    func testAReadThatWasOnlySlowStillCounts() async {
        let mac = Mac([.reached])
        mac.slow[1] = 0.7                // patience is 0.4
        let r = refresher(delays: [0.8])  // so the retry is due at 1.2 s
        r.refresh { await mac.read() }
        await settle { r.retrying }
        XCTAssertTrue(r.retrying, "patience ran out: it says it cannot reach the Mac")
        await settle(2) { r.problem == nil && !r.retrying }
        XCTAssertNil(r.problem)
        XCTAssertFalse(r.retrying)
        try? await Task.sleep(nanoseconds: 1_000_000_000)      // well past when that retry was due
        XCTAssertEqual(mac.reads, 1, "the Mac had answered: the retry that was waiting is not sent")
    }

    /// The other way round: a read given up on, whose "no answer" comes in
    /// after the retry has already got through, says nothing about the Mac now.
    func testALateMissDoesNotOverwriteTheReadThatGotThrough() async {
        let mac = Mac([Self.noAnswer, .reached])
        mac.slow[1] = 0.8                // patience is 0.4: the retry goes out at 0.45 and reaches the Mac
        let r = refresher(delays: [0.05])
        r.refresh { await mac.read() }
        await settle(2) { mac.reads == 2 && r.problem == nil && !r.retrying }
        XCTAssertEqual(mac.reads, 2)
        try? await Task.sleep(nanoseconds: 800_000_000)        // the first read's miss has come in by now
        XCTAssertNil(r.problem, "the newest read reached the Mac: an older one's miss is not the page's")
        XCTAssertFalse(r.retrying)
        XCTAssertEqual(mac.reads, 2, "…and starts no retrying")
    }

    func testAPullWaitsForItsReadAndItsMissIsFollowedUpLikeAnyOther() async {
        let mac = Mac([.reached, Self.noAnswer])
        let r = refresher(delays: [30])
        r.refresh { await mac.read() }
        await settle { mac.reads == 1 }
        await r.refreshAndWait()
        XCTAssertEqual(mac.reads, 2, "the pull read the Mac")
        XCTAssertEqual(r.problem, Self.noAnswer)
        XCTAssertTrue(r.retrying)
        r.pause()
    }

    // MARK: - What an error says about trying again

    func testOnlyAFailureToReachIsWorthAnotherTry() {
        func conn(_ kind: SSHService.ConnectionError.Kind) -> Error { SSHService.ConnectionError(message: "its own words", kind: kind) }
        for kind: SSHService.ConnectionError.Kind in [.authRejected, .hostKeyMismatch, .noPin, .unusablePin, .badPrivateKey, .missingSecret] {
            XCTAssertEqual(PageRefresher.Outcome.of(conn(kind), "generic"), .refused("its own words"), "\(kind)")
            XCTAssertFalse(RunMonitor.keepsPolling(after: conn(kind)), "the standing poll stops there too: \(kind)")
        }
        for kind: SSHService.ConnectionError.Kind in [.portClosed, .hostNotFound, .other] {
            XCTAssertEqual(PageRefresher.Outcome.of(conn(kind), "generic"), .unreachable("its own words"), "\(kind)")
            XCTAssertTrue(RunMonitor.keepsPolling(after: conn(kind)), "\(kind)")
        }
        XCTAssertEqual(PageRefresher.Outcome.of(NSError(domain: NSPOSIXErrorDomain, code: 60), "Couldn't load projects."),
                       .unreachable("Couldn't load projects."), "an error with no words of its own is said in the page's")
        XCTAssertTrue(RunMonitor.keepsPolling(after: NSError(domain: NSPOSIXErrorDomain, code: 60)))
        let (u, f) = (PageRefresher.Outcome.unreachable("u"), PageRefresher.Outcome.refused("f"))
        XCTAssertEqual(PageRefresher.Outcome.worst(.reached, u), u)
        XCTAssertEqual(PageRefresher.Outcome.worst(f, .reached), f)
        XCTAssertEqual(PageRefresher.Outcome.worst(f, u), u, "one block out of reach: the page keeps trying")
        XCTAssertEqual(PageRefresher.Outcome.worst(.reached, .reached), .reached)
    }

    /// A slow failure that finally gives up must not write over the answer of
    /// the retry that already succeeded.
    func testOnlyTheNewestReadsAnswerIsThePages() {
        var ticket = LoadTicket()
        let slow = ticket.take()
        XCTAssertTrue(ticket.isLatest(slow))
        let retry = ticket.take()
        XCTAssertFalse(ticket.isLatest(slow), "the first read was overtaken")
        XCTAssertTrue(ticket.isLatest(retry))
    }
}
