import XCTest
@testable import Pervio

/// R9: "06:30" on a schedule is SERVER-local time — that is the clock the
/// server's own tick runs on. The first-issue policy asked the PHONE what time
/// it was, so a phone one timezone away from its server got the decision
/// backwards: it stayed quiet on a subscription whose slot had already gone by
/// (silent until tomorrow), or fired an extra issue on one that the server was
/// about to print anyway (a double run, day one).
///
/// B5: these two cases used to lean on the phone's REAL clock to make that
/// point. They were written so that `Calendar.current` disagreed with the
/// scripted server clock at every minute of the day except one (23:59 for the
/// first, 00:00 for the second) — which meant that during those minutes the
/// tests still passed under the exact regression they exist to catch, and a
/// suite you have to read with a clock in your other hand isn't evidence. The
/// phone clock is now injected: every case below hands in the clock that would
/// make the WRONG decision, so if the policy ever consults the phone again the
/// test is red at every minute of the day.
@MainActor
final class ScheduleFirstIssueTests: XCTestCase {

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

    private func settle(clock: String?, scheduleTime: String,
                        phone: (Int, Int)) async -> (String, FakeSSH) {
        let fake = FakeSSH()
        if let clock { fake.script("date", clock) } else { fake.fail("date") }
        let line = await ScheduleFirstIssue.settle(ssh: fake, time: scheduleTime,
                                                   phoneClock: { phone })
        return (line, fake)
    }

    /// 2026-09-01: subscribing REGISTERS, it never SPENDS. The auto-fired
    /// "first issue" is gone — a 订阅 tap that quietly burned a full pipeline
    /// run surprised exactly the user it was meant to reassure. The clock now
    /// only WORDS the toast (今天 vs 明天); the server-vs-phone teeth of R9
    /// live on in the wording asserts.
    func testR9_slotAlreadyPassed_saysTomorrowAndNeverFires() async {
        let (line, fake) = await settle(clock: "23:59", scheduleTime: "23:59", phone: (0, 0))
        XCTAssertEqual(fake.firedSchedules, [],
                       "subscribing must never spend a run — the slot being gone means "
                       + "the next issue is tomorrow's, not a surprise bill now")
        XCTAssertEqual(line, "已订阅,下期明天 23:59 自动送达",
                       "the phone (00:00) would have said 今天 — the SERVER's clock words it")
    }

    func testR9_slotStillAhead_saysTodayAndNeverFires() async {
        let (line, fake) = await settle(clock: "00:00", scheduleTime: "00:01", phone: (23, 59))
        XCTAssertEqual(fake.firedSchedules, [])
        XCTAssertEqual(line, "已订阅,首期今天 00:01 自动送达",
                       "the phone (23:59) would have said 明天 — the SERVER's clock words it")
    }

    /// The clock is read over the same connection the subscribe already has;
    /// a server that won't answer must not break subscribing.
    func testR9_anUnreadableServerClockStillSettlesTheSubscription() async {
        let (line, fake) = await settle(clock: nil, scheduleTime: "06:30", phone: (12, 0))
        XCTAssertTrue(fake.calls.contains { $0.contains("date +%H:%M") },
                      "the server clock must be asked — otherwise the phone's timezone "
                      + "words the promise: \(fake.calls)")
        XCTAssertTrue(line.hasPrefix("已订阅"), "a subscription, not an error: \(line)")
        XCTAssertEqual(fake.firedSchedules, [], "NO path through settle() may fire")
    }

    /// Server unreachable → the phone's own clock words it, both directions —
    /// and neither direction fires anything.
    func testR9_whenTheServerWontAnswerThePhonesClockWordsIt() async {
        let (passed, passedFake) = await settle(clock: nil, scheduleTime: "06:30", phone: (12, 0))
        XCTAssertEqual(passedFake.firedSchedules, [])
        XCTAssertEqual(passed, "已订阅,下期明天 06:30 自动送达")

        let (ahead, aheadFake) = await settle(clock: nil, scheduleTime: "06:30", phone: (6, 0))
        XCTAssertEqual(aheadFake.firedSchedules, [])
        XCTAssertEqual(ahead, "已订阅,首期今天 06:30 自动送达")
    }

    /// A server whose `date` comes back wrapped in a login banner still yields
    /// the clock, not the phone's.
    func testR9_serverClockIsReadThroughABannerLine() async {
        let (line, _) = await settle(clock: "Welcome to prod-1\n\n23:59\n",
                                     scheduleTime: "23:59", phone: (0, 0))
        XCTAssertEqual(line, "已订阅,下期明天 23:59 自动送达",
                       "the clock line was there — it just wasn't the only line")
    }

    // MARK: - 现在来一期 (the explicit replacement for the auto-fire)

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

    /// Wire models decode tolerantly and expose no memberwise init — mint the
    /// fixture the way the wire would.
    private func minted(_ id: String, name: String) -> WorkflowSchedule {
        try! JSONDecoder().decode(WorkflowSchedule.self, from: Data(
            #"{"id":"\#(id)","name":"\#(name)","time":"07:30"}"#.utf8))
    }

    func testRunIssueNow_firesExactlyTheSubscribedSchedule() async {
        let fake = FakeSSH()
        let store = WorkflowMarketServerState(profile: TestFactory.profile(),
                                              secret: "s", makeSSH: { fake })
        let item = publication
        // scheduleName is fileprivate to the market file; a NAMED spec's
        // schedule name is its own name, so the fixture states it directly.
        store.schedules = [minted("sched-9", name: "夹具晨报")]

        let toast = await store.runIssueNow(item)

        XCTAssertEqual(fake.firedSchedules, ["sched-9"])
        XCTAssertEqual(toast, "这一期正在印制 — 稍后见首页卡片")
    }

    func testRunIssueNow_withoutItsScheduleIsAQuietNoOp() async {
        let fake = FakeSSH()
        let store = WorkflowMarketServerState(profile: TestFactory.profile(),
                                              secret: "s", makeSSH: { fake })
        let toast = await store.runIssueNow(publication)
        XCTAssertNil(toast)
        XCTAssertEqual(fake.firedSchedules, [], "no schedule, nothing to fire")
        XCTAssertTrue(fake.calls.isEmpty, "…and no connection is even opened: \(fake.calls)")
    }
}
