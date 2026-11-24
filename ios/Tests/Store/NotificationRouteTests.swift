import XCTest
@testable import Pervio

/// Tapping a push must land ON ITS SUBJECT — the run's conversation, the
/// workflow's monitor, home for the digest/approval — not merely reopen the app
/// wherever it was. The route rides the `thread-id` the server ALREADY stamps
/// on every push (per-run / per-workflow threads exist for notification
/// grouping), so these pin that thread grammar as a routing contract: rename a
/// thread server-side and this file goes red before the phone quietly falls
/// back to "just open the app".
final class NotificationRouteTests: XCTestCase {

    func testRunThread_routesToThatRun() {
        XCTAssertEqual(NotificationRoute.parse(thread: "pervio-run-a1b2c3d4e5f6"),
                       .run("a1b2c3d4e5f6"))
    }

    func testWorkflowThread_routesToItsMonitor() {
        XCTAssertEqual(NotificationRoute.parse(thread: "pervio-wf-22457d9221da"),
                       .workflow("22457d9221da"))
    }

    func testHomeThreads_digestApprovalDeploy() {
        // These subjects LIVE on the home page (digest strip, recents), so home
        // is their destination, not a fallback.
        XCTAssertEqual(NotificationRoute.parse(thread: "pervio-digest"), .home)
        XCTAssertEqual(NotificationRoute.parse(thread: "pervio-approve"), .home)
        XCTAssertEqual(NotificationRoute.parse(thread: "pervio-deploy"), .home)
    }

    func testUnknownOrEmptyThreads_parseToNil_theTapJustOpensTheApp() {
        XCTAssertNil(NotificationRoute.parse(thread: "somebody-elses-thread"))
        XCTAssertNil(NotificationRoute.parse(thread: ""))
        // A bare prefix with no id names nothing — don't navigate to a ghost.
        XCTAssertNil(NotificationRoute.parse(thread: "pervio-run-"))
        XCTAssertNil(NotificationRoute.parse(thread: "pervio-wf-"))
    }

    func testUserInfo_readsTheApsThreadId() {
        // The wire shape APNs actually delivers: thread-id nested under aps.
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Pervio · 任务完成"],
                    "thread-id": "pervio-run-deadbeef0001"] as [String: Any],
        ]
        XCTAssertEqual(NotificationRoute.parse(userInfo: userInfo), .run("deadbeef0001"))
        // A LOCAL banner has no aps dict — no route, the tap opens the app as-is.
        XCTAssertNil(NotificationRoute.parse(userInfo: [:]))
        XCTAssertNil(NotificationRoute.parse(userInfo: ["aps": ["alert": "hi"]]))
    }

    @MainActor
    func testAppDelegate_buffersATapThatBeatsTheStore() {
        // Cold launch FROM a notification: didReceive fires before PervioApp's
        // .task wires the closure. The tap is the user's whole intent — it must
        // be buffered and replayed on wiring, not dropped like an early token.
        let delegate = AppDelegate()
        delegate.handleTap(userInfo: [
            "aps": ["thread-id": "pervio-wf-f00dfeed0002"] as [String: Any],
        ])
        var delivered: [NotificationRoute] = []
        delegate.onNotificationTap = { delivered.append($0) }
        XCTAssertEqual(delivered, [.workflow("f00dfeed0002")],
                       "the buffered tap must replay exactly once on wiring")

        // Wired path: a later tap flows straight through (and the buffer stays empty).
        delegate.handleTap(userInfo: [
            "aps": ["thread-id": "pervio-run-cafe00000003"] as [String: Any],
        ])
        XCTAssertEqual(delivered, [.workflow("f00dfeed0002"), .run("cafe00000003")])

        // An unroutable tap neither delivers nor pollutes the buffer.
        delegate.handleTap(userInfo: [:])
        XCTAssertEqual(delivered.count, 2)
    }
}
