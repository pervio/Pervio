import XCTest
@testable import Pervio

/// R5: each conversation remembers its own model / effort / run-mode /
/// permission. Tapping another conversation in the drawer must not carry the
/// knobs of the one you left over the top of the one you opened — the session id
/// changes first, and the knobs on screen are still the old conversation's.
@MainActor
final class ConversationParamsTests: XCTestCase {

    private let sidA = "sess-params-A"
    private let sidB = "sess-params-B"

    private func freshAppStore() -> AppStore {
        let app = AppStore()
        app.sessionParams = [:]
        for sid in [sidA, sidB] { app.removeParams(for: sid, on: TestFactory.profile()) }
        return app
    }

    private func params(model: String, effort: String, perm: String,
                        runMode: Bool) -> ConvParams {
        var p = TestFactory.profile()
        p.model = model; p.effort = effort; p.permissionMode = perm; p.runMode = runMode
        return ConvParams(p)
    }

    func testR5_openingAnotherConversationDoesNotOverwriteItsSavedParams() async {
        let fake = FakeSSH()
        fake.script("pervio-sessions usage", "{}")
        fake.script("pervio-sessions context", "{}")
        fake.script("transcript", TestFactory.transcriptJSON([("user", "B: hi")]))

        let app = freshAppStore()
        // B was configured (and left) as a careful, cheap, plan-mode conversation.
        let bParams = params(model: "haiku", effort: "low", perm: "plan", runMode: false)
        app.saveParams(bParams, for: sidB, on: TestFactory.profile())

        // A is the loud one we're currently in.
        var profileA = TestFactory.profile()
        profileA.model = "opus"; profileA.effort = "xhigh"
        profileA.permissionMode = "bypassPermissions"; profileA.runMode = true
        let store = ChatStore(profile: profileA, secret: "secret",
                              resumeSessionId: sidA, ssh: fake)
        await store.connect()

        await store.open(sessionId: sidB)      // drawer tap
        app.chatDidChangeSession(store)        // ChatView's onChange(of: sessionId)

        XCTAssertEqual(app.params(for: sidB, on: TestFactory.profile()), bParams,
                       "opening conversation B saved the knobs of conversation A "
                       + "under B's id — B's own model/permission are gone")
        XCTAssertEqual(store.profile.model, "haiku",
                       "the opened conversation should come back with its own knobs")
        XCTAssertEqual(store.profile.permissionMode, "plan")
        XCTAssertTrue(store.profile.runMode,
                      "Chat/Run is the person's setting, not B's: opening B must not flip the mode")
    }

    /// Chat/Run follows the person, per server: the toggle is written to the
    /// server entry, a conversation's saved knobs never override it (a Chat
    /// user was flipped back to Run on every open, 2026-10-16).
    func testChatRunIsThePersonsSettingNotTheConversations() {
        let app = freshAppStore()
        var server = TestFactory.profile()        // the fixture is chat mode
        server.id = UUID()
        app.profiles = [server]
        app.setRunMode(true, server: server.id)
        XCTAssertTrue(app.profiles[0].runMode, "the toggle lands on the server entry")
        app.setRunMode(false, server: server.id)
        XCTAssertFalse(app.profiles[0].runMode)

        var p = server
        p.runMode = false
        params(model: "haiku", effort: "low", perm: "plan", runMode: true).apply(to: &p)
        XCTAssertFalse(p.runMode, "a conversation saved in Run must not switch a Chat user to Run")
        XCTAssertEqual(p.model, "haiku", "the other knobs still come back")

        var fresh = server
        fresh.runMode = true
        app.restoreKnobs(into: &fresh, sessionId: nil)   // a brand-new chat on this server
        XCTAssertTrue(fresh.runMode, "a new chat starts from whatever the entry holds — untouched by restore")
    }

    /// Re-entering a conversation (ChatView.onAppear) brings back EVERY saved
    /// knob — the provider and the Cursor model included, not just the Claude
    /// ones. The bug: a conversation on GLM kept "glm-5.3" but lost "glm" on
    /// re-entry, so its next turn asked Anthropic for a GLM model.
    func testR5c_reenteringAConversationRestoresItsProviderAndCursorModel() async {
        let app = freshAppStore()
        var saved = TestFactory.profile()
        saved.model = "glm-5.3"; saved.provider = "glm"; saved.cursorModel = "gpt-5.6"
        saved.codexModel = "gpt-5.6-sol"; saved.permissionMode = "plan"
        app.saveParams(ConvParams(saved), for: sidA, on: TestFactory.profile())

        // Opened from the list: the store starts from the SERVER profile
        // (no provider, the server's default model), with its session id set.
        var server = TestFactory.profile()
        server.model = "claude-opus-5"; server.provider = ""; server.cursorModel = ""
        let store = ChatStore(profile: server, secret: "secret", resumeSessionId: sidA, ssh: FakeSSH())
        app.restoreKnobs(into: &store.profile, sessionId: store.sessionId)   // ChatView.onAppear

        XCTAssertEqual(store.profile.provider, "glm", "the provider must come back with the model")
        XCTAssertEqual(store.profile.model, "glm-5.3")
        XCTAssertEqual(store.profile.cursorModel, "gpt-5.6")
        XCTAssertEqual(store.profile.codexModel, "gpt-5.6-sol")
        XCTAssertEqual(store.profile.permissionMode, "plan")
    }

    /// No saved knobs → the server's own defaults, provider included, never
    /// whatever the store happened to carry.
    func testR5d_aConversationWithoutSavedKnobsTakesTheServersDefaults() async {
        let app = freshAppStore()
        var server = TestFactory.profile()
        server.model = "claude-opus-5"; server.provider = "kimi"; server.permissionMode = "acceptEdits"
        app.profiles = [server]
        var onScreen = server
        onScreen.model = "glm-5.3"; onScreen.provider = "glm"; onScreen.permissionMode = "plan"
        let store = ChatStore(profile: onScreen, secret: "secret", resumeSessionId: "sess-unsaved", ssh: FakeSSH())
        app.restoreKnobs(into: &store.profile, sessionId: store.sessionId)

        XCTAssertEqual(store.profile.provider, "kimi")
        XCTAssertEqual(store.profile.model, "claude-opus-5")
        XCTAssertEqual(store.profile.permissionMode, "acceptEdits")
    }

    func testR5_aNewChatStillSavesItsOwnParamsWhenItLearnsItsId() async {
        let fake = FakeSSH()
        fake.script("pervio-sessions usage", "{}")
        fake.chatEvents([.initialized(sessionId: sidA, model: nil),
                         .result(text: "ok", sessionId: sidA, costUSD: nil,
                                 isError: false, contextWindow: nil)])
        let app = freshAppStore()
        var profile = TestFactory.profile()
        profile.model = "opus"; profile.effort = "xhigh"
        let store = ChatStore(profile: profile, secret: "secret", ssh: fake)
        await store.connect()

        store.submit("first turn")             // the id arrives mid-turn
        await TestFactory.settle()
        app.chatDidChangeSession(store)        // ChatView's onChange(of: sessionId)

        XCTAssertEqual(app.params(for: sidA, on: TestFactory.profile())?.model, "opus",
                       "a chat that just learned its id must still record ITS knobs")
        XCTAssertEqual(app.params(for: sidA, on: TestFactory.profile())?.effort, "xhigh")
    }

    func testR5_aForkInheritsTheParamsOfTheConversationItBranchedFrom() async {
        let fake = FakeSSH()
        fake.script("pervio-sessions usage", "{}")
        fake.script("pervio-sessions context", "{}")
        fake.script("transcript", TestFactory.transcriptJSON([("user", "hi")]))
        fake.forkedSessionId = sidB

        let app = freshAppStore()
        var profileA = TestFactory.profile()
        profileA.model = "opus"; profileA.effort = "xhigh"
        let store = ChatStore(profile: profileA, secret: "secret",
                              resumeSessionId: sidA, ssh: fake)
        var first = ChatMessage.user("第一句")
        first.serverUuid = "uuid-first"
        var second = ChatMessage.user("第二句")
        second.serverUuid = "uuid-second"
        store.messages = [first, second]
        await store.connect()

        _ = await store.restateFork(beforeUuid: "uuid-second")   // 从这里重新说
        app.chatDidChangeSession(store)

        XCTAssertEqual(store.sessionId, sidB)
        XCTAssertEqual(app.params(for: sidB, on: TestFactory.profile())?.model, "opus",
                       "a fork continues THIS conversation — the branch keeps its knobs")
    }
    /// 2026-08-22 user ruling: Run mode is the FACTORY default — long turns
    /// belong in detached runs (visible, reattachable, survive the phone
    /// leaving). The test fixture pins chat mode for path tests; this is the
    /// one place the real default itself is pinned.
    func testRunModeIsTheFactoryDefault() {
        XCTAssertTrue(ServerProfile().runMode,
                      "a fresh profile must default to Run mode")
        XCTAssertFalse(TestFactory.profile().runMode,
                       "the FIXTURE stays chat-mode so path tests mean what they say")
    }

}
