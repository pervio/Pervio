import XCTest
@testable import Pervio

/// A `/model X` typed into the composer switches the conversation's OWN model
/// setting as well as the engine's living process (2026-11-18): the phone
/// starts every process with `--model` from that setting, so a switch made
/// with the command alone used to be lost at the next start — a day on 5.2,
/// then back on 5.1 after a restart.
@MainActor
final class ModelCommandTests: XCTestCase {

    func testTheCommandNamesItsModel() {
        XCTAssertEqual(ChatStore.modelCommandTarget("/model claude-fable-5-2"), "claude-fable-5-2")
        XCTAssertEqual(ChatStore.modelCommandTarget("/model fable[1m]"), "fable[1m]")
        XCTAssertEqual(ChatStore.modelCommandTarget("/MODEL opus"), "opus", "the command is not case-sensitive")
        XCTAssertEqual(ChatStore.modelCommandTarget("  /model   sonnet  "), "sonnet",
                       "spaces around are tolerated (send() trims anyway)")
        XCTAssertNil(ChatStore.modelCommandTarget("/model"), "bare: the engine shows its picker, nothing to persist")
        XCTAssertNil(ChatStore.modelCommandTarget("/model two words"), "a model id has no spaces")
        XCTAssertNil(ChatStore.modelCommandTarget("/models claude-opus-5"))
        XCTAssertNil(ChatStore.modelCommandTarget("please /model opus"))
    }

    func testATypedSwitchIsRememberedByTheConversationAndStillSent() async {
        let fake = FakeSSH()
        fake.script("pervio-sessions usage", "{}")
        fake.chatEvents([.initialized(sessionId: "sess-m", model: "claude-fable-5-2"),
                         .result(text: "Set model to claude-fable-5-2", sessionId: "sess-m",
                                 costUSD: nil, isError: false, contextWindow: nil)])
        var p = TestFactory.profile()
        p.model = "claude-fable-5-1"
        let store = ChatStore(profile: p, secret: "s", resumeSessionId: "sess-m", ssh: fake)
        await store.connect()
        await store.send("/model claude-fable-5-2")
        XCTAssertEqual(store.profile.model, "claude-fable-5-2", "the setting the next process starts from")
        XCTAssertEqual(fake.chatPrompts.last, "/model claude-fable-5-2", "the command still reaches the engine")
    }

    func testOtherMessagesAndOtherEnginesLeaveTheSettingAlone() async {
        let fake = FakeSSH()
        fake.script("pervio-sessions usage", "{}")
        fake.chatEvents([.result(text: "ok", sessionId: "sess-m", costUSD: nil, isError: false, contextWindow: nil)])
        var p = TestFactory.profile()
        p.model = "claude-fable-5-1"
        let store = ChatStore(profile: p, secret: "s", resumeSessionId: "sess-m", ssh: fake)
        await store.connect()
        await store.send("/model")
        XCTAssertEqual(store.profile.model, "claude-fable-5-1")
        await store.send("switch the model to opus please")
        XCTAssertEqual(store.profile.model, "claude-fable-5-1")

        var c = TestFactory.profile()
        c.backend = .codex
        c.model = "claude-fable-5-1"
        let codex = ChatStore(profile: c, secret: "s", resumeSessionId: "sess-c", ssh: fake)
        await codex.connect()
        await codex.send("/model gpt-6.2-sol")
        XCTAssertEqual(codex.profile.model, "claude-fable-5-1", "Codex has its own model field; its /model is not ours to persist")
    }
}
