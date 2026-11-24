import XCTest
@testable import Pervio

/// U1: the market decides which shelf a workflow belongs on — 刊物 (subscribe
/// once, printed daily onto the home screen) or 能力 (installed / summoned).
/// The judgment used to need TWO things: a spec that publishes AND a
/// `suggestedTime`. Only the bundled catalog ever carries a time: the server's
/// own `templates list` has never sent one, and neither does a shared JSON
/// someone pastes in. So a workflow that plainly produces a daily publication
/// landed on the capability shelf, where there is no 订阅 button at all — the
/// user's GitHub 热点日报 could be neither subscribed nor recognised as already
/// subscribed from the market.
@MainActor
final class PublicationShelfTests: XCTestCase {

    /// A spec whose last step publishes — the one mechanism that makes a home
    /// card (`publish` on a step; the server archives that step's output).
    private func publishingSpec(name: String = "GitHub 热点日报",
                                publishDir: String? = nil) -> WorkflowSpec {
        var fetch = WorkflowStep(id: "fetch", backend: .claude, prompt: "")
        fetch.command = "curl -s https://example.invalid/trending"
        var digest = WorkflowStep(id: "digest", backend: .claude,
                                  prompt: "写日报", dependsOn: ["fetch"])
        digest.publishEnabled = true
        digest.publishDir = publishDir
        var spec = WorkflowSpec()
        spec.name = name
        spec.dir = "~"
        spec.steps = [fetch, digest]
        return spec
    }

    private func item(_ spec: WorkflowSpec, suggestedTime: String? = nil) -> WorkflowMarketItem {
        WorkflowMarketItem(id: "github-daily", title: "GitHub 热点日报", author: "me",
                           summary: "", tags: [], spec: spec, suggestedTime: suggestedTime)
    }

    /// The bug the user hit, at the level that decides it.
    func testU1_aSpecThatPublishesIsAPublicationEvenWithNoSuggestedTime() {
        let it = item(publishingSpec())

        XCTAssertNil(it.suggestedTime,
                     "precondition: nothing outside the bundled catalog carries a time")
        XCTAssertTrue(it.spec.publishes,
                      "precondition: this spec really does produce a daily publication")
        XCTAssertTrue(it.isPublication,
                      "a workflow with a publish step is a 刊物 — judged on the missing "
                      + "suggestedTime instead, it lands on the 能力 shelf where there is "
                      + "no 订阅 button, so the user can neither subscribe to it nor see "
                      + "that they already have")
    }

    /// The other half of the rule, so the fix can't be "everything is a 刊物":
    /// nothing without a publish step may be labelled one.
    func testU1_aSpecWithoutAPublishStepIsStillACapability() {
        var spec = WorkflowSpec()
        spec.name = "深度代码审计"
        spec.steps = [WorkflowStep(id: "audit", backend: .codex, prompt: "审")]

        XCTAssertFalse(item(spec).isPublication,
                       "a workflow that publishes nothing must never be offered as a "
                       + "subscription — 订阅 would arm a daily run that prints no card")
        XCTAssertFalse(item(spec, suggestedTime: "06:30").isPublication,
                       "a suggested time alone is a schedule hint, not a publication")
    }

    /// The button's promise and the schedule it creates are ONE number. A row
    /// that says 06:30 while `subscribe` arms something else is how a user ends
    /// up with an issue that never arrives when they expect it.
    func testU1_aPublicationWithNoServerTimeAdvertisesTheSameDefaultItSubscribesAt() {
        XCTAssertEqual(item(publishingSpec()).subscribeTime, PublicationTarget.defaultDailyTime,
                       "with no time from the server the market subscribes at the default — "
                       + "the row has to advertise that same time, not 'no time'")
        XCTAssertEqual(item(publishingSpec(), suggestedTime: "07:15").subscribeTime, "07:15",
                       "when the template DOES carry a time, that time wins")
    }

    // MARK: - Server templates (the user's own 热点日报)

    /// One `templates list` entry, built the way the server writes it: the
    /// wrapper carries name/summary/suggestedTime, the spec sits inside. Decoded
    /// by the PRODUCTION decoder so a field the app forgets to read fails here.
    private func templateJSON(spec: WorkflowSpec, file: String = "github-daily.json",
                              name: String = "GitHub 热点日报",
                              suggestedTime: String? = nil,
                              kind: String? = nil, ok: Bool = true) -> String {
        let specData = try! JSONEncoder().encode(spec)
        let specObj = try! JSONSerialization.jsonObject(with: specData)
        var entry: [String: Any] = ["file": file, "mtime": 1_700_000_000, "ok": ok,
                                    "name": name, "steps": spec.steps.count,
                                    "summary": "每天早上的 GitHub 热点", "spec": specObj]
        if let suggestedTime { entry["suggestedTime"] = suggestedTime }
        if let kind { entry["kind"] = kind }
        if !ok { entry["error"] = "not valid JSON" }
        let data = try! JSONSerialization.data(withJSONObject: entry)
        return String(decoding: data, as: UTF8.self)
    }

    private func template(_ json: String) -> ServerTemplate {
        try! JSONDecoder().decode(ServerTemplate.self, from: Data(json.utf8))
    }

    private func market(_ fake: FakeSSH) -> WorkflowMarketServerState {
        WorkflowMarketServerState(profile: TestFactory.profile(), secret: "secret",
                                  makeSSH: { fake })
    }

    /// The whole user-visible bug, end to end: their own publishing template is
    /// listed by the server, and the market can subscribe it in one tap without
    /// a trip through the editor.
    func testU1_aServerTemplateThatPublishesIsSubscribableInOneTap() async {
        let fake = FakeSSH()
        fake.echoesItsOwnWrites = true
        fake.script("date", "05:00")          // server clock — 06:30 is still ahead today
        fake.templates = [template(templateJSON(spec: publishingSpec()))]
        let market = market(fake)
        await market.refresh()

        guard let row = market.templates.first, let it = row.marketItem else {
            return XCTFail("a listed, parseable workflow template must convert to a market "
                           + "item — without one there is no 订阅 button on its row at all")
        }
        XCTAssertTrue(it.isPublication, "it has a publish step: it belongs on the 刊物 shelf")
        XCTAssertFalse(market.isSubscribed(it), "precondition: nothing subscribed yet")

        let toast = await market.subscribe(it)

        XCTAssertNotNil(toast, "the subscribe failed: \(market.actionError ?? "no error")")
        XCTAssertEqual(fake.addedSchedules.map { "\($0.name)@\($0.time)" },
                       ["GitHub 热点日报@06:30"],
                       "a template with no time of its own subscribes at the default, under "
                       + "the workflow's own name — the same name 已订阅 is judged on")
        XCTAssertTrue(market.isSubscribed(it), "the row must flip to 已订阅 straight away")
    }

    /// The other half the user complained about: the digest was ALREADY running
    /// every morning and the market still showed no sign of it.
    func testU1_aTemplateWhoseScheduleIsAlreadyRunningReadsAsSubscribed() async {
        let fake = FakeSSH()
        fake.templates = [template(templateJSON(spec: publishingSpec()))]
        fake.schedules = [FakeSSH.scheduleRow(id: "sched-1", name: "GitHub 热点日报",
                                              time: "06:30")]
        let market = market(fake)
        await market.refresh()

        guard let it = market.templates.first?.marketItem else {
            return XCTFail("precondition: the template converts to a market item")
        }
        XCTAssertTrue(market.isSubscribed(it),
                      "a schedule under this workflow's name is already firing every "
                      + "morning — offering 订阅 again mints a SECOND daily schedule that "
                      + "double-runs and double-spends")
    }

    /// The server half of this batch adds `suggestedTime` to `templates list`
    /// (wrapper field, omitted when absent). The app has to read it — and has to
    /// still work against a server that never sends it.
    func testU1_theTemplatesOwnTimeIsWhatGetsScheduled() async {
        let fake = FakeSSH()
        fake.echoesItsOwnWrites = true
        fake.script("date", "05:00")
        fake.templates = [template(templateJSON(spec: publishingSpec(), suggestedTime: "07:15"))]
        let market = market(fake)
        await market.refresh()

        XCTAssertEqual(market.templates.first?.suggestedTime, "07:15",
                       "the wrapper's daily time never reached the app")
        guard let it = market.templates.first?.marketItem else {
            return XCTFail("precondition: the template converts to a market item")
        }
        XCTAssertEqual(it.subscribeTime, "07:15")

        _ = await market.subscribe(it)

        XCTAssertEqual(fake.addedSchedules.map(\.time), ["07:15"],
                       "the template asked for 07:15 and the subscription armed another "
                       + "time — the issue arrives when the user isn't expecting it")
    }

    func testU1_anOlderServerSendsNoTimeAndTheTemplateStillSubscribes() async {
        let fake = FakeSSH()
        fake.templates = [template(templateJSON(spec: publishingSpec()))]
        let market = market(fake)
        await market.refresh()

        XCTAssertNil(market.templates.first?.suggestedTime,
                     "an old server omits the field entirely — that must decode as nil, "
                     + "not fail the whole listing")
        XCTAssertEqual(market.templates.first?.marketItem?.subscribeTime,
                       PublicationTarget.defaultDailyTime,
                       "no time from the server = subscribe at the default, not refuse")
    }

    /// Guards against the fix over-reaching: rows that must NEVER grow a 订阅
    /// button. A playbook has no spec at all (it is loaded into a conversation),
    /// and a broken file's spec is exactly the thing we couldn't read.
    func testU1_playbooksAndBrokenTemplatesAreNeverSubscribable() {
        let playbook = template(#"{"file":"p.json","name":"复盘剧本","ok":true,"#
                                + #""kind":"playbook","body":"复盘方法论正文","mtime":1}"#)
        XCTAssertNil(playbook.marketItem,
                     "a playbook is text for a conversation — subscribing one would arm a "
                     + "daily run of something that can't run")

        let broken = template(templateJSON(spec: publishingSpec(), ok: false))
        XCTAssertNil(broken.marketItem,
                     "the file didn't parse server-side; subscribing its half-read spec "
                     + "would arm a daily run nobody has seen")

        var plain = WorkflowSpec()
        plain.name = "整理下载目录"
        plain.steps = [WorkflowStep(id: "tidy", backend: .claude, prompt: "整理")]
        let capability = template(templateJSON(spec: plain, name: "整理下载目录"))
        XCTAssertEqual(capability.marketItem?.isPublication, false,
                       "a template that publishes nothing stays a 能力: it converts (so the "
                       + "row can still say so) but must not be offered as a subscription")
    }
}
