import XCTest
import SwiftUI
@testable import Pervio

/// The server editor is hosted in a real window and must come up: a section
/// that reaches for an environment object nobody injects (MacCredentialSection
/// declared EngineStore that way, 2026-10-16) kills the app the moment the New
/// Server sheet opens — the unit suite never rendered the Form, the e2e did.
/// A crash here fails the whole run; a blank hierarchy fails this test.
@MainActor
final class ServerEditorRenderTests: XCTestCase {
    private var window: UIWindow?

    private func host<V: View>(_ v: V) -> UIView {
        let host = UIHostingController(rootView: v)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        w.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        w.rootViewController = host
        w.makeKeyAndVisible()
        window = w
        host.view.frame = w.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        return host.view
    }

    private func count(_ v: UIView) -> Int { 1 + v.subviews.reduce(0) { $0 + count($1) } }

    func testNewServerEditorRenders() {
        let v = host(ProfileEditView(profile: ServerProfile()).environmentObject(AppStore()))
        XCTAssertGreaterThan(count(v), 5, "the New Server form rendered nothing")
    }

    func testCompleteServerEditorRenders() {
        let v = host(ProfileEditView(profile: TestFactory.profile()).environmentObject(AppStore()))
        XCTAssertGreaterThan(count(v), 5, "the server form rendered nothing")
    }
}
