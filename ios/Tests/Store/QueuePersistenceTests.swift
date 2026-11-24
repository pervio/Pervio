import XCTest
@testable import Pervio

/// R4: a brand-new chat only learns its session id once the first turn starts
/// streaming. A follow-up typed before that has nowhere to be saved — and the
/// queue file is what makes "typed, queued, then the app was killed" survive.
@MainActor
final class QueuePersistenceTests: XCTestCase {

    private let sid = "sess-born-on-first-turn"

    private var queueFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(ConversationState.queueFileName(
                scope: ConversationState.scope(of: TestFactory.profile()), sid: sid))
    }

    override func setUp() async throws {
        if let queueFile { try? FileManager.default.removeItem(at: queueFile) }
    }
    override func tearDown() async throws {
        if let queueFile { try? FileManager.default.removeItem(at: queueFile) }
    }

    func testR4_followUpQueuedBeforeTheFirstSessionIdSurvivesAnAppKill() async {
        let fake = FakeSSH()
        fake.script("pervio-sessions usage", "{}")
        fake.chatEvents([.initialized(sessionId: sid, model: "claude-opus-4-8"),
                         .result(text: "done", sessionId: sid, costUSD: nil,
                                 isError: false, contextWindow: nil)])
        fake.pauseChat(before: 0)      // nothing has streamed back yet — no id
        fake.pauseChat(before: 1)      // …then hold the turn open after the id lands

        let store = ChatStore(profile: TestFactory.profile(), secret: "secret", ssh: fake)
        await store.connect()
        store.submit("build the thing")
        await fake.awaitChatPaused()
        XCTAssertNil(store.sessionId, "precondition: a new chat has no id yet")

        store.submit("and when that's done, deploy it")
        XCTAssertEqual(store.queuedCount, 1, "precondition: the follow-up is queued")

        fake.releaseChat()             // the first turn's init event arrives
        await TestFactory.settle()
        XCTAssertEqual(store.sessionId, sid, "precondition: the id is established now")
        XCTAssertEqual(store.queuedCount, 1, "precondition: the follow-up hasn't fired yet")

        // The app is killed mid-turn. A fresh launch reopens the same conversation
        // (offline, so nothing drains it) and should still find the follow-up.
        let relaunch = FakeSSH()
        relaunch.connectError = FakeSSH.Boom(message: "offline")
        let reopened = ChatStore(profile: TestFactory.profile(), secret: "secret",
                                 resumeSessionId: sid, ssh: relaunch)
        await reopened.start()

        XCTAssertEqual(reopened.queuedCount, 1,
                       "the follow-up queued before the first session id existed was "
                       + "never written to disk, so the app kill lost it")
    }
}
