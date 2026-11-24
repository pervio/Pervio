import XCTest
@testable import Pervio

/// R6: 「从这里重新说」 on the FIRST message is really "start this conversation
/// over" — a fresh chat with the message ready to re-edit. What must not vanish
/// on the way is the Pervio chip the user lit by hand: it's an explicit choice
/// about THIS conversation, not something the entry point gets to re-decide.
@MainActor
final class PervioChipTests: XCTestCase {

    private let oldSid = "sess-before-restate"
    private let newSid = "sess-after-restate"

    private func clearStickyKeys() {
        for s in [oldSid, newSid] {
            UserDefaults.standard.removeObject(forKey: TestFactory.key(.workflows, s))
        }
    }
    override func setUp() async throws { clearStickyKeys() }
    override func tearDown() async throws { clearStickyKeys() }

    func testR6_restatingFromTheFirstMessageKeepsTheManuallyLitPervioChip() async {
        let fake = FakeSSH()
        fake.script("pervio-sessions usage", "{}")
        fake.chatEvents([.initialized(sessionId: newSid, model: nil),
                         .result(text: "ok", sessionId: newSid, costUSD: nil,
                                 isError: false, contextWindow: nil)])

        // A plain entry point (SessionsView): the birth seed is OFF.
        let store = ChatStore(profile: TestFactory.profile(), secret: "secret",
                              resumeSessionId: oldSid, pervioContext: false, ssh: fake)
        var first = ChatMessage.user("第一句:帮我看看这个工作流")
        first.serverUuid = "uuid-first"
        store.messages = [first]
        await store.connect()

        store.togglePervioContext()          // the user lights the chip by hand
        XCTAssertTrue(store.pervioContext, "precondition: the chip is on")

        let switched = await store.restateFork(beforeUuid: "uuid-first")
        XCTAssertTrue(switched, "precondition: rewinding from the first message restarts the chat")
        XCTAssertNil(store.sessionId, "precondition: the fresh chat has no id yet")
        XCTAssertTrue(store.pervioContext, "precondition: the chip survived the restart itself")

        store.submit("第一句(重说):帮我看看这个工作流")   // the first turn mints a new id
        await TestFactory.settle()
        XCTAssertEqual(store.sessionId, newSid, "precondition: the new id was adopted")

        XCTAssertTrue(store.pervioContext,
                      "adopting the restated conversation's id re-derived the chip from "
                      + "the entry point's seed and dropped the user's explicit choice")

        store.submit("第二句")               // the next turn is the one that shows it
        await TestFactory.settle()
        XCTAssertEqual(fake.chatPervioFlags.last, true,
                       "the turn after the restate went out WITHOUT --pervio-context")
    }
}
