import XCTest
@testable import Pervio

/// The phone-local "pin a conversation to the top" preference (`PinStore`), used
/// by BOTH conversation lists — the home "Recent" block and a project's history.
/// A pin is a habit of THIS phone, not server data, so it lives in UserDefaults
/// and never opens a socket. These tests pin the four properties the feature
/// rests on:
///   * a pin floats its row above the time-sorted rest, most-recently pinned first;
///   * un-pinning drops the row back into plain modified-time order;
///   * the SAME session pinned once is pinned in both lists (one shared key);
///   * the storage key can't collide with another feature's key, or with a
///     DIFFERENT conversation's (a dir that abuts a session id must not merge).
///
/// Every case runs against an ISOLATED UserDefaults suite (a fresh, uniquely
/// named domain per test, torn down after) so not one of them can read or write
/// the real app's `pervio.*` domain — the same discipline PushTokenUploadTests
/// uses for its "last uploaded token" memo.
@MainActor
final class HomePinTests: XCTestCase {

    /// A throwaway UserDefaults domain, wiped on the way out so a pin written by
    /// one test can never leak into another (or into the real app).
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "pervio.pintest.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func store() -> PinStore { PinStore(defaults: defaults) }

    // MARK: - Fixtures

    /// One profile id reused across a list so the key varies only by (dir, session).
    private let profileId = UUID()

    private func session(_ id: String, modified: Int) -> SessionSummary {
        SessionSummary(id: id, preview: id, modified: modified, bytes: 0, backend: .claude)
    }

    /// The item shape both lists carry: a (dir, session) pair. The home list uses
    /// `HomeRecentModel.Item`; a project list is just its `dir` + each session.
    private struct Row { let dir: String; let session: SessionSummary }
    private func key(_ r: Row) -> String {
        PinStore.key(profileId: profileId, dir: r.dir, sessionId: r.session.id)
    }

    // MARK: - Sort: pinned floats to the top, most-recent pin first

    /// Three sessions, newest-modified first (the order both lists hand in). Pin
    /// the OLDEST, and it must jump to the front; the other two keep their time
    /// order behind it.
    func testPinFloatsRowToTop_restKeepsTimeOrder() {
        let s = store()
        let rows = [
            Row(dir: "/p", session: session("a", modified: 300)),   // newest
            Row(dir: "/p", session: session("b", modified: 200)),
            Row(dir: "/p", session: session("c", modified: 100)),   // oldest
        ]
        // Precondition (RED anchor): with nothing pinned, the helper is identity.
        XCTAssertEqual(s.sortedPinnedFirst(rows, keyFor: key).map { $0.session.id },
                       ["a", "b", "c"], "unpinned order must be the input (time) order")

        s.togglePin(key(rows[2]))    // pin "c", the oldest
        XCTAssertEqual(s.sortedPinnedFirst(rows, keyFor: key).map { $0.session.id },
                       ["c", "a", "b"],
                       "the pinned row leads; the unpinned rest keeps newest-first order")
    }

    /// Two pins: the one pinned LATER sits above the one pinned earlier, even
    /// though its modified time is older — "most-recently pinned first".
    func testMultiplePins_orderByPinTimeDescending() {
        let s = store()
        let rows = [
            Row(dir: "/p", session: session("a", modified: 300)),
            Row(dir: "/p", session: session("b", modified: 200)),
            Row(dir: "/p", session: session("c", modified: 100)),
        ]
        // Pin "a" first, then "c" a second later → "c" is the more recent pin.
        s.togglePin(key(rows[0]), now: Date(timeIntervalSince1970: 1000))
        s.togglePin(key(rows[2]), now: Date(timeIntervalSince1970: 1001))

        XCTAssertEqual(s.sortedPinnedFirst(rows, keyFor: key).map { $0.session.id },
                       ["c", "a", "b"],
                       "later pin ('c') tops earlier pin ('a'); the unpinned 'b' trails")
    }

    // MARK: - Unpin restores plain time order

    func testUnpinRestoresTimeOrder() {
        let s = store()
        let rows = [
            Row(dir: "/p", session: session("a", modified: 300)),
            Row(dir: "/p", session: session("b", modified: 200)),
            Row(dir: "/p", session: session("c", modified: 100)),
        ]
        let ck = key(rows[2])
        s.togglePin(ck)
        XCTAssertEqual(s.sortedPinnedFirst(rows, keyFor: key).first?.session.id, "c",
                       "precondition: 'c' is pinned to the top")

        s.togglePin(ck)     // toggle again = unpin
        XCTAssertFalse(s.isPinned(ck), "toggling a pinned key must unpin it")
        XCTAssertEqual(s.sortedPinnedFirst(rows, keyFor: key).map { $0.session.id },
                       ["a", "b", "c"], "unpinning falls back to the modified-time order")
    }

    // MARK: - One shared state across BOTH lists

    /// The home list and the project list build the key from the SAME triple, so a
    /// session pinned in one is pinned in the other. Proven by pinning through the
    /// home-list item and reading through the project-list item for the same
    /// (profile, dir, session).
    func testSameConversationSharesPinAcrossLists() {
        let s = store()
        let dir = "/home/you/proj"
        let sess = session("sess-42", modified: 500)

        // Home list stores its rows as HomeRecentModel.Item — build ITS key the
        // way HomeRecentRows does.
        let homeItem = HomeRecentModel.Item(dir: dir, session: sess)
        let homeKey = PinStore.key(profileId: profileId, dir: homeItem.dir,
                                   sessionId: homeItem.session.id)
        // Project list has a bare (dir, session) — build the key the way
        // SessionsView does.
        let projectKey = PinStore.key(profileId: profileId, dir: dir, sessionId: sess.id)

        XCTAssertEqual(homeKey, projectKey,
                       "both lists must derive the identical key for one conversation")

        s.togglePin(homeKey)                       // pin from the home list…
        XCTAssertTrue(s.isPinned(projectKey),      // …seen pinned from the project list
                      "a pin made in one list must show in the other (shared key)")
    }

    // MARK: - Key uniqueness: no collision with other conversations or features

    /// A dir that ABUTS the next field's value must not merge into another
    /// conversation's key. With a naive "dir + sessionId" concatenation,
    /// ("/a", "bc") and ("/ab", "c") both spell "/abc"; the U+0001 separator keeps
    /// them distinct.
    func testKeyDoesNotCollideAcrossDirSessionBoundary() {
        let k1 = PinStore.key(profileId: profileId, dir: "/a", sessionId: "bc")
        let k2 = PinStore.key(profileId: profileId, dir: "/ab", sessionId: "c")
        XCTAssertNotEqual(k1, k2,
                          "the dir/session boundary must be unambiguous: \(k1) vs \(k2)")
    }

    /// Different profiles, same dir + session → different keys (the pin is scoped
    /// to the server profile, as the key format promises).
    func testKeyIsScopedToProfile() {
        let a = PinStore.key(profileId: UUID(), dir: "/p", sessionId: "s")
        let b = PinStore.key(profileId: UUID(), dir: "/p", sessionId: "s")
        XCTAssertNotEqual(a, b, "the same session under two profiles must not share a pin")
    }

    /// The store writes ONLY under its own `pervio.pin*` namespace — the cache,
    /// the outbox and the migration marks (three keys since the 2026-09-08 ledger
    /// sync) — and none of them is a key another feature already owns (profiles,
    /// sessionParams, homeProfileId, the language switch, the push-token memo).
    /// A raw scan of the isolated domain after a pin proves both that the writes
    /// happened and that every key is ours.
    func testStorageKeyIsUniqueAndDoesNotClashWithOtherFeatures() {
        let s = store()
        s.togglePin(PinStore.key(profileId: profileId, dir: "/p", sessionId: "s"))

        let keysWritten = Set(defaults.persistentDomain(forName: suiteName)?.keys ?? Dictionary<String, Any>().keys)
        // Exactly the pin store's own keys are present in its isolated domain…
        XCTAssertEqual(keysWritten,
                       ["pervio.pinnedSessions.v1", "pervio.pinOps.v1", "pervio.pinMigrated.v1"],
                       "the pin store must write only its three namespaced keys, got: \(keysWritten)")
        // …and it is none of the keys other features are known to use.
        let foreignKeys: Set<String> = [
            "pervio.profiles.v1", "pervio.sessionParams.v1", "pervio.homeProfileId.v1",
            "pervio.promptLanguage",
        ]
        XCTAssertTrue(keysWritten.isDisjoint(with: foreignKeys),
                      "the pin key collides with another feature's key: \(keysWritten)")
    }

    // MARK: - Persistence: a pin survives a relaunch (same domain, new instance)

    func testPinSurvivesReload() {
        let k = PinStore.key(profileId: profileId, dir: "/p", sessionId: "s")
        store().togglePin(k)

        // A brand-new PinStore on the SAME domain (as on the next launch) must see
        // the pin — it loads from UserDefaults in init.
        XCTAssertTrue(PinStore(defaults: defaults).isPinned(k),
                      "a pin must persist across store instances (relaunch)")
    }

    // MARK: - Home block composition: pins ALWAYS make the page

    /// `HomeRecentRows.visibleRows` — the rule that fixes "I pinned it and it
    /// vanished from home anyway": pinning used to reorder only within the
    /// newest rows, so a pin older than the block did nothing exactly where
    /// pinning was supposed to matter. Pins (≤3) lead, the newest unpinned
    /// rows follow — ten of them since the block became the default folder's
    /// own chats (2026-10-17) — and with no pins the block is just the newest.
    private func homeItems(_ ids: [String]) -> [HomeRecentModel.Item] {
        // Newest-first, the order the model hands the view.
        ids.enumerated().map { i, id in
            HomeRecentModel.Item(dir: "~/P", session: session(id, modified: 1_000 - i))
        }
    }
    private func rows(_ items: [HomeRecentModel.Item],
                      pinned: Set<String>) -> [String] {
        HomeRecentRows.visibleRows(items,
                                   pinnedFirst: { $0 },   // pin-recency order is PinStore's, tested above
                                   isPinned: { pinned.contains($0.session.id) })
            .map(\.session.id)
    }

    @MainActor
    func testHomeRows_noPins_isTheNewestTen() {
        let items = homeItems(["a", "b", "c", "d", "e"])
        XCTAssertEqual(rows(items, pinned: []), ["a", "b", "c", "d", "e"], "fewer than ten: all of them")
        let many = homeItems((0..<14).map { "s\($0)" })
        XCTAssertEqual(rows(many, pinned: []), (0..<10).map { "s\($0)" }, "more than ten: the newest ten")
    }

    @MainActor
    func testHomeRows_anOldPinSurfaces_andTheNewestStay() {
        // "l" is the twelfth-newest — past the block, it reaches home only pinned.
        let items = homeItems(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"])
        XCTAssertEqual(rows(items, pinned: ["l"]), ["l", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j"],
                       "the pin leads; the newest ten are still below it")
    }

    @MainActor
    func testHomeRows_capsAtThreePinsPlusTheNewest() {
        let items = homeItems(["a", "b", "c", "d", "e", "f", "g", "h"])
        let visible = rows(items, pinned: ["d", "e", "f", "g"])
        XCTAssertEqual(visible.count, 7, "a pin spree must not take the whole page: three pins, then the rest")
        XCTAssertEqual(Array(visible.suffix(4)), ["a", "b", "c", "h"],
                       "the newest unpinned rows always close the block")
        XCTAssertTrue(visible.prefix(3).allSatisfy { ["d", "e", "f", "g"].contains($0) })
    }

    @MainActor
    func testHomeRows_aPinnedNewestRowIsNotShownTwice() {
        let items = homeItems(["a", "b", "c", "d"])
        XCTAssertEqual(rows(items, pinned: ["a"]), ["a", "b", "c", "d"],
                       "a pinned newest row leads and is excluded from the recents tail")
    }

    // MARK: - Ledger sync (2026-09-08): outbox, migration, the Mac's truth

    private func summary(_ id: String, pinned: Bool?, at: Int? = nil) -> SessionSummary {
        SessionSummary(id: id, preview: "p", modified: 1, bytes: 1, backend: nil,
                       pinned: pinned, pinnedAt: at)
    }

    func testToggleRecordsAnOutboxOpAndFlushPlanCarriesIt() {
        let store = PinStore(defaults: defaults)
        let pid = UUID()
        let key = PinStore.key(profileId: pid, dir: "/d", sessionId: "s1")
        store.togglePin(key, now: Date(timeIntervalSince1970: 100))
        let plan = store.flushPlan(profileId: pid, dir: "/d")
        XCTAssertEqual(plan.merge, ["s1": 100])
        XCTAssertTrue(plan.unpins.isEmpty)
        store.togglePin(key)
        let again = store.flushPlan(profileId: pid, dir: "/d")
        XCTAssertEqual(again.unpins, ["s1"])
        XCTAssertTrue(again.merge.isEmpty, "the latest op per conversation wins")
        XCTAssertTrue(store.flushPlan(profileId: UUID(), dir: "/d").isEmpty,
                      "another profile's scope hears nothing")
    }

    func testPreLedgerPinsMigrateOnFirstFlushAndAStaleServerCannotEraseThemFirst() {
        let pid = UUID()
        let key = PinStore.key(profileId: pid, dir: "/d", sessionId: "old")
        // A pin made by the phone-only PinStore of old: in storage, no outbox op.
        defaults.set(try! JSONEncoder().encode([key: 50.0]), forKey: "pervio.pinnedSessions.v1")
        let store = PinStore(defaults: defaults)
        XCTAssertTrue(store.isPinned(key))
        store.absorb([summary("old", pinned: false)], profileId: pid, dir: "/d")
        XCTAssertTrue(store.isPinned(key), "before migration a Mac that never heard of it must not win")
        XCTAssertEqual(store.flushPlan(profileId: pid, dir: "/d").merge, ["old": 50], "…and it gets uploaded")
        store.markFlushed(profileId: pid, dir: "/d")
        store.absorb([summary("old", pinned: false)], profileId: pid, dir: "/d")
        XCTAssertFalse(store.isPinned(key), "after migration the ledger is the truth")
    }

    func testTheMacsFlagsOverwriteTheCacheExceptForTapsStillInFlight() {
        let pid = UUID()
        let store = PinStore(defaults: defaults)
        store.markFlushed(profileId: pid, dir: "/d")
        let ka = PinStore.key(profileId: pid, dir: "/d", sessionId: "a")
        let kb = PinStore.key(profileId: pid, dir: "/d", sessionId: "b")
        store.absorb([summary("a", pinned: true, at: 777), summary("b", pinned: false)],
                     profileId: pid, dir: "/d")
        XCTAssertEqual(store.pinnedAt(ka), 777)
        XCTAssertFalse(store.isPinned(kb))
        store.togglePin(kb)                                        // a tap not yet replayed
        store.absorb([summary("b", pinned: false)], profileId: pid, dir: "/d")
        XCTAssertTrue(store.isPinned(kb), "an unflushed tap outranks a stale server flag")
        store.absorb([summary("a", pinned: nil)], profileId: pid, dir: "/d")
        XCTAssertEqual(store.pinnedAt(ka), 777, "an older server's unstamped row changes nothing")
    }

    func testOutboxSurvivesRelaunch() {
        let pid = UUID()
        let key = PinStore.key(profileId: pid, dir: "/d", sessionId: "s")
        PinStore(defaults: defaults).togglePin(key, now: Date(timeIntervalSince1970: 9))
        let reborn = PinStore(defaults: defaults)
        XCTAssertEqual(reborn.flushPlan(profileId: pid, dir: "/d").merge, ["s": 9],
                       "a tap made offline must still reach the Mac after a relaunch")
    }

    func testSessionSummaryDecodesPinFlagsTolerantly() throws {
        let json = #"[{"id":"x","preview":"p","modified":1,"bytes":2,"pinned":true,"pinnedAt":42},{"id":"y","preview":"p","modified":1,"bytes":2}]"#
        let rows = try JSONDecoder().decode([SessionSummary].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].pinned, true)
        XCTAssertEqual(rows[0].pinnedAt, 42)
        XCTAssertNil(rows[1].pinned, "an older server sends no flag → nil, never false")
    }
}

