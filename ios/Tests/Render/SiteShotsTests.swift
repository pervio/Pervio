import XCTest
import SwiftUI
import UIKit
@testable import Pervio

/// The screens the website, the README and the App Store listing show — the
/// REAL pages (ChatView and friends, hosted full-screen in the simulator over
/// a scripted Mac) with a staged conversation, photographed by `simctl` from
/// outside so the status bar and the home indicator are the system's own.
///
/// Not a test: it asserts nothing and is skipped unless asked for. To take the
/// pictures, `scripts/site-shots.sh` writes an output directory into
/// `Tests/Fixtures/snapshots/.shots`, runs this class on a 6.9" simulator and
/// answers each `<name>.ready` this file drops there with a screenshot named
/// `<name>.png`. Every scene is staged in Chinese and in English.
@MainActor
final class SiteShotsTests: XCTestCase {
    private var window: UIWindow?
    private var outDir: URL!
    private let langKey = "pervio.promptLanguage"
    private var savedLang: Any?

    override func setUpWithError() throws {
        let marker = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/snapshots/.shots")
        guard let line = try? String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            throw XCTSkip("site shots are staged on demand (scripts/site-shots.sh)")
        }
        outDir = URL(fileURLWithPath: line)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        savedLang = UserDefaults.standard.object(forKey: langKey)
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        if let savedLang { UserDefaults.standard.set(savedLang, forKey: langKey) }
        else { UserDefaults.standard.removeObject(forKey: langKey) }
        super.tearDown()
    }

    // MARK: - staging

    private func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func host<V: View>(_ view: V) {
        window?.isHidden = true
        let host = UIHostingController(rootView: view.environmentObject(AppStore()))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        w.overrideUserInterfaceStyle = .dark
        w.rootViewController = host
        w.makeKeyAndVisible()
        window = w
        pump(0.5)
    }

    /// Ask the script outside for a photograph of the screen as it is now, and
    /// wait until it has been taken.
    private func shoot(_ name: String) {
        pump(0.8)
        let ready = outDir.appendingPathComponent(name + ".ready")
        let png = outDir.appendingPathComponent(name + ".png")
        try? FileManager.default.removeItem(at: png)
        FileManager.default.createFile(atPath: ready.path, contents: Data())
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !FileManager.default.fileExists(atPath: png.path) { pump(0.1) }
        try? FileManager.default.removeItem(at: ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), "no photograph of \(name) — is scripts/site-shots.sh running?")
    }

    private func profile(run: Bool) -> ServerProfile {
        var p = ServerProfile()
        p.name = "mac-mini"; p.host = "mac-mini"; p.username = "me"
        p.projectDir = "/Users/me/code/shop-api"
        p.pinnedHostKey = "ssh-ed25519 AAAA"
        p.model = "claude-fable-5-2"
        p.runMode = run
        return p
    }

    // MARK: - the conversation on stage

    private struct Words {
        let ask1, think1, found, done, ask2, committed: String
        let ask3, merged, bgTask, interject, changelog: String
    }

    private func words(_ lang: PromptLanguage) -> Words {
        lang == .chinese
        ? Words(ask1: "登录接口偶尔返回 500，帮我查查是哪里的问题",
                think1: "先看 session 刷新的路径，再跑一遍 auth 的测试。",
                found: "找到了。`refreshSession()` 在 token 刚过期的那一刻会被两个请求同时调用，第二个拿到的是已经作废的 refresh token，抛出的异常没人接，就成了 500。\n\n**修法**：按用户加一把锁，第二个请求等第一个的结果。",
                done: "改好了，`auth` 的 42 个测试全部通过，还新加了一个并发刷新的用例。要我提交吗？",
                ask2: "提交吧，说明里写清原因",
                committed: "已提交 `3f2a91c`：串行化 session 刷新，避免并发使用已作废的 refresh token。",
                ask3: "合到 release 分支，再跑一遍全量测试",
                merged: "已经合到 `release`。全量测试要十来分钟，我放到后台跑，跑完告诉你。",
                bgTask: "npm test（全量）",
                interject: "顺便把 CHANGELOG 也更新一下",
                changelog: "好，`CHANGELOG.md` 已补上这条修复。测试还在跑，目前 318 个通过。")
        : Words(ask1: "The login endpoint returns a 500 every now and then. Can you find out why?",
                think1: "Trace the session refresh path first, then run the auth tests.",
                found: "Found it. `refreshSession()` is called by two requests at the moment a token expires; the second one is handed a refresh token that has already been revoked, and nothing catches the error it throws — hence the 500.\n\n**Fix**: a per-user lock, so the second request waits for the first one's result.",
                done: "Done. All 42 `auth` tests pass, plus a new one for the concurrent refresh. Shall I commit?",
                ask2: "Commit it, and put the cause in the message",
                committed: "Committed as `3f2a91c`: serialize session refresh so a revoked refresh token is never used twice.",
                ask3: "Merge it into release and run the full test suite",
                merged: "Merged into `release`. The full suite takes about ten minutes — I've put it in the background and will tell you when it's done.",
                bgTask: "npm test (full suite)",
                interject: "Update the CHANGELOG while you're at it",
                changelog: "Done — `CHANGELOG.md` now has this fix. Tests still running, 318 passed so far.")
    }

    private func transcript(_ w: Words) -> String {
        func tool(_ v: String, _ name: String, _ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var d: [String: Any] = ["t": "tool", "v": v, "name": name, "id": id]
            for (k, x) in extra { d[k] = x }
            return d
        }
        let file = "/Users/me/code/shop-api/src/auth/session.ts"
        let rows: [[String: Any]] = [
            ["role": "user", "text": w.ask1, "tools": []],
            ["role": "assistant", "text": w.found + "\n\n" + w.done, "tools": [], "thinking": w.think1,
             "blocks": [
                ["t": "thinking", "v": w.think1],
                tool("Grep refreshSession", "Grep", "toolu_a1"),
                tool("Read .../auth/session.ts", "Read", "toolu_a2", ["filePath": file]),
                tool("Bash npm test -- auth", "Bash", "toolu_a3", ["command": "npm test -- auth"]),
                ["t": "text", "v": w.found],
                tool("Edit .../auth/session.ts", "Edit", "toolu_a4",
                     ["filePath": file, "oldString": "const next = await issue(token)",
                      "newString": "const next = await withUserLock(user.id, () => issue(token))"]),
                tool("Bash npm test -- auth", "Bash", "toolu_a5", ["command": "npm test -- auth"]),
                ["t": "text", "v": w.done],
             ]],
            ["role": "user", "text": w.ask2, "tools": []],
            ["role": "assistant", "text": w.committed, "tools": [],
             "blocks": [
                tool("Bash git commit -am \"fix(auth): serialize session refresh\"", "Bash", "toolu_b1",
                     ["command": "git commit -am \"fix(auth): serialize session refresh\""]),
                ["t": "text", "v": w.committed],
             ]],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
    }

    private func fake(_ w: Words) -> FakeSSH {
        let f = FakeSSH()
        f.script("transcript", transcript(w))
        f.script("context --dir", #"{"used": 61400, "model": "claude-fable-5-2"}"#)
        f.script("pervio-sessions usage", #"{"five_hour": {"utilization": 37.5, "resets_at": "2027-01-01T12:00:00Z"}, "seven_day": {"utilization": 51.0, "resets_at": "2027-01-05T00:00:00Z"}}"#)
        return f
    }

    private func chatPage(_ store: ChatStore, _ p: ServerProfile) -> some View {
        NavigationStack {
            ChatView(profile: p, secret: "s", resumeSessionId: "sess-shots", store: store)
        }
        .tint(Palette.accent)
    }

    private func waitForHistory(_ store: ChatStore) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, store.messages.count < 4 { pump(0.1) }
        pump(1.2)
    }

    // MARK: - a Duet on stage (Watch: one works, the other checks)

    private struct DuetWords {
        let goal, first, feedback, second, summary: String
    }

    private func duetWords(_ lang: PromptLanguage) -> DuetWords {
        lang == .chinese
        ? DuetWords(goal: "给订单列表接口加分页，每页条数可以传参",
                    first: "加好了。`GET /orders` 现在接受 `page` 和 `limit`，默认每页 24 条，`orders` 的 54 个测试全部通过。",
                    feedback: "`limit` 没有上限，传 100000 会把整张表读出来；`page` 传 0 或负数时返回 500。请加上限，并处理越界的页码。\n\n继续",
                    second: "按意见改了：`limit` 上限 100，超过的按 100 算；`page` 小于 1 时按第 1 页处理。新加了 3 个用例，57 个测试全部通过。",
                    summary: "分页已加好：默认每页 24 条，上限 100，越界的页码按第 1 页处理。上一轮指出的两个问题都已修复，57 个测试全部通过。")
        : DuetWords(goal: "Add pagination to the order list endpoint, with the page size as a parameter",
                    first: "Done. `GET /orders` now takes `page` and `limit`, 24 per page by default. All 54 `orders` tests pass.",
                    feedback: "`limit` has no upper bound, so 100000 reads the whole table, and a `page` of 0 or below returns a 500. Cap the limit and handle out-of-range pages.\n\n继续",
                    second: "Fixed as asked: `limit` is capped at 100, and a `page` below 1 is treated as page 1. Three new cases added, and all 57 tests pass.",
                    summary: "Pagination is in: 24 per page by default, capped at 100, and an out-of-range page falls back to page 1. Both problems from the first round are fixed, and all 57 tests pass.")
    }

    /// The primary's conversation as the Mac records a Watch task: the person's
    /// goal, the first attempt, the watcher's feedback handed back by the group
    /// (`via`), the second attempt.
    private func duetTranscript(_ w: DuetWords) -> String {
        func tool(_ v: String, _ name: String, _ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var d: [String: Any] = ["t": "tool", "v": v, "name": name, "id": id]
            for (k, x) in extra { d[k] = x }
            return d
        }
        let file = "/Users/me/code/shop-api/src/orders/list.ts"
        let rows: [[String: Any]] = [
            ["role": "user", "text": w.goal, "tools": [], "via": "human"],
            ["role": "assistant", "text": w.first, "tools": [],
             "blocks": [
                tool("Read .../orders/list.ts", "Read", "toolu_d1", ["filePath": file]),
                tool("Edit .../orders/list.ts", "Edit", "toolu_d2",
                     ["filePath": file, "oldString": "return db.orders.all(userId)",
                      "newString": "return db.orders.page(userId, page, limit)"]),
                tool("Bash npm test -- orders", "Bash", "toolu_d3", ["command": "npm test -- orders"]),
                ["t": "text", "v": w.first],
             ]],
            ["role": "user", "text": w.feedback, "tools": [], "via": "watcher"],
            ["role": "assistant", "text": w.second, "tools": [],
             "blocks": [
                tool("Edit .../orders/list.ts", "Edit", "toolu_d4",
                     ["filePath": file, "oldString": "const limit = Number(q.limit ?? 24)",
                      "newString": "const limit = Math.min(Number(q.limit ?? 24), 100)"]),
                tool("Edit .../orders/list.test.ts", "Edit", "toolu_d5",
                     ["filePath": "/Users/me/code/shop-api/src/orders/list.test.ts", "oldString": "})",
                      "newString": "  it(\"caps limit at 100\", ...)\n})"]),
                tool("Bash npm test -- orders", "Bash", "toolu_d6", ["command": "npm test -- orders"]),
                ["t": "text", "v": w.second],
             ]],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
    }

    /// The group as `pervio-group tick` reports it once the watcher has passed
    /// the second round: a new partner is read-only, an ask-tier primary runs
    /// as acceptEdits (GroupCreateSheet.payload).
    private func duetGroup(_ w: DuetWords) -> String {
        let g: [String: Any] = [
            "id": "d0e7d0e7d0e7", "dir": "/Users/me/code/shop-api", "mode": "watch", "autoSynth": false,
            "maxRounds": 5, "rev": 4,
            "primary": ["session": "sess-shots", "backend": "claude", "perm": "acceptEdits"],
            "members": [["session": "sess-watch", "backend": "codex", "sandbox": "read-only"]],
            "createdAt": 1,
            "round": ["n": 0, "state": "idle", "text": "", "runs": [String: String](), "answers": [String: String](),
                      "synthRun": "", "synth": "", "relayRuns": [String: String]()],
            "watch": ["task": ["n": 1, "goal": w.goal, "round": 2, "state": "passed",
                               "rounds": [["round": 1, "p": "p1", "w": "w1", "verdict": "继续", "text": w.feedback],
                                          ["round": 2, "p": "p2", "w": "w2", "verdict": "通过", "text": w.summary]],
                               "question": "", "decision": NSNull(), "summary": w.summary, "error": "",
                               "startedAt": 1, "endedAt": 2],
                      "history": [Any]()],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: g), as: UTF8.self)
    }

    // MARK: - the scenes

    func testStageTheScreens() {
        for lang in [PromptLanguage.chinese, .english] {
            UserDefaults.standard.set(lang.rawValue, forKey: langKey)
            let w = words(lang)
            let tag = lang == .chinese ? "zh" : "en"

            // 1 · a conversation, read back at rest
            do {
                let p = profile(run: false)
                let store = ChatStore(profile: p, secret: "s", resumeSessionId: "sess-shots", ssh: fake(w))
                host(chatPage(store, p))
                waitForHistory(store)
                shoot("chat-\(tag)")

                // 2 · the agent asks before it pushes
                store.pendingPermission = PendingPermission(
                    sid: "sid", requestId: "req",
                    call: ToolCall(name: "Bash", label: "Bash git push origin release",
                                   command: "git push origin release"))
                pump(1.0)
                shoot("approval-\(tag)")
                store.pendingPermission = nil
                pump(0.6)
            }

            // 3 · a turn still running in Run mode, spoken into, with a background task
            do {
                let p = profile(run: true)
                let f = fake(w)
                f.runTailStaysOpen = true
                f.runEvents = [
                    .initialized(sessionId: "sess-shots", model: "claude-fable-5-2"),
                    .toolUse(ToolCall(name: "Bash", label: "Bash git checkout release && git cherry-pick 3f2a91c",
                                      command: "git checkout release && git cherry-pick 3f2a91c")),
                    .textDelta(w.merged),
                    .toolUse(ToolCall(name: "Bash", label: "Bash npm test", command: "npm test")),
                    .backgroundTasks([BackgroundTask(id: "t1", description: w.bgTask,
                                                     startedAt: Date().addingTimeInterval(-133), kind: .command)]),
                ]
                f.sayEvents = [
                    .toolUse(ToolCall(name: "Edit", label: "Edit CHANGELOG.md",
                                      filePath: "/Users/me/code/shop-api/CHANGELOG.md",
                                      oldString: "## Unreleased", newString: "## Unreleased\n- fix(auth): serialize session refresh")),
                    .textDelta(w.changelog),
                ]
                let store = ChatStore(profile: p, secret: "s", resumeSessionId: "sess-shots", ssh: f)
                host(chatPage(store, p))
                waitForHistory(store)
                store.submit(w.ask3)
                let d1 = Date().addingTimeInterval(8)
                while Date() < d1, !(store.messages.last?.text.contains("release") ?? false) { pump(0.1) }
                pump(0.8)
                store.submit(w.interject)
                let d2 = Date().addingTimeInterval(8)
                while Date() < d2, !(store.messages.last?.text.contains("CHANGELOG") ?? false) { pump(0.1) }
                pump(1.0)
                shoot("running-\(tag)")
                store.stop()
                pump(0.5)
            }

            // 4 · a Duet in Watch mode: the watcher sent the first attempt back,
            // and passed the second
            do {
                let p = profile(run: false)
                let d = duetWords(lang)
                let f = FakeSSH()
                f.script("transcript", duetTranscript(d))
                f.script("context --dir", #"{"used": 48200, "model": "claude-fable-5-2"}"#)
                f.script("pervio-sessions usage", #"{"five_hour": {"utilization": 37.5, "resets_at": "2027-01-01T12:00:00Z"}, "seven_day": {"utilization": 51.0, "resets_at": "2027-01-05T00:00:00Z"}}"#)
                f.script("pervio-group tick", duetGroup(d))
                let g = try! JSONDecoder().decode(ChatGroup.self, from: Data(duetGroup(d).utf8))
                host(NavigationStack { GroupView(profile: p, secret: "s", group: g, ssh: f) }.tint(Palette.accent))
                pump(4.0)
                shoot("duet-\(tag)")
            }

            // 5 · a workflow halfway through, as the run page's Diagram tab draws
            // it. The page around the diagram only talks to a real Mac (its store
            // dials its own connection and starts a Live Activity), so what is
            // hosted here is the diagram view itself, fed the way the page feeds
            // it: the built-in deep-research template's own steps, with the
            // statuses a ledger would report midway (both digs and the merge
            // done, the check running).
            do {
                if let item = WorkflowMarketItem.featured.first(where: { $0.id == "deep-research" }) {
                    let done: Set<String> = ["dig_claude", "dig_codex", "prep", "merge"]
                    let running = item.spec.steps.first { !done.contains($0.id) }?.id ?? ""
                    let nodes = item.spec.steps.map { st in
                        WorkflowGraphNode(id: st.id, backend: st.backend,
                                          status: done.contains(st.id) ? "done" : st.id == running ? "running" : "pending",
                                          dependsOn: st.dependsOn, inputs: workflowOutputRefs(in: st.prompt))
                    }
                    host(NavigationStack {
                        WorkflowGraphView(nodes: nodes)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Palette.bg.ignoresSafeArea())
                            .pervioBar(item.spec.name)
                    }.tint(Palette.accent))
                    pump(1.5)
                    shoot("workflow-\(tag)")
                }
            }
        }
        FileManager.default.createFile(atPath: outDir.appendingPathComponent("ALL.done").path, contents: Data())
    }
}
