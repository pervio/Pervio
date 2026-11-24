import XCTest
@testable import Pervio

/// TWO paths create a daily schedule from a spec — the editor's Save and the
/// market's one-tap 订阅 — and the market decides 已订阅 by looking the name IT
/// computed up in `schedule list`. So the name is not cosmetic: it is the only
/// identifier the two paths share.
///
/// When they disagree the market cannot see a subscription the editor made. The
/// row's button stays live, the pre-add re-list asks the server about the wrong
/// name and also finds nothing, and the tap mints a SECOND daily schedule for the
/// same workflow — two runs, two cards, two bills, every morning, silently.
///
/// A nameless spec is where they disagreed: the editor fell back to a fixed
/// string, the market fell back to the catalog `title`.
@MainActor
final class ScheduleNameAgreementTests: XCTestCase {

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

    /// What an editor Save has always called a nameless spec's schedule
    /// (WorkflowEditorView.saveSchedule). Frozen as a literal here on purpose:
    /// schedules under this exact string are ALREADY on users' servers, so it is
    /// a wire contract, not an implementation detail — whatever the two paths
    /// converge on has to be able to recognize those. Change either side's rule
    /// and the cases below go red.
    private let editorNameForANamelessSpec = "Scheduled workflow"

    // MARK: fixtures

    /// A spec whose last step publishes — the one thing that makes a 刊物, i.e.
    /// the only kind of row that can be subscribed at all.
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
    /// by the PRODUCTION decoder. `title` is the wrapper's display name — market
    /// metadata that never reaches the server, and never reaches the editor.
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

    /// The one nameless publishing row both cases below act on, loaded through
    /// the real `templates list` → `marketItem` path.
    private func namelessRow(_ market: WorkflowMarketServerState) -> WorkflowMarketItem? {
        guard let item = market.templates.first?.marketItem else { return nil }
        guard item.spec.name.isEmpty, item.isPublication, !item.title.isEmpty,
              item.title != item.spec.name else { return nil }
        return item
    }

    // MARK: - editor first, market second

    /// The reported hole, in order: Save the schedule in the editor, come back to
    /// the market row for the SAME template, tap 订阅.
    func testTheMarketRecognizesTheScheduleTheEditorSavedForTheSameNamelessSpec() async {
        let fake = FakeSSH()
        fake.echoesItsOwnWrites = true
        // Only reachable if a second schedule really gets added: the first-issue
        // policy reads the server clock right after a successful add.
        fake.script("date", "05:00")
        // The server exactly as an editor Save left it: the spec carries no name,
        // so `schedule add` was given the editor's fixed fallback.
        fake.schedules = [FakeSSH.scheduleRow(id: "sched-1",
                                              name: editorNameForANamelessSpec, time: "06:30")]
        fake.templates = [template(file: "papers.json", title: "论文晨报(arXiv)",
                                   spec: publishingSpec(name: ""))]
        let market = market(fake)
        await market.refresh()
        guard let item = namelessRow(market) else {
            return XCTFail("precondition: a nameless publishing template lists and converts "
                           + "to a market row whose title is not the (empty) workflow name")
        }

        // The row must not offer to subscribe — but it must not claim 已订阅
        // either. A nameless spec schedules under the shared fallback name, and
        // ANY nameless workflow saved from the editor lands on that same name,
        // so this row cannot prove the schedule is its own. 已订阅 would gray the
        // only publication in the library out of existence on the strength of an
        // unrelated workflow. Off, and saying why, is the whole truth here.
        XCTAssertFalse(market.isSubscribed(item),
                       "the row claims 已订阅 off a name every nameless workflow shares — "
                       + "an unrelated editor Save would gray this one out for good")
        XCTAssertEqual(market.blockedLabel(item), "先起个名字",
                       "the button must be off and must say what to do about it")
        XCTAssertEqual(market.subscriptionState(item), .unnamedBucket)
        XCTAssertNotNil(market.subscriptionNote(item),
                        "a dead button with no sentence under it is the original complaint")

        let toast = await market.subscribe(item)

        XCTAssertEqual(fake.addedSchedules.count, 0,
                       "the tap added a SECOND daily schedule for one workflow: the server "
                       + "now fires 「\(editorNameForANamelessSpec)」 AND "
                       + "「\(fake.addedSchedules.first?.name ?? "")」 every morning — two "
                       + "runs, two cards, two bills, and nothing in the app says so")
        XCTAssertEqual(toast, "已订阅过了,无需重复",
                       "and it must say so out loud — silence reads like the tap did nothing")
    }

    // MARK: - market first, editor second

    /// The same disagreement seen from the other end: whatever the market names a
    /// nameless spec's schedule is what the editor will look at (and what the
    /// user will look at in the Workflows list) forever after. It has to be the
    /// name the editor itself would have chosen, or the very next Save on the same
    /// spec mints the duplicate instead.
    func testOneTapSubscribeNamesANamelessSpecsScheduleWhatTheEditorWould() async {
        let fake = FakeSSH()
        fake.echoesItsOwnWrites = true
        fake.script("date", "05:00")   // 05:00 < 06:30 → the server's own tick prints issue one
        fake.templates = [template(file: "papers.json", title: "论文晨报(arXiv)",
                                   spec: publishingSpec(name: ""))]
        let market = market(fake)
        await market.refresh()
        guard let item = namelessRow(market) else {
            return XCTFail("precondition: a nameless publishing template lists and converts "
                           + "to a market row whose title is not the (empty) workflow name")
        }

        let toast = await market.subscribe(item)
        XCTAssertNotNil(toast, "precondition: the subscribe went through — "
                        + (market.actionError ?? "no error"))

        XCTAssertEqual(fake.addedSchedules.map(\.name), [editorNameForANamelessSpec],
                       "the market named this schedule after its own catalog title, which "
                       + "the editor cannot know and never writes — so an editor Save on the "
                       + "same spec adds a second daily schedule under "
                       + "「\(editorNameForANamelessSpec)」")
    }

    // MARK: - the editor's own create path, executed

    /// The market cases above drive `subscribe()`, so they can only ever prove
    /// the MARKET's half. This one executes the code the editor's Save runs —
    /// `ScheduleCreate.add`, which owns the name for both entrances (neither is
    /// given a `name:` to get wrong) — and pins it to the string already on
    /// users' servers.
    func testTheCreatePathBothSavesRunNamesANamelessSpecTheWayTheEditorAlwaysHas() async throws {
        let fake = FakeSSH()
        _ = try await ScheduleCreate.add(ssh: fake, profile: TestFactory.profile(),
                                         spec: publishingSpec(name: ""), time: "06:30")

        XCTAssertEqual(fake.addedSchedules.map(\.name), [editorNameForANamelessSpec],
                       "the one create path renamed the nameless case, so every schedule "
                       + "already saved under 「\(editorNameForANamelessSpec)」 becomes "
                       + "invisible to the market row that made it — and the next 订阅 "
                       + "arms a duplicate beside it")
    }

    /// …and the same path leaves a named spec's own name alone.
    func testTheCreatePathKeepsANamedSpecsOwnName() async throws {
        let fake = FakeSSH()
        _ = try await ScheduleCreate.add(ssh: fake, profile: TestFactory.profile(),
                                         spec: publishingSpec(name: "论文晨报"), time: "06:30")

        XCTAssertEqual(fake.addedSchedules.map(\.name), ["论文晨报"],
                       "a spec's own name is the schedule's name — the fallback is for the "
                       + "nameless case only")
    }

    // MARK: - the guard against over-correcting

    /// Converging on the editor's rule must not flatten specs that DO have a
    /// name: the name in the spec is the user's own word for it, it is what the
    /// Workflows list shows, and both paths have always used it.
    func testANamedSpecKeepsItsOwnNameOnBothPaths() async {
        let fake = FakeSSH()
        fake.echoesItsOwnWrites = true
        fake.script("date", "05:00")
        fake.templates = [template(file: "papers.json", title: "论文晨报(arXiv)",
                                   spec: publishingSpec(name: "论文晨报"))]
        let market = market(fake)
        await market.refresh()
        guard let item = market.templates.first?.marketItem, item.title != item.spec.name else {
            return XCTFail("precondition: the row's title and the workflow name differ, so "
                           + "this case can tell which one the schedule was named after")
        }

        let toast = await market.subscribe(item)
        XCTAssertNotNil(toast, "precondition: the subscribe went through — "
                        + (market.actionError ?? "no error"))

        XCTAssertEqual(fake.addedSchedules.map(\.name), ["论文晨报"],
                       "a named spec's schedule is named after the SPEC on both paths — "
                       + "neither the market's display title nor the nameless fallback")
        XCTAssertNotEqual(fake.addedSchedules.first?.name, editorNameForANamelessSpec,
                          "the nameless fallback must stay the nameless case only")
    }
}
