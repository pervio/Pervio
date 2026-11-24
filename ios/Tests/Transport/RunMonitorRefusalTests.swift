import XCTest
@testable import Pervio

/// The standing poll behind the runs pill asks the Mac every few seconds for as
/// long as a server page is open. Against a Mac that REFUSES this phone (a
/// rejected key or password, a host key that is not the pinned one) that was a
/// credential sent every 15 seconds, with nobody having asked — the pattern an
/// address gets banned for — while the pages themselves had already stopped
/// asking (PageRefresher). The poll now stops at a refusal too, and goes on
/// after a Mac that merely could not be reached. Both met here over the real
/// SSH stack: the sandbox's sshd for the refusals, a dead port for the other.
@MainActor
final class RunMonitorRefusalTests: XCTestCase {

    private func settle(_ seconds: Double, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func monitor(_ profile: ServerProfile, _ secret: String) -> RunMonitor {
        let m = RunMonitor(profile: profile, secret: secret)
        m.pace = (busy: 0.2, idle: 0.2)
        return m
    }

    func testThePollStopsWhenTheMacRefusesTheAccount() async throws {
        let endpoint = try SandboxEndpoint.discover()
        var profile = endpoint.profile
        profile.username = "pervio-no-such-account"
        let m = monitor(profile, endpoint.privateKey)
        m.start()
        XCTAssertTrue(m.isPolling)
        await settle(20) { !m.isPolling }
        XCTAssertFalse(m.isPolling, "an account the Mac rejected is not asked for again every few seconds")
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(m.isPolling, "…and nothing starts it again by itself")
        m.start()                          // a page of this server was opened again
        XCTAssertTrue(m.isPolling, "the next page of this server asks once more")
        await settle(20) { !m.isPolling }
        XCTAssertFalse(m.isPolling)
        m.stop()
    }

    func testThePollStopsWhenTheHostKeyIsNotThePinnedOne() async throws {
        let endpoint = try SandboxEndpoint.discover()
        var profile = endpoint.profile
        profile.pinnedHostKey = SandboxEndpoint.rogueHostKeyLine()
        let m = monitor(profile, endpoint.privateKey)
        m.start()
        await settle(20) { !m.isPolling }
        XCTAssertFalse(m.isPolling, "someone else answering on that address is not offered the connection again and again")
        m.stop()
    }

    /// The red line's way out is the server's settings. A monitor built before
    /// they were fixed carries the old ones for good — matched by the server's
    /// id alone, as it was, it would have been kept, refused again at every
    /// page, and the running row left dead until the app was quit.
    func testAMonitorBuiltBeforeTheSettingsWereFixedIsReplaced() async throws {
        let endpoint = try SandboxEndpoint.discover()
        // ONE saved server throughout (`endpoint.profile` mints a new id at
        // every call): what changes below is its settings, never which server.
        let right = endpoint.profile
        var wrong = right
        wrong.username = "pervio-no-such-account"
        let store = AppStore()
        defer { store.deactivateRuns() }

        store.activateRuns(for: wrong, secret: endpoint.privateKey)
        let first = try XCTUnwrap(store.activeMonitor)
        first.pace = (busy: 0.2, idle: 0.2)
        await settle(20) { !first.isPolling }
        XCTAssertFalse(first.isPolling, "refused: the poll stopped")

        // Another page of the same server, nothing edited: the same monitor, asked once more.
        store.activateRuns(for: wrong, secret: endpoint.privateKey)
        XCTAssertTrue(store.activeMonitor === first)
        XCTAssertTrue(first.isPolling, "opening a page of this server asks again — once")
        await settle(20) { !first.isPolling }
        XCTAssertFalse(first.isPolling)

        // A conversation hands on its own copy of the profile, the working
        // directory replaced by its own (ChatStore): the same server still.
        var inAChat = wrong
        inAChat.projectDir = "~/some/project/of/the/conversation"
        store.activateRuns(for: inAChat, secret: endpoint.privateKey)
        XCTAssertTrue(store.activeMonitor === first, "stepping into a conversation keeps the monitor — replaced, the pill would blank at every step in and out")
        await settle(20) { !first.isPolling }

        // A knob turned in a chat is not a reason for a new poll either.
        var knob = wrong
        knob.model = "sonnet"; knob.effort = "high"; knob.runMode.toggle(); knob.backend = .codex
        store.activateRuns(for: knob, secret: endpoint.privateKey)
        XCTAssertTrue(store.activeMonitor === first, "a model or a mode picked in a conversation keeps the monitor")
        await settle(20) { !first.isPolling }

        // The account corrected in the settings: a monitor of its own, and its poll stays.
        store.activateRuns(for: right, secret: endpoint.privateKey)
        let second = try XCTUnwrap(store.activeMonitor)
        XCTAssertFalse(second === first, "the server as it is saved now gets a monitor of its own")
        XCTAssertFalse(first.isPolling, "…and the old one is stopped")
        second.pace = (busy: 0.2, idle: 0.2)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertTrue(second.isPolling, "with the right account the Mac answers and the poll goes on")

        // So is each of the other things the connection is made of.
        var port = right; port.port = 2
        var pin = right; pin.pinnedHostKey = SandboxEndpoint.rogueHostKeyLine()
        var hop = right; hop.route = [JumpHop()]
        var host = right; host.host = "pervio-no-such-host.invalid"
        for (what, edited) in [("port", port), ("pinned host key", pin), ("route", hop), ("host", host)] {
            XCTAssertFalse(second.serves(edited, secret: endpoint.privateKey), "an edited \(what) is a new connection")
        }
        XCTAssertTrue(second.serves(right, secret: endpoint.privateKey))

        // Another key for the same server is a change too.
        store.activateRuns(for: right, secret: endpoint.privateKey + "\n# replaced")
        XCTAssertFalse(store.activeMonitor === second, "a replaced key is a new connection")
    }

    func testThePollGoesOnWhileTheMacCannotBeReached() async throws {
        let endpoint = try SandboxEndpoint.discover()
        var profile = endpoint.profile
        profile.port = 2                   // nothing listens there
        let m = monitor(profile, endpoint.privateKey)
        m.start()
        try? await Task.sleep(nanoseconds: 2_000_000_000)      // several polls' worth at this pace
        XCTAssertTrue(m.isPolling, "a Mac that is asleep or off the network comes back: the poll must still be there when it does")
        m.stop()
        XCTAssertFalse(m.isPolling)
    }
}
