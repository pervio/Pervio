import XCTest
@testable import Pervio

/// `pervio-chat engines` on connect: what the Mac has, and what the phone does
/// with it. Pins: the answer parses out of a noisy stdout and junk is nil; a
/// profile flips to the engine that IS installed and never to one that is not;
/// the probe is recorded per server and survives a relaunch; the store asks
/// exactly one command.
@MainActor
final class EngineProbeTests: XCTestCase {
    private let suiteName = "EngineProbeTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let codexOnly = #"{"claude": "", "codex": "/opt/homebrew/bin/codex", "tmux": "/opt/homebrew/bin/tmux"}"#

    func testParsesOutOfANoisyStdoutAndRejectsJunk() {
        let p = EngineProbe.parse("Last login: Tue\n" + codexOnly + "\n")
        XCTAssertEqual(p?.has(.claude), false)
        XCTAssertEqual(p?.has(.codex), true)
        XCTAssertEqual(p?.hasTmux, true)
        XCTAssertNil(EngineProbe.parse("pervio-chat: working dir does not exist: engines"),
                     "an older server answers the verb with its usage error — not a probe")
        XCTAssertNil(EngineProbe.parse(""))
    }

    func testCaptionReadsLikeTheRow() {
        XCTAssertEqual(EngineProbe.parse(codexOnly)?.caption, "claude ✗ · codex ✓ · cursor ✗ · tmux ✓")
    }

    func testPrefersTheInstalledEngineAndNeverAMissingOne() {
        let cx = EngineProbe.parse(codexOnly)!
        XCTAssertEqual(cx.preferredBackend(over: .claude), .codex, "codex-only Mac: a Claude default flips")
        XCTAssertNil(cx.preferredBackend(over: .codex), "already on the installed one: nothing to do")
        let both = EngineProbe(claude: "/a/claude", codex: "/b/codex", tmux: "")
        XCTAssertNil(both.preferredBackend(over: .claude))
        XCTAssertNil(both.preferredBackend(over: .codex))
        let none = EngineProbe()
        XCTAssertNil(none.preferredBackend(over: .claude), "neither installed: leave the profile alone")
    }

    func testRefreshAsksOneCommandRecordsPerServerAndSurvivesRelaunch() async {
        let fake = FakeSSH()
        fake.script("pervio-chat engines", codexOnly)
        let profile = TestFactory.profile()
        let store = EngineStore(defaults: defaults)
        let got = await store.refresh(profile: profile, secret: "s", ssh: fake)
        XCTAssertEqual(got?.has(.codex), true)
        XCTAssertEqual(fake.commandCalls(containing: "engines").count, 1)
        XCTAssertTrue(fake.commandCalls(containing: "engines")[0].hasSuffix("/pervio-chat engines"))
        XCTAssertEqual(store.probe(for: profile)?.caption, "claude ✗ · codex ✓ · cursor ✗ · tmux ✓")

        let relaunched = EngineStore(defaults: defaults)
        XCTAssertEqual(relaunched.probe(for: profile)?.has(.codex), true, "cached per phone")

        // A server too old for the verb changes nothing.
        fake.script("pervio-chat engines", "pervio-chat: working dir does not exist: engines")
        let again = await store.refresh(profile: profile, secret: "s", ssh: fake)
        XCTAssertNil(again)
        XCTAssertEqual(store.probe(for: profile)?.has(.codex), true, "last good record stays")
    }
}

/// Cursor + the provider roster on the probe, and the wire flags they turn into.
@MainActor
final class EngineProviderTests: XCTestCase {
    private let probeJSON = #"""
    {"claude": "/a/claude", "codex": "", "cursor": "/Users/me/.local/bin/agent", "tmux": "/opt/homebrew/bin/tmux",
     "providers": [{"name": "glm", "engine": "claude", "label": "智谱 GLM", "baseUrl": "https://open.bigmodel.cn/api/anthropic",
                    "models": ["glm-5", "glm-5-air"], "defaultModel": "glm-5", "hasKey": true, "source": "pervio", "wireApi": ""},
                   {"name": "codex:deepseek", "engine": "codex", "label": "DeepSeek", "baseUrl": "https://api.deepseek.com/v1",
                    "models": [], "defaultModel": "", "hasKey": false, "source": "codex-config", "wireApi": "chat"}]}
    """#

    /// A Cursor API key on the Mac is the probe's word (older servers send no
    /// such key: false); the keychain failure line gets the hint, nothing else does.
    func testProbeCarriesTheCursorKeyAndTheKeychainFailureGetsItsHint() {
        let with = EngineProbe.parse(#"{"claude": "", "codex": "", "cursor": "/x/agent", "tmux": "", "cursorKey": true}"#)
        XCTAssertEqual(with?.cursorKey, true)
        XCTAssertEqual(with?.cursorLogin, false)
        XCTAssertEqual(EngineProbe.parse(#"{"claude": "", "codex": "", "cursor": "/x/agent", "tmux": "", "cursorLogin": true}"#)?.cursorLogin, true)
        XCTAssertEqual(EngineProbe.parse(probeJSON)?.cursorKey, false, "an older server's answer has no key field")
        XCTAssertEqual(EngineProbe.parse(probeJSON)?.cursorLogin, false)
        XCTAssertEqual(ChatStore.failureHint("Run security unlock-keychain and try again"), L.cursorKeychainHint())
        // Codex's writer lock reads as the takeover hint since 2026-11-11 (a living run's refusal lands as a result, with no other place to say it).
        XCTAssertEqual(ChatStore.failureHint("Error: thread X already has an active writer"), L.takeoverHint())
        XCTAssertNil(ChatStore.failureHint(""))
    }

    func testProbeCarriesCursorAndTheRosterAndTheOldShapeStillDecodes() {
        let p = EngineProbe.parse(probeJSON)
        XCTAssertEqual(p?.has(.cursor), true)
        XCTAssertEqual(p?.has(.codex), false)
        XCTAssertEqual(p?.providers.count, 2)
        XCTAssertEqual(p?.providers(for: .claude).map(\.name), ["glm"])
        XCTAssertEqual(p?.providers(for: .cursor), [], "Cursor has no providers")
        XCTAssertEqual(p?.provider(named: "glm")?.defaultModel, "glm-5")
        XCTAssertEqual(p?.caption, "claude ✓ · codex ✗ · cursor ✓ · tmux ✓")
        let old = EngineProbe.parse(#"{"claude": "", "codex": "/x/codex", "tmux": ""}"#)
        XCTAssertEqual(old?.has(.codex), true, "a record without cursor/providers (older server or cache) still decodes")
        XCTAssertEqual(old?.providers, [])
        XCTAssertEqual(old?.preferredBackend(over: .cursor), .codex, "a missing engine yields to the first installed one")
    }

    func testWireFlags_cursorAndProvider() {
        let svc = SSHService()
        var p = TestFactory.profile()
        p.backend = .cursor; p.cursorModel = "gpt-5.3-codex"; p.effort = "high"; p.permissionMode = "plan"; p.provider = "glm"
        let cmd = svc.buildChatCommand(profile: p, prompt: "hi", resume: nil, approveSid: nil, pervioContext: false)
        XCTAssertTrue(cmd.contains("--backend cursor"), cmd)
        XCTAssertTrue(cmd.contains("--model 'gpt-5.3-codex'"), "Cursor's own model namespace rides --model: \(cmd)")
        XCTAssertFalse(cmd.contains("--effort"), "Cursor has no effort knob: \(cmd)")
        XCTAssertFalse(cmd.contains("--sandbox"), cmd)
        XCTAssertFalse(cmd.contains("--provider"), "Cursor ignores providers even when one is set: \(cmd)")
        XCTAssertTrue(cmd.contains("--perm 'plan'"), cmd)

        var c = TestFactory.profile()
        c.backend = .claude; c.provider = "glm"; c.model = "glm-5"
        let chat = svc.buildChatCommand(profile: c, prompt: "hi", resume: nil, approveSid: nil, pervioContext: false)
        XCTAssertTrue(chat.contains("--provider 'glm'") && chat.contains("--model 'glm-5'"), chat)
        let run = svc.buildStartRunCommand(profile: c, prompt: "hi", resume: nil, pervioContext: false)
        XCTAssertTrue(run.contains("--provider 'glm'"), "a detached run carries the provider too: \(run)")

        var x = TestFactory.profile()
        x.backend = .codex; x.provider = "codex:deepseek"; x.codexModel = "deepseek-chat"
        let cx = svc.buildChatCommand(profile: x, prompt: "hi", resume: nil, approveSid: nil, pervioContext: false)
        XCTAssertTrue(cx.contains("--backend codex") && cx.contains("--provider 'codex:deepseek'") && cx.contains("--model 'deepseek-chat'"), cx)

        var plain = TestFactory.profile()
        plain.backend = .claude; plain.provider = ""
        let pl = svc.buildChatCommand(profile: plain, prompt: "hi", resume: nil, approveSid: nil, pervioContext: false)
        XCTAssertFalse(pl.contains("--provider"), "no provider = no flag (the engine's own account): \(pl)")
    }

    func testProfileAndConvParamsRoundTripTheNewFields() throws {
        var p = TestFactory.profile()
        p.backend = .cursor; p.cursorModel = "composer-2.5"; p.provider = "glm"
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(ServerProfile.self, from: data)
        XCTAssertEqual(back.backend, .cursor)
        XCTAssertEqual(back.cursorModel, "composer-2.5")
        XCTAssertEqual(back.provider, "glm")
        XCTAssertEqual(back.activeModel, "composer-2.5")
        var q = TestFactory.profile()
        ConvParams(p).apply(to: &q)
        XCTAssertEqual(q.cursorModel, "composer-2.5")
        XCTAssertEqual(q.provider, "glm")
        // params saved before these fields existed decode with them absent
        let old = try JSONDecoder().decode(ConvParams.self, from: Data(#"{"model":"opus","effort":"","runMode":false,"permissionMode":"auto"}"#.utf8))
        XCTAssertNil(old.provider)
        XCTAssertNil(old.cursorModel)
    }

    func testCursorRunModesMapOntoThePermissionField() {
        XCTAssertEqual(CursorRunMode.named("plan").id, "plan")
        XCTAssertEqual(CursorRunMode.named("bypassPermissions").isDangerous, true)
        XCTAssertEqual(CursorRunMode.named("default").id, "acceptEdits", "any other Claude mode lands on Cursor's default")
        XCTAssertEqual(CursorRunMode.named("auto").id, "acceptEdits")
    }
}

/// The vendor presets ride on the probe; a preset knows its regions' URLs.
final class ProviderUrlShapeTests: XCTestCase {
    func testGuessesTheShapeFromThePathOnly() {
        XCTAssertEqual(ProviderUrlShape.guess("https://open.bigmodel.cn/api/anthropic"), .anthropic)
        XCTAssertEqual(ProviderUrlShape.guess("https://open.bigmodel.cn/api/paas/v4"), .openai, "the GLM mix-up the first tester hit")
        XCTAssertEqual(ProviderUrlShape.guess("https://api.moonshot.cn/v1"), .openai)
        XCTAssertEqual(ProviderUrlShape.guess("https://api.deepseek.com/anthropic"), .anthropic)
        XCTAssertEqual(ProviderUrlShape.guess("https://dashscope.aliyuncs.com/api/v2/apps/claude-code-proxy"), .anthropic)
        XCTAssertEqual(ProviderUrlShape.guess("https://dashscope.aliyuncs.com/compatible-mode/v1"), .openai)
        XCTAssertEqual(ProviderUrlShape.guess("https://openrouter.ai/api/v1"), .openai)
        XCTAssertNil(ProviderUrlShape.guess("https://openrouter.ai/api"), "a bare /api says nothing — no warning")
        XCTAssertNil(ProviderUrlShape.guess("https://anthropic-proxy.example.com"), "the host never counts, only the path")
        XCTAssertNil(ProviderUrlShape.guess("not a url"))
    }
}

final class ProviderPresetTests: XCTestCase {
    func testPresetsDecodeAndResolveUrlsPerEngineAndRegion() {
        let json = #"""
        {"claude": "/a", "codex": "", "tmux": "", "providers": [],
         "presets": [{"id": "glm", "label": "智谱 GLM", "note": "", "docs": "https://d", "models": ["glm-5.3", "glm-5.2"],
                      "defaultModel": "glm-5.3", "wireApi": "chat",
                      "regions": [{"id": "cn", "label": "中国区", "claudeUrl": "https://open.bigmodel.cn/api/anthropic",
                                   "codexUrl": "https://open.bigmodel.cn/api/paas/v4", "modelsUrl": "https://open.bigmodel.cn/api/paas/v4/models"},
                                  {"id": "intl", "label": "国际版", "claudeUrl": "https://api.z.ai/api/anthropic",
                                   "codexUrl": "https://api.z.ai/api/paas/v4", "modelsUrl": "https://api.z.ai/api/paas/v4/models"}]},
                     {"id": "deepseek", "label": "DeepSeek", "models": ["deepseek-v4-pro"], "defaultModel": "deepseek-v4-pro",
                      "regions": [{"id": "global", "label": "", "claudeUrl": "https://api.deepseek.com/anthropic",
                                   "codexUrl": "https://api.deepseek.com/v1", "modelsUrl": "https://api.deepseek.com/v1/models"}]}]}
        """#
        let probe = EngineProbe.parse(json)
        XCTAssertEqual(probe?.presets.map(\.id), ["glm", "deepseek"])
        let glm = probe!.presets[0], ds = probe!.presets[1]
        XCTAssertTrue(glm.needsRegion)
        XCTAssertNil(glm.url(for: .claude, region: ""), "two regions, none picked → no URL (nothing is assumed)")
        XCTAssertEqual(glm.url(for: .claude, region: "intl"), "https://api.z.ai/api/anthropic")
        XCTAssertEqual(glm.url(for: .codex, region: "cn"), "https://open.bigmodel.cn/api/paas/v4")
        XCTAssertFalse(ds.needsRegion)
        XCTAssertEqual(ds.url(for: .claude, region: ""), "https://api.deepseek.com/anthropic", "a single region needs no pick")
        let old = EngineProbe.parse(#"{"claude": "/a", "codex": "", "tmux": ""}"#)
        XCTAssertEqual(old?.presets, [], "a probe without presets still decodes")
    }
}

/// A new conversation must not be titled by the one just left: the badge takes
/// the engine's init-time model name, and reset() has to drop it (a Cursor chat
/// opened after a GLM one read "Glm 5.3" while its runs went out as
/// grok-4.7-high, 2026-10-16).
@MainActor
final class NewConversationTitleTests: XCTestCase {
    func testResetDropsTheLeftConversationsModelName() async {
        let store = ChatStore(profile: TestFactory.profile(), secret: "s", resumeSessionId: nil, ssh: FakeSSH())
        store.modelName = "Glm 5.3"
        store.reset()
        XCTAssertEqual(store.modelName, "", "the badge must fall back to the configured model, not the old name")
        XCTAssertNil(store.usage)
    }
}
