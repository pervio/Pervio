import XCTest
@testable import Pervio

/// The group page is a thin client: it sends one `say`, then watches `tick`
/// until the Mac's round settles. These pin the client-side contract — the
/// strip's wording per state, the pane-refresh signal firing exactly when the
/// set of runs changes, a busy round refusing a second message, and the
/// create sheet's payload (the primary as configured, a new partner read-only).
@MainActor
final class GroupStoreTests: XCTestCase {

    private func groupJSON(state: String, n: Int = 1, runs: [String: String] = [:],
                           answers: [String: String] = [:], synthRun: String = "",
                           relayRuns: [String: String] = [:], memberSession: String = "",
                           rev: Int = 0) -> String {
        let g: [String: Any] = [
            "id": "abc123abc123", "dir": "/proj", "mode": "parallel", "autoSynth": true, "maxRounds": 5, "rev": rev,
            "primary": ["session": "sess-P", "backend": "claude", "perm": "auto"],
            "members": [["session": memberSession, "backend": "codex", "sandbox": "read-only"]],
            "createdAt": 1, "round": ["n": n, "state": state, "text": "q", "runs": runs,
                                      "answers": answers, "synthRun": synthRun, "synth": "", "relayRuns": relayRuns],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: g), encoding: .utf8)!
    }

    private func watchJSON(state: String, round: Int = 1, verdicts: [String] = [], question: String = "",
                           summary: String = "", rev: Int = 0) -> String {
        var rounds: [[String: Any]] = []
        for (i, v) in verdicts.enumerated() {
            rounds.append(["round": i + 1, "p": "p\(i + 1)", "w": "w\(i + 1)", "verdict": v, "text": "意见 \(i + 1)"])
        }
        if rounds.count < round {
            rounds.append(["round": round, "p": "p\(round)", "w": state == "reviewing" ? "w\(round)" : "", "verdict": "", "text": ""])
        }
        let g: [String: Any] = [
            "id": "abc123abc123", "dir": "/proj", "mode": "watch", "autoSynth": false, "maxRounds": 5, "rev": rev,
            "primary": ["session": "sess-P", "backend": "claude", "perm": "acceptEdits"],
            "members": [["session": "", "backend": "codex", "sandbox": "workspace-write"]],
            "createdAt": 1, "round": ["n": 0, "state": "idle", "text": "", "runs": [:], "answers": [:],
                                      "synthRun": "", "synth": "", "relayRuns": [:]],
            "watch": ["task": ["n": 1, "goal": "加分页", "round": round, "state": state, "rounds": rounds,
                               "question": question, "decision": NSNull(), "summary": summary, "error": "",
                               "startedAt": 1, "endedAt": 0], "history": []],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: g), encoding: .utf8)!
    }

    private func store(_ fake: FakeSSH, state: String = "idle") -> GroupStore {
        let g = try! JSONDecoder().decode(ChatGroup.self, from: Data(groupJSON(state: state).utf8))
        return GroupStore(profile: TestFactory.profile(), secret: "s", group: g, ssh: fake)
    }

    func testSayOpensARoundAndTellsThePanesToLookAgain() async {
        let fake = FakeSSH()
        fake.script("pervio-group say", groupJSON(state: "answering", runs: ["p": "r1", "m0": "r2"], rev: 1))
        fake.script("pervio-group tick", groupJSON(state: "answering", runs: ["p": "r1", "m0": "r2"], rev: 1))
        let s = store(fake)
        XCTAssertEqual(s.refreshToken, 0)
        await s.say("这题怎么解")
        XCTAssertEqual(s.group.round.state, "answering")
        XCTAssertEqual(s.refreshToken, 1, "rev moved → the panes reattach")
        XCTAssertTrue(fake.calls.contains { $0.contains("--to all") }, "the strip's default target is everyone")
        XCTAssertTrue(s.isBusy)
        XCTAssertTrue(s.statusLine.contains("0/2") || s.statusLine.contains("已答 0/2"), s.statusLine)
        s.stopPolling()
    }

    func testRefreshAdvancesStateAndSignalsOnlyWhenRunsChange() async {
        let fake = FakeSSH()
        fake.script("pervio-group tick", groupJSON(state: "answering", runs: ["p": "r1", "m0": "r2"],
                                                   answers: ["p": "A"], rev: 2))
        let s = store(fake, state: "answering")
        await s.refresh()
        let t1 = s.refreshToken
        await s.refresh()                      // same rev → no new signal
        XCTAssertEqual(s.refreshToken, t1, "an unchanged rev must not churn the panes")
        fake.script("pervio-group tick", groupJSON(state: "synthesizing", runs: ["p": "r1", "m0": "r2"],
                                                   answers: ["p": "A", "m0": "B"], synthRun: "r3",
                                                   memberSession: "thread-NEW", rev: 3))
        await s.refresh()
        XCTAssertEqual(s.group.round.state, "synthesizing")
        XCTAssertEqual(s.refreshToken, t1 + 1, "rev moved → signal once")
        XCTAssertEqual(s.group.members[0].session, "thread-NEW", "the partner's session id arrives with its first run")
        XCTAssertTrue(s.statusLine.contains("汇总") || s.statusLine.lowercased().contains("synth"), s.statusLine)
        fake.script("pervio-group tick", groupJSON(state: "done", runs: ["p": "r1", "m0": "r2"],
                                                   answers: ["p": "A", "m0": "B"], synthRun: "r3",
                                                   memberSession: "thread-NEW", rev: 4))
        await s.refresh()
        XCTAssertFalse(s.isBusy)
        XCTAssertEqual(s.refreshToken, t1 + 2)
    }

    func testABusyRoundRefusesASecondMessageButAllowsAPrivateWord() async {
        let fake = FakeSSH()
        let s = store(fake, state: "answering")
        await s.say("again")
        XCTAssertFalse(fake.calls.contains { $0.contains("pervio-group say") }, "nothing goes to everyone mid-round")
        fake.script("pervio-group say", groupJSON(state: "answering", runs: ["p": "r1", "m0": "r2"], rev: 2))
        await s.say("只问你", to: "m0")
        XCTAssertTrue(fake.calls.contains { $0.contains("--to m0") }, "a word to ONE member is allowed any time")
        s.stopPolling()
    }

    func testWatchModeReadsTheTaskAndCanStopTheLoop() async {
        let fake = FakeSSH()
        var g = try! JSONDecoder().decode(ChatGroup.self, from: Data(watchJSON(state: "reviewing", round: 2, verdicts: ["继续"]).utf8))
        let s = GroupStore(profile: TestFactory.profile(), secret: "s", group: g, ssh: fake)
        XCTAssertTrue(g.isWatch && g.watchActive, "a loop in flight keeps the page polling")
        XCTAssertEqual(g.task?.rounds.first?.verdict, "继续")
        XCTAssertTrue(s.statusLine.contains("2/3"), s.statusLine)
        XCTAssertTrue(s.isBusy)
        await s.say("插一句", to: "p")
        XCTAssertFalse(fake.calls.contains { $0.contains("pervio-group say") }, "mid-loop the field is closed: stop first, then resend")
        XCTAssertNotNil(s.errorText)
        fake.script("pervio-group stop", watchJSON(state: "stopped", round: 2, verdicts: ["继续"], rev: 1))
        await s.stop()
        XCTAssertTrue(fake.calls.contains { $0.contains("pervio-group stop --id abc123abc123") }, "停 → stop")
        XCTAssertEqual(s.group.task?.state, "stopped")
        XCTAssertFalse(s.isBusy)
        s.stopPolling()
        // the endings read back as the person sees them
        g = try! JSONDecoder().decode(ChatGroup.self, from: Data(watchJSON(state: "waiting", round: 2, verdicts: ["继续", "需要你"], question: "24 还是 50?").utf8))
        XCTAssertEqual(GroupStore.watchStatus(g), L.groupTaskN(1) + " · " + L.groupWatchWaiting())
        XCTAssertEqual(g.task?.question, "24 还是 50?")
        g = try! JSONDecoder().decode(ChatGroup.self, from: Data(watchJSON(state: "passed", round: 1, verdicts: ["通过"], summary: "可以合了").utf8))
        XCTAssertTrue(GroupStore.watchStatus(g).contains("1"), GroupStore.watchStatus(g))
        XCTAssertEqual(g.task?.summary, "可以合了")
        // a parallel group is untouched by any of this
        let plain = store(fake)
        XCTAssertFalse(plain.group.isWatch)
        await plain.stop()
        XCTAssertEqual(fake.calls.filter { $0.contains("pervio-group stop") }.count, 1, "stop is watch-only")
    }

    func testTheForkKeyRidesAlongAndAMemberCanBeReconfigured() async {
        let fake = FakeSSH()
        fake.script("pervio-group say", groupJSON(state: "answering", runs: ["p": "r1", "m0": "r2"], rev: 1))
        fake.script("pervio-group tick", groupJSON(state: "answering", runs: ["p": "r1", "m0": "r2"], rev: 1))
        let s = store(fake)
        await s.say("带上工作流上下文", pervioContext: true)
        XCTAssertTrue(fake.calls.contains { $0.contains("pervio-group say") && $0.contains("--pervio-context") },
                      "a lit fork key sends --pervio-context")
        s.stopPolling()
        fake.script("pervio-group set", groupJSON(state: "answering", runs: ["p": "r1", "m0": "r2"], rev: 2))
        await s.setMember("m0", ["model": "gpt-test-9", "sandbox": ""])
        let set = fake.calls.first { $0.contains("pervio-group set") } ?? ""
        XCTAssertTrue(set.contains("--to m0"), set)
        XCTAssertEqual(s.refreshToken, 2, "the Mac bumped rev → panes look again")
        s.stopPolling()
    }

    private func duoJSON(live: [String: String] = [:], last: [String: String] = [:], rev: Int = 0) -> String {
        let g: [String: Any] = [
            "id": "abc123abc123", "dir": "/proj", "mode": "duo", "autoSynth": false, "maxRounds": 5, "rev": rev,
            "primary": ["session": "sess-P", "backend": "claude", "perm": "acceptEdits"],
            "members": [["session": "sess-M", "backend": "codex", "sandbox": "read-only"]],
            "createdAt": 1, "round": ["n": 0, "state": "idle", "text": "", "runs": [:], "answers": [:],
                                      "synthRun": "", "synth": "", "relayRuns": [:]],
            "duo": ["live": live, "last": last],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: g), encoding: .utf8)!
    }

    /// 双窗: a window still answering takes no second word, the other window is
    /// free; a critique needs a reply to quote and goes out as `say --critique`
    /// with the person's note; 停 cuts a live window short.
    func testDuoWindowsAreIndependentAndACritiqueQuotesTheOtherSide() async {
        let fake = FakeSSH()
        var g = try! JSONDecoder().decode(ChatGroup.self, from: Data(duoJSON(live: ["p": "r1"]).utf8))
        let s = GroupStore(profile: TestFactory.profile(), secret: "s", group: g, ssh: fake)
        XCTAssertTrue(g.isDuo && g.duoActive && g.isLive("p") && !g.isLive("m0"))
        XCTAssertTrue(s.isBusy)
        XCTAssertEqual(s.statusLine, L.groupDuoAnswering(L.groupPartnerN(1)) + " · " + L.groupDuoIdle(L.groupPartnerN(2)))
        await s.say("再说一句", to: "p")
        XCTAssertFalse(fake.calls.contains { $0.contains("pervio-group say") }, "the window still answering takes no second word")
        XCTAssertEqual(s.errorText, L.groupMemberBusy())
        fake.script("pervio-group say", duoJSON(live: ["p": "r1", "m0": "r2"], rev: 1))
        await s.say("你说", to: "m0")
        XCTAssertTrue(fake.calls.contains { $0.contains("--to m0") }, "the other window is free meanwhile")
        s.stopPolling()

        g = try! JSONDecoder().decode(ChatGroup.self, from: Data(duoJSON().utf8))
        let s2 = GroupStore(profile: TestFactory.profile(), secret: "s", group: g, ssh: fake)
        await s2.critique(by: "p", of: "m0")
        XCTAssertFalse(fake.calls.contains { $0.contains("--critique") }, "nothing to quote yet")
        XCTAssertEqual(s2.errorText, L.groupNothingToCritique())

        g = try! JSONDecoder().decode(ChatGroup.self, from: Data(duoJSON(last: ["m0": "r2"]).utf8))
        let s3 = GroupStore(profile: TestFactory.profile(), secret: "s", group: g, ssh: fake)
        fake.script("pervio-group say", duoJSON(live: ["p": "r3"], last: ["m0": "r2"], rev: 2))
        await s3.critique(by: "p", of: "m0", extra: "重点看边界")
        let call = fake.calls.first { $0.contains("--critique") } ?? ""
        XCTAssertTrue(call.contains("--to p --critique m0") && call.contains("重点看边界"), call)
        XCTAssertTrue(s3.group.isLive("p"))
        s3.stopPolling()
        fake.script("pervio-group stop", duoJSON(last: ["m0": "r2"], rev: 3))
        await s3.stop()
        XCTAssertFalse(s3.group.duoActive, "停 works on a duo window")
        XCTAssertEqual(GroupStore.duoStatus(s3.group), L.groupDuoIdle(L.groupPartnerN(1)) + " · " + L.groupDuoIdle(L.groupPartnerN(2)))
    }

    /// Who can write is read off the permissions the Mac will pass: two
    /// writers on one directory is what the strip warns about (never blocks).
    func testWhoCanWriteIsReadOffThePermissions() {
        var g = try! JSONDecoder().decode(ChatGroup.self, from: Data(duoJSON().utf8))
        XCTAssertEqual(g.writers, ["p"], "acceptEdits writes; read-only does not")
        g.members[0].sandbox = "workspace-write"
        XCTAssertEqual(g.writers, ["p", "m0"])
        g.primary.perm = "plan"
        XCTAssertEqual(g.writers, ["m0"])
        XCTAssertEqual(GroupVia.label("critique"), L.groupViaCritique())
        XCTAssertTrue(GroupVia.isInjected("synth") && GroupVia.isInjected("review"))
        XCTAssertFalse(GroupVia.isInjected("human") || GroupVia.isInjected(nil), "the person's own words stay a bubble")
    }

    func testCreatePayloadCarriesThePrimaryAsConfiguredAndANewPartnerReadOnly() {
        var p = TestFactory.profile()
        p.backend = .claude; p.permissionMode = "acceptEdits"; p.model = "claude-opus-5"; p.effort = "high"
        let pay = GroupCreateSheet.payload(primarySession: "sess-P", profile: p, autoSynth: false,
                                           partnerBackend: .codex, partnerSession: "")
        let primary = pay["primary"] as! [String: Any]
        let member = (pay["members"] as! [[String: Any]])[0]
        XCTAssertEqual(primary["perm"] as? String, "plan", "头脑风暴: the primary starts read-only too; member settings can open it")
        XCTAssertEqual(primary["model"] as? String, "claude-opus-5")
        let duo = GroupCreateSheet.payload(primarySession: "sess-P", profile: p, autoSynth: true,
                                           partnerBackend: .codex, partnerSession: "", mode: "duo")
        XCTAssertEqual(duo["mode"] as? String, "duo")
        XCTAssertEqual((duo["primary"] as! [String: Any])["perm"] as? String, "acceptEdits",
                       "双窗: the primary keeps its own permissions — the one writer by default")
        XCTAssertEqual(((duo["members"] as! [[String: Any]])[0])["sandbox"] as? String, "read-only")
        XCTAssertEqual(primary["effort"] as? String, "high")
        XCTAssertEqual(member["sandbox"] as? String, "read-only", "a new partner starts read-only")
        XCTAssertEqual(pay["autoSynth"] as? Bool, false)
        let existing = GroupCreateSheet.payload(primarySession: "sess-P", profile: p, autoSynth: true,
                                                partnerBackend: .claude, partnerSession: "sess-X")
        let m2 = (existing["members"] as! [[String: Any]])[0]
        XCTAssertNil(m2["perm"], "an existing conversation keeps its own settings")
        XCTAssertEqual(m2["session"] as? String, "sess-X")
        let watch = GroupCreateSheet.payload(primarySession: "sess-P", profile: p, autoSynth: true,
                                             partnerBackend: .codex, partnerSession: "", mode: "watch")
        XCTAssertEqual(watch["mode"] as? String, "watch")
        XCTAssertEqual(watch["autoSynth"] as? Bool, false, "a watcher never synthesises")
        var ask = p; ask.permissionMode = "default"
        let fixed = GroupCreateSheet.payload(primarySession: "sess-P", profile: ask, autoSynth: true,
                                             partnerBackend: .codex, partnerSession: "", mode: "watch")
        XCTAssertEqual((fixed["primary"] as! [String: Any])["perm"] as? String, "acceptEdits",
                       "a detached run cannot ask: an ask-tier primary starts as acceptEdits in watch mode")
    }
}
