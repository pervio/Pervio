import XCTest
@testable import Pervio

/// Claude Code injects a fixed user turn — "Continue from where you left off." —
/// when it drops the channel and reconnects mid-task. The transcript FILE records
/// it as a real user line, so reopening the conversation rendered it as the user's
/// own bubble: the user reads a message they never typed and is scared they sent
/// something they don't remember (it happened once already). It must fold into a
/// centered small system hint ("已断线续跑" / the English variant per the prompt
/// language) — NOT a user bubble — on transcript reload.
///
/// Detection is deliberately generous per the spec: the WHOLE message being the
/// sentence, or the sentence STANDING ALONE as the leading paragraph (a prefix or
/// a following body around it), both fold. The accepted tradeoff: a user who
/// genuinely types exactly this also lands on the system hint — documented in the
/// production comment.
@MainActor
final class ReconnectHintTests: XCTestCase {

    private func loadedStore(_ turns: [(String, String)],
                             language: PromptLanguage = .chinese) async -> ChatStore {
        UserDefaults.standard.set(language.rawValue, forKey: PromptLanguage.defaultsKey)
        let fake = FakeSSH()
        fake.script("--session 'sess-1'", TestFactory.transcriptJSON(turns))
        fake.script("context --dir", #"{"used": 10, "model": "claude-fable-5"}"#)
        fake.script("pervio-sessions usage", "{}")
        let store = ChatStore(profile: TestFactory.profile(), secret: "s",
                              resumeSessionId: "sess-1", ssh: fake)
        await store.start()
        return store
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PromptLanguage.defaultsKey)
        super.tearDown()
    }

    /// The whole user turn IS the fixed sentence → a system hint, never a user bubble.
    func testWholeMessageReconnectFoldsToSystemHint() async {
        let store = await loadedStore([
            ("user", "real question"),
            ("assistant", "an answer"),
            ("user", "Continue from where you left off."),
            ("assistant", "resumed work"),
        ])
        let injected = store.messages[2]
        XCTAssertEqual(injected.role, .system,
                       "the injected reconnect turn must be a centered system hint, not a user bubble")
        XCTAssertFalse(injected.text.contains("Continue from where you left off"),
                       "the hint replaces the raw string, it doesn't echo it: \(injected.text)")
        XCTAssertEqual(injected.text, ChatStore.reconnectHintText(language: .chinese),
                       "the hint reads in the Settings prompt language")
        // The genuine user turn beside it stays a user bubble untouched.
        XCTAssertEqual(store.messages[0].role, .user)
        XCTAssertEqual(store.messages[0].text, "real question")
    }

    /// The sentence leads its own paragraph, with a real body after it (a variant
    /// with the fixed line at the top) → still a hint.
    func testReconnectAsLeadingParagraphFolds() async {
        let store = await loadedStore([
            ("user", "Continue from where you left off.\n\nAlso, add tests."),
            ("assistant", "ok"),
        ])
        XCTAssertEqual(store.messages[0].role, .system,
                       "the fixed sentence leading its own paragraph still marks an auto-resume")
    }

    /// English prompt language → the English hint.
    func testEnglishHintText() async {
        let store = await loadedStore([
            ("user", "Continue from where you left off."),
            ("assistant", "ok"),
        ], language: .english)
        XCTAssertEqual(store.messages[0].role, .system)
        XCTAssertEqual(store.messages[0].text, ChatStore.reconnectHintText(language: .english))
        XCTAssertNotEqual(ChatStore.reconnectHintText(language: .english),
                          ChatStore.reconnectHintText(language: .chinese),
                          "the two languages read differently")
    }

    /// Don't misfire: an ordinary user turn that merely MENTIONS the phrase mid-sentence
    /// stays a user bubble — only the whole message or a leading standalone paragraph folds.
    func testMentionMidSentenceStaysUserBubble() async {
        let store = await loadedStore([
            ("user", "Please continue from where you left off in the previous file, thanks."),
            ("assistant", "ok"),
        ])
        XCTAssertEqual(store.messages[0].role, .user,
                       "an incidental mention inside the user's own sentence is not the injected turn")
    }

    /// The helper itself: unit-level truth table so the recognizer is pinned
    /// independent of the reload plumbing.
    func testRecognizerTruthTable() {
        XCTAssertTrue(ChatStore.isReconnectContinuation("Continue from where you left off."))
        XCTAssertTrue(ChatStore.isReconnectContinuation("  Continue from where you left off.  "),
                      "surrounding whitespace is ignored")
        XCTAssertTrue(ChatStore.isReconnectContinuation("Continue from where you left off.\nmore"),
                      "leading standalone line folds")
        XCTAssertFalse(ChatStore.isReconnectContinuation("please Continue from where you left off."),
                       "a prefix on the SAME line is a real sentence, not the injected turn")
        XCTAssertFalse(ChatStore.isReconnectContinuation("normal message"))
        XCTAssertFalse(ChatStore.isReconnectContinuation(""))
    }
}
