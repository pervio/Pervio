import XCTest
@testable import Pervio

/// The phone's half of logging Cursor in to its file store: the verb's JSON is
/// read tolerantly, the loop opens the link once and polls until the Mac says
/// done, a dead login or a timeout comes back as failed, and the chat parks
/// the turn only for Cursor's keychain refusal.
@MainActor
final class CursorLoginFlowTests: XCTestCase {
    func testParsesTheVerbsJsonOutOfANoisyShell() {
        let s = CursorLoginState.parse("Last login: x\n{\"state\": \"waiting\", \"url\": \"https://cursor.com/loginDeepControl?c=1\", \"account\": \"\", \"error\": \"\", \"login\": false}\n")
        XCTAssertEqual(s?.phase, .waiting)
        XCTAssertEqual(s?.url?.host, "cursor.com")
        XCTAssertEqual(CursorLoginState.parse("{\"state\": \"done\", \"account\": \"a@b\", \"login\": true}")?.account, "a@b")
        XCTAssertNil(CursorLoginState.parse("pervio-provider: unknown command"))
        XCTAssertNil(CursorLoginState.parse("{\"state\": \"odd\"}"))
    }

    func testOpensTheLinkOnceAndPollsUntilDone() async {
        var calls: [String] = []
        var opened: [URL] = []
        let st = await CursorLoginFlow.run(run: { action in
            calls.append(action)
            switch action {
            case "start": return "{\"state\": \"waiting\", \"url\": \"https://cursor.com/x\"}"
            default: return calls.filter { $0 == "status" }.count < 2
                ? "{\"state\": \"waiting\", \"url\": \"https://cursor.com/x\"}"
                : "{\"state\": \"done\", \"account\": \"me@x\", \"login\": true}"
            }
        }, open: { opened.append($0) }, poll: 0.01, timeout: 5)
        XCTAssertEqual(st.phase, .done)
        XCTAssertEqual(st.account, "me@x")
        XCTAssertEqual(opened.map(\.absoluteString), ["https://cursor.com/x"], "the link opens exactly once")
        XCTAssertEqual(calls.first, "start")
        XCTAssertEqual(calls.filter { $0 == "status" }.count, 2)
    }

    func testADeadLoginAndATimeoutComeBackAsFailed() async {
        let dead = await CursorLoginFlow.run(run: { action in
            action == "start" ? "{\"state\": \"waiting\", \"url\": \"https://cursor.com/x\"}" : "{\"state\": \"failed\", \"error\": \"login failed (shim)\"}"
        }, open: { _ in }, poll: 0.01, timeout: 5)
        XCTAssertEqual(dead.phase, .failed)
        XCTAssertEqual(dead.error, "login failed (shim)")

        var cancelled = false
        let late = await CursorLoginFlow.run(run: { action in
            if action == "cancel" { cancelled = true }
            return action == "start" ? "{\"state\": \"waiting\", \"url\": \"https://cursor.com/x\"}" : "{\"state\": \"waiting\"}"
        }, open: { _ in }, poll: 0.01, timeout: 0.05)
        XCTAssertEqual(late.phase, .failed)
        XCTAssertTrue(cancelled, "a timed-out login is cancelled on the Mac")

        let noAgent = await CursorLoginFlow.run(run: { _ in "pervio-provider: cursor-login: cursor agent not found" }, open: { _ in }, poll: 0.01, timeout: 1)
        XCTAssertEqual(noAgent.phase, .failed)
    }

    func testOnlyCursorsKeychainRefusalParksTheTurn() {
        var p = TestFactory.profile(); p.backend = .cursor
        let store = ChatStore(profile: p, secret: "s", resumeSessionId: nil, ssh: FakeSSH())
        XCTAssertFalse(store.offerCursorLoginIfLocked("ActionRequiredError: Free plans can only use Auto", atts: []))
        XCTAssertNil(store.cursorLoginOffer)
        XCTAssertTrue(store.offerCursorLoginIfLocked("Run security unlock-keychain and try again.", atts: []))
        XCTAssertNotNil(store.cursorLoginOffer)
        store.cursorLoginOffer = nil
        XCTAssertTrue(store.offerCursorLoginIfLocked("Error: Authentication required. Please run 'agent login' first, or set CURSOR_API_KEY environment variable.", atts: []),
                      "a Mac that never logged in gets the same one tap")
        XCTAssertNotNil(ChatStore.failureHint("Authentication required. Please run 'agent login' first"))

        var c = TestFactory.profile(); c.backend = .claude
        let other = ChatStore(profile: c, secret: "s", resumeSessionId: nil, ssh: FakeSSH())
        XCTAssertFalse(other.offerCursorLoginIfLocked("Run security unlock-keychain and try again.", atts: []),
                       "another engine's keychain line is not Cursor's login problem")
    }
}
