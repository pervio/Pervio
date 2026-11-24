import XCTest
@testable import Pervio

/// R8: the market's pull and a tap on 安装 / 订阅 are two independent round
/// trips over two connections, and the pull is the slow one. When the user taps
/// while the shelves are still loading, the pull comes back holding the server
/// as it was BEFORE the tap — and it used to publish that answer as the truth
/// and wipe the "I just did this" fallbacks on top. The template really is on
/// the server, the schedule really exists, and the market offers to install and
/// subscribe them all over again (a second daily schedule silently double-runs
/// and double-spends).
///
/// Both tests drive the real `WorkflowMarketServerState` and give each operation
/// its OWN `FakeSSH`, exactly like production mints its own one-shot connection
/// per call — the pull's client is held mid-listing while the tap's client runs
/// to completion.
@MainActor
final class MarketRefreshRaceTests: XCTestCase {

    // The zh copy pins in this suite predate the English default flip
    // (2026-09-01): an ABSENT language key used to mean Chinese and now means
    // English. Pin zh explicitly; put the user's real setting back afterwards.
    private var savedLang: Any?
    override func setUp() {
        super.setUp()
        savedLang = UserDefaults.standard.object(forKey: PromptLanguage.defaultsKey)
        UserDefaults.standard.set("zh", forKey: PromptLanguage.defaultsKey)
    }
    override func tearDown() {
        if let savedLang { UserDefaults.standard.set(savedLang, forKey: PromptLanguage.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: PromptLanguage.defaultsKey) }
        super.tearDown()
    }

    /// A real catalog entry, so ids / template filenames / schedule names are
    /// the ones the app actually uses.
    private var capability: WorkflowMarketItem {
        WorkflowMarketItem.featured.first(where: { $0.suggestedTime == nil })!
    }
    /// WF-5 (2026-08-22) removed the embedded digest from `featured` — the
    /// publication ships as a SERVER template now, so the bundled shelf
    /// deliberately stocks none. The race under test only needs SOME
    /// publication item; mint a fixture one. (The old force-unwrap of the
    /// emptied shelf took the whole test host down with a SIGTRAP, which
    /// xcodebuild reported as "test runner hung" — a full day of misdirection.)
    private var publication: WorkflowMarketItem {
        var step = WorkflowStep(id: "issue", backend: .claude, prompt: "出刊")
        step.publishEnabled = true
        var spec = WorkflowSpec()
        spec.name = "夹具晨报"
        spec.steps = [step]
        return WorkflowMarketItem(id: "fixture-pub", title: "夹具晨报", author: "t",
                                  summary: "s", tags: [], spec: spec,
                                  suggestedTime: "07:30")
    }

    private func state(_ clients: [any MarketSSHProtocol]) -> WorkflowMarketServerState {
        var queue = clients
        return WorkflowMarketServerState(profile: TestFactory.profile(), secret: "secret",
                                         makeSSH: { queue.removeFirst() })
    }

    func testR8_anInstallIsNotErasedByARefreshThatWasAlreadyInFlight() async {
        let item = capability
        let pulling = FakeSSH()      // the refresh that started BEFORE the tap
        let installing = FakeSSH()   // the tap's own connection
        pulling.templates = []                     // the library as the pull read it
        installing.echoesItsOwnWrites = true       // …and as it is once the save lands
        pulling.gate("listTemplates")

        let market = state([pulling, installing])
        let pull = Task { await market.refresh() }
        await pulling.awaitCall("listTemplates")
        XCTAssertFalse(market.isInstalled(item), "precondition: nothing installed yet")

        let toast = await market.install(item)
        XCTAssertEqual(toast, "已安装到服务器模板库", "precondition: the install succeeded")
        XCTAssertEqual(installing.savedTemplates.count, 1,
                       "precondition: the template really was written to the server")
        XCTAssertTrue(market.isInstalled(item), "precondition: the button says 已安装")

        pulling.release("listTemplates")
        await pull.value

        XCTAssertTrue(market.isInstalled(item),
                      "the refresh published a library listing it had read BEFORE the "
                      + "install and cleared the fallback on top — the template is on the "
                      + "server but the market offers 安装 again")
    }

    func testR8_aSubscriptionIsNotErasedByARefreshThatWasAlreadyInFlight() async {
        let item = publication
        let pulling = FakeSSH()
        let subscribing = FakeSSH()
        pulling.schedules = []                       // no schedules when the pull read them
        subscribing.echoesItsOwnWrites = true        // the server lists what it just added
        subscribing.script("date", "07:00")          // server clock, for the first-issue policy
        // Hold the pull inside the read whose answer the tap will invalidate: the
        // schedule list left the server before the subscription existed.
        pulling.gate("listSchedules")

        let market = state([pulling, subscribing])
        let pull = Task { await market.refresh() }
        await pulling.awaitCall("listSchedules")
        XCTAssertFalse(market.isSubscribed(item), "precondition: not subscribed yet")

        let toast = await market.subscribe(item)
        XCTAssertNotNil(toast, "precondition: the subscribe succeeded")
        XCTAssertEqual(subscribing.callCount("scheduleAdd"), 1,
                       "precondition: the schedule really was created on the server")
        XCTAssertTrue(market.isSubscribed(item), "precondition: the button says 已订阅")

        pulling.release("listSchedules")
        await pull.value

        XCTAssertTrue(market.isSubscribed(item),
                      "the refresh published a schedule list it had read BEFORE the "
                      + "subscription and cleared the fallback on top — one more tap now "
                      + "mints a SECOND daily schedule that double-runs every morning")
    }

    /// The other half of the rule: a pull that overlaps nothing is still the
    /// truth. A capability deleted on the server (or a schedule removed in the
    /// Workflows tab) must stop reading as 已安装 / 已订阅 after a clean refresh —
    /// the fallbacks are a bridge, not a memory.
    func testR8_aRefreshWithNoOverlappingActionStillClearsTheFallbacks() async {
        let item = capability
        let installing = FakeSSH()
        installing.echoesItsOwnWrites = true
        let afterDeletion = FakeSSH()
        afterDeletion.templates = []                 // someone deleted it on the server

        let market = state([installing, afterDeletion])
        _ = await market.install(item)
        XCTAssertTrue(market.isInstalled(item), "precondition: installed")

        await market.refresh()

        XCTAssertFalse(market.isInstalled(item),
                       "a refresh that raced nothing IS the truth — 已安装 must not be "
                       + "pinned on a template that is no longer on the server")
    }
}
