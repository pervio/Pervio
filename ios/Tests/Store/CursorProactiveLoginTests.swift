import XCTest
@testable import Pervio

/// Cursor with no login the Mac can use is told BEFORE the first turn (2026-10-19):
/// the connect-time probe knows (no API key, no file-store login), so the send
/// parks the text and offers the one-tap login instead of failing first.
@MainActor
final class CursorProactiveLoginTests: XCTestCase {
    func testASendWithNoUsableLoginParksTheTextAndOffersLogin() async throws {
        let fake = FakeSSH()
        var profile = TestFactory.profile(); profile.backend = .cursor
        let noLogin = EngineProbe(claude: "/x/claude", codex: "", cursor: "/x/agent", tmux: "", cursorKey: false, cursorLogin: false)
        EngineStore.shared.record(noLogin, for: profile)
        defer { EngineStore.shared.record(EngineProbe(claude: "/x/claude", codex: "", cursor: "/x/agent", tmux: "", cursorKey: true, cursorLogin: true), for: profile) }
        let store = ChatStore(profile: profile, secret: "secret", resumeSessionId: nil, ssh: fake)
        await store.connect()
        await store.send("hello cursor")
        XCTAssertEqual(store.cursorLoginOffer?.text, "hello cursor", "the turn is parked behind the login offer")
        XCTAssertFalse(fake.calls.contains("chatStream"), "nothing was sent to a Cursor that cannot answer")
        XCTAssertFalse(store.isBusy)
        // Once the Mac can read a login (an API key, say), the same send goes through.
        EngineStore.shared.record(EngineProbe(claude: "/x/claude", codex: "", cursor: "/x/agent", tmux: "", cursorKey: true, cursorLogin: false), for: profile)
        store.cursorLoginOffer = nil
        await store.send("hello again")
        XCTAssertTrue(fake.calls.contains("chatStream"), "with a key on the Mac the turn is sent")
    }
}
