import XCTest
@testable import Pervio

/// The flip-back spinner (2026-08-30): every issue flip re-fetched over SSH and
/// showed a blank page with a wheel. These pin the cure — a per-issue cache that
/// paints instantly on a flip back, plus a SILENT background revalidation so a
/// re-published today's issue still lands without ever showing the spinner.
@MainActor
final class ArchiveReaderCacheTests: XCTestCase {

    private func makeStore() -> ArchiveReaderStore {
        ArchiveReaderStore(profile: TestFactory.profile(), secret: "s")
    }

    func testFlipBackPaintsFromCacheInstantly() async {
        let store = makeStore()
        var calls = 0
        var gate: CheckedContinuation<String, Never>?
        store.archiveReadOverride = { _, file in
            calls += 1
            if calls <= 2 { return file == "a.md" ? "甲刊" : "乙刊" }
            // Third call = the revalidation behind a cache hit; hold it open so
            // the test can prove the cached paint happened BEFORE it resolved.
            return await withCheckedContinuation { gate = $0 }
        }

        await store.read(dir: "~/x", file: "a.md")
        XCTAssertEqual(store.content, "甲刊")
        await store.read(dir: "~/x", file: "b.md")
        XCTAssertEqual(store.content, "乙刊")
        XCTAssertEqual(calls, 2)

        // Flip back to a.md: cached text must be on screen while the
        // revalidation round trip is still parked on the gate.
        let flip = Task { await store.read(dir: "~/x", file: "a.md") }
        for _ in 0..<200 where gate == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(store.content, "甲刊", "cache hit must paint before the network answers")
        XCTAssertFalse(store.loading, "a cache hit must never show the spinner")
        XCTAssertEqual(calls, 3, "a hit still revalidates in the background")

        // The silent refresh repaints only because the bytes changed.
        gate?.resume(returning: "甲刊 · 补跑后重发")
        await flip.value
        XCTAssertEqual(store.content, "甲刊 · 补跑后重发")
    }

    func testUnchangedRevalidationDoesNotChurnContent() async {
        let store = makeStore()
        var calls = 0
        store.archiveReadOverride = { _, _ in calls += 1; return "同一份" }
        await store.read(dir: "~/x", file: "a.md")
        await store.read(dir: "~/x", file: "a.md")
        XCTAssertEqual(store.content, "同一份")
        XCTAssertEqual(calls, 2, "hit path revalidates once, and identical bytes repaint nothing")
        XCTAssertFalse(store.loading)
    }

    func testRevalidationFailureKeepsTheCachedIssue() async {
        let store = makeStore()
        var calls = 0
        store.archiveReadOverride = { _, _ in
            calls += 1
            if calls == 1 { return "第一版" }
            throw SSHService.ConnectionError(message: "tunnel dropped")
        }
        await store.read(dir: "~/x", file: "a.md")
        await store.read(dir: "~/x", file: "a.md")
        XCTAssertEqual(store.content, "第一版", "a dead revalidation must not blank a cached issue")
        XCTAssertNil(store.errorText)
    }
}
