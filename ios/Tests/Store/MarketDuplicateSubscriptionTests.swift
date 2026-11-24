import XCTest
@testable import Pervio

/// The two defences that keep ONE tap on 订阅 from arming a SECOND daily
/// schedule — the failure that double-runs and double-spends every morning,
/// silently, until someone reads the Workflows list.
///
/// Both became reachable in the same batch: template rows grew a 订阅 button, so
/// `subscribe()` now has a third caller and the market's 已订阅 judgment is
/// consulted for rows it was never written for.
@MainActor
final class MarketDuplicateSubscriptionTests: XCTestCase {

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

    // MARK: fixtures

    /// A spec whose last step publishes — the one thing that makes a 刊物.
    private func publishingSpec(name: String) -> WorkflowSpec {
        var fetch = WorkflowStep(id: "fetch", backend: .claude, prompt: "")
        fetch.command = "curl -s https://example.invalid/papers"
        var digest = WorkflowStep(id: "digest", backend: .claude, prompt: "写日报",
                                  dependsOn: ["fetch"])
        digest.publishEnabled = true
        var spec = WorkflowSpec()
        spec.name = name
        spec.dir = "~"
        spec.steps = [fetch, digest]
        return spec
    }

    /// One `templates list` row, built the way the server writes it and decoded
    /// by the PRODUCTION decoder.
    private func template(file: String, title: String, spec: WorkflowSpec) -> ServerTemplate {
        let specObj = try! JSONSerialization.jsonObject(
            with: try! JSONEncoder().encode(spec))
        let entry: [String: Any] = ["file": file, "mtime": 1_700_000_000, "ok": true,
                                    "name": title, "steps": spec.steps.count,
                                    "summary": "", "spec": specObj]
        let data = try! JSONSerialization.data(withJSONObject: entry)
        return try! JSONDecoder().decode(ServerTemplate.self, from: data)
    }

    private func market(_ fake: FakeSSH) -> WorkflowMarketServerState {
        WorkflowMarketServerState(profile: TestFactory.profile(), secret: "secret",
                                  makeSSH: { fake })
    }

    // MARK: - P2-A: the server-side check before the add

    /// The market's cached schedule list is not the truth — it is whatever the
    /// last pull managed to read. A tap that lands while the first pull is still
    /// in flight, or after it failed, is judged against an EMPTY list, so
    /// 已订阅 says "no" about a schedule that has been printing every morning
    /// for a week. The only thing standing between that tap and a second
    /// 「GitHub 热点日报@06:30」 is `subscribe()`'s own re-list on its own
    /// connection, before the add.
    ///
    /// So this test deliberately never calls `refresh()`: the stale/failed-pull
    /// state IS the state the guard exists for.
    func testP2A_aTapOnAStaleShelfDoesNotMintASecondDailySchedule() async {
        let fake = FakeSSH()
        fake.echoesItsOwnWrites = true
        // Only ever reached if the guard is gone: the first-issue policy asks
        // the server's clock right after a successful add.
        fake.script("date", "05:00")
        // The server as it really is — the subscription already exists.
        fake.schedules = [FakeSSH.scheduleRow(id: "sched-1", name: "GitHub 热点日报",
                                              time: "06:30")]
        let market = market(fake)
        let row = template(file: "github-daily.json", title: "GitHub 热点日报",
                           spec: publishingSpec(name: "GitHub 热点日报"))
        guard let item = row.marketItem else {
            return XCTFail("precondition: a parseable publishing template is a market item")
        }

        XCTAssertFalse(market.isSubscribed(item),
                       "precondition: this is the whole point — the app's cached view has "
                       + "no idea the schedule exists, so the button is live and tappable")

        let toast = await market.subscribe(item)

        XCTAssertEqual(fake.addedSchedules.count, 0,
                       "the tap created a SECOND daily schedule under a name the server "
                       + "already had: 「GitHub 热点日报@06:30」 now fires twice every "
                       + "morning, printing two cards and spending two runs' quota, and "
                       + "nothing in the app says so")
        XCTAssertEqual(fake.callCount("scheduleAdd"), 0,
                       "nothing may reach scheduleAdd once the server says the name is taken")
        XCTAssertEqual(toast, "已订阅过了,无需重复",
                       "a refusal the user can read — silence would look like the tap did "
                       + "nothing, and they would tap again")
        XCTAssertTrue(market.isSubscribed(item),
                      "the check just read the truth off the server — the row must flip to "
                      + "已订阅 so the refusal makes sense")
    }

    // MARK: - P2-B: two templates, one workflow name

    /// `marketItem` namespaces a row's id by FILENAME on purpose ("never the
    /// workflow name, two templates may share one"), and then 已订阅 asks about
    /// `spec.name` anyway. Two papers templates both called 论文晨报: subscribing
    /// A makes B's brand-new 订阅 button gray out for good, with no explanation
    /// and nothing the user can do about it.
    func testP2B_subscribingOneTemplateDoesNotClaimASameNamedSiblingsSubscription() async {
        let fake = FakeSSH()
        fake.echoesItsOwnWrites = true
        fake.script("date", "05:00")
        fake.templates = [
            template(file: "papers-a.json", title: "论文晨报(arXiv)",
                     spec: publishingSpec(name: "论文晨报")),
            template(file: "papers-b.json", title: "论文晨报(HuggingFace)",
                     spec: publishingSpec(name: "论文晨报")),
        ]
        let market = market(fake)
        await market.refresh()

        guard market.templates.count == 2,
              let a = market.templates[0].marketItem,
              let b = market.templates[1].marketItem else {
            return XCTFail("precondition: both templates list and convert to market items")
        }
        XCTAssertNotEqual(a.id, b.id, "precondition: rows are keyed by filename, not name")
        XCTAssertEqual(a.spec.name, b.spec.name,
                       "precondition: the two specs really do carry the same workflow name, "
                       + "which is what the schedule they would create is named after")

        let toast = await market.subscribe(a)
        XCTAssertNotNil(toast, "precondition: A subscribed — \(market.actionError ?? "no error")")
        XCTAssertEqual(fake.addedSchedules.map(\.name), ["论文晨报"],
                       "precondition: exactly one schedule exists, and it is A's")

        XCTAssertFalse(market.isSubscribed(b),
                       "B has no subscription — the only schedule on the server is A's. "
                       + "Reading 已订阅 off the shared workflow name grays B's brand-new "
                       + "订阅 button permanently, with no explanation and no way out; "
                       + "reached from anywhere else, the pre-add guard then refuses it "
                       + "with 「已订阅过了」 about a schedule that isn't B's")
        XCTAssertTrue(market.isSubscribed(a),
                      "A is the row that armed it — it must still read 已订阅, or the fix "
                      + "has simply turned the button back on for a schedule that exists")

        // The row has to SAY the thing, not just go quiet: which name is taken,
        // that the app can't tell whose it is, and the way out.
        guard let note = market.subscriptionNote(b) else {
            return XCTFail("B's button is off and the row explains nothing — that is the "
                           + "same dead gray button, only relabelled")
        }
        XCTAssertTrue(note.contains("论文晨报"), "the note must name the schedule name at "
                      + "stake, otherwise the user can't find what to rename: \(note)")
        XCTAssertNil(market.subscriptionNote(a),
                     "A's row owns its subscription — it gets 已订阅, not a conflict note")

        if case .nameTaken = market.subscriptionState(b) {} else {
            XCTFail("B must read as 'the name is taken by a same-named workflow', which is "
                    + "the only thing the app actually knows: got "
                    + "\(market.subscriptionState(b))")
        }
    }
}
