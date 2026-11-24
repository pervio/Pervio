import XCTest
@testable import Pervio

/// R1 / R3: what the conversation you LEFT is still doing must never land in the
/// one you opened. Both are driven through `FakeSSH`, which holds the server's
/// answer until the test releases it — so the in-flight work of conversation A
/// finishes *after* the store has already switched to B, exactly as it does when
/// a phone on a slow link taps another chat in the drawer.
@MainActor
final class ConversationSwitchTests: XCTestCase {

    private func makeStore(_ fake: FakeSSH, resume: String?) -> ChatStore {
        ChatStore(profile: TestFactory.profile(), secret: "secret",
                  resumeSessionId: resume, ssh: fake)
    }

    /// Scripts every incidental call `start()` makes, so only the transcript
    /// answers are interesting.
    private func scriptBackground(_ fake: FakeSSH) {
        fake.script("pervio-sessions usage", "{}")
        fake.script("pervio-sessions context", "{}")
    }

    func testR1_leftConversationsHistoryDoesNotOverwriteTheOpenedOne() async {
        let fake = FakeSSH()
        scriptBackground(fake)
        fake.script("transcript --dir '/srv/proj' --session 'sess-A'",
                    TestFactory.transcriptJSON([("user", "A: 老会话的问题"),
                                                ("assistant", "A: 老会话的回答")]))
        fake.script("transcript --dir '/srv/proj' --session 'sess-B'",
                    TestFactory.transcriptJSON([("user", "B: 新会话的问题"),
                                                ("assistant", "B: 新会话的回答")]))
        // A's transcript is still travelling when the user taps another chat.
        fake.gate("--session 'sess-A'")

        let store = makeStore(fake, resume: "sess-A")
        let starting = Task { await store.start() }
        await fake.awaitCall("transcript --dir '/srv/proj' --session 'sess-A'")

        await store.open(sessionId: "sess-B")
        XCTAssertEqual(store.messages.map(\.text),
                       ["B: 新会话的问题", "B: 新会话的回答"],
                       "precondition: open() loaded B's transcript")

        fake.release("--session 'sess-A'")
        _ = await starting.value

        XCTAssertEqual(store.sessionId, "sess-B")
        XCTAssertEqual(store.messages.map(\.text),
                       ["B: 新会话的问题", "B: 新会话的回答"],
                       "the conversation you LEFT finished loading and replaced the "
                       + "opened conversation's transcript")
    }

    func testR3_backgroundExportStartedBeforeTheSwitchDoesNotChipTheOpenedChat() async {
        let fake = FakeSSH()
        scriptBackground(fake)
        fake.script("transcript --dir '/srv/proj' --session 'sess-B'",
                    TestFactory.transcriptJSON([("user", "B: hi")]))
        // The 背景 export of a past conversation (picked while still in A).
        fake.script("transcript --dir '/old/proj' --session 'past-1'",
                    TestFactory.transcriptJSON([("user", "过去的问题"),
                                                ("assistant", "过去的回答")]))
        fake.gate("--session 'past-1'")

        let store = makeStore(fake, resume: "sess-A")
        await store.connect()
        let summary = SessionSummary(id: "past-1", preview: "过去的问题",
                                     modified: 0, bytes: 40, backend: .codex)
        store.profile.backend = .codex   // codex takes the same uploads-path route
        store.attachContextAsync(projectPath: "/old/proj", session: summary)
        await fake.awaitCall("--session 'past-1'")

        // The user gives up waiting and opens another conversation.
        await store.open(sessionId: "sess-B")
        XCTAssertTrue(store.attachments.isEmpty, "precondition: open() cleared the chips")

        fake.release("--session 'past-1'")
        await TestFactory.settle()

        XCTAssertTrue(store.attachments.isEmpty,
                      "the 背景 export started in the previous conversation landed as a "
                      + "chip on the conversation the user switched to: "
                      + store.attachments.map(\.name).joined(separator: ", "))
    }
}
