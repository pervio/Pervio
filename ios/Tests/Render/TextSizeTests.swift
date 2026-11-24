import XCTest
import SwiftUI
@testable import Pervio

/// Settings → text size must change what is on screen, at once (a tester tapped
/// 大 and nothing moved, 2026-10-17 probe). Pinned on a hosted Text: the stored
/// step scales the rendered height, and changing the store while the view is
/// up re-renders it.
@MainActor
final class TextSizeTests: XCTestCase {
    private var window: UIWindow?
    private let key = TextSize.defaultsKey

    override func tearDown() {
        window?.isHidden = true
        window = nil
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    private func host<V: View>(_ v: V) -> UIHostingController<V> {
        let host = UIHostingController(rootView: v)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        w.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        w.rootViewController = host
        w.makeKeyAndVisible()
        window = w
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return host
    }

    private func measured<V: View>(_ host: UIHostingController<V>) -> CGFloat {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: 1000, height: 1000)).height
    }

    func testStoredStepScalesTheText() {
        UserDefaults.standard.set("small", forKey: key)
        let small = measured(host(Text("The quick brown fox").modifier(TextSizeModifier())))
        window?.isHidden = true
        UserDefaults.standard.set("large", forKey: key)
        let large = measured(host(Text("The quick brown fox").modifier(TextSizeModifier())))
        XCTAssertGreaterThan(large, small, "large must render taller than small (small \(small), large \(large))")
    }

    /// The app starts on "system" (no step) and the person picks a step: the
    /// modifier's branch flips from bare content to a sized one.
    func testLeavingSystemForAStepReRenders() {
        UserDefaults.standard.removeObject(forKey: key)
        let h = host(Text("The quick brown fox").modifier(TextSizeModifier()))
        let before = measured(h)
        UserDefaults.standard.set("large", forKey: key)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let after = measured(h)
        XCTAssertGreaterThan(after, before, "system → large must grow the text (before \(before), after \(after))")
    }

    // MARK: bisecting the app's tree (the home greeting did not move in the probe)
    final class SizeBox { var last: CGSize = .zero }
    struct Probe: View {
        let box: SizeBox
        var body: some View {
            Text("The quick brown fox").font(.title2.bold())
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { box.last = g.size }
                        .onChange(of: g.size) { _, s in box.last = s }
                })
        }
    }

    private func grows<V: View>(_ make: (SizeBox) -> V, file: StaticString = #filePath, line: UInt = #line) {
        UserDefaults.standard.set("small", forKey: key)
        let box = SizeBox()
        let h = host(make(box))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let before = box.last.height
        UserDefaults.standard.set("large", forKey: key)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        h.view.layoutIfNeeded()
        let after = box.last.height
        XCTAssertGreaterThan(after, before, "small \(before) → large \(after)", file: file, line: line)
    }

    func testScalesInsideNavigationStackList() {
        grows { box in NavigationStack { List { Probe(box: box) } }.modifier(TextSizeModifier()) }
    }

    func testScalesInsideNavigationStackVStack() {
        grows { box in NavigationStack { VStack { Probe(box: box) } }.modifier(TextSizeModifier()) }
    }

    func testRootWrapperScalesTooAndKeepsTheTreeOnSystemToStep() {
        UserDefaults.standard.removeObject(forKey: key)
        let box = SizeBox()
        let h = host(TextSized { Probe(box: box) })
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let before = box.last.height
        UserDefaults.standard.set("large", forKey: key)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        h.view.layoutIfNeeded()
        XCTAssertGreaterThan(box.last.height, before, "system → large through the root wrapper")
    }

    /// The chat bubble is a UITextView: it must follow the step like SwiftUI text does.
    func testChatBubbleFollowsTheStep() {
        func height(_ step: DynamicTypeSize) -> CGFloat {
            let h = host(SelectableText(plain: "The quick brown fox jumps over the lazy dog, twice over.", menuItems: [])
                            .dynamicTypeSize(step).frame(width: 300))
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let s = h.sizeThatFits(in: CGSize(width: 300, height: 1000)).height
            window?.isHidden = true
            return s
        }
        let small = height(.small), big = height(.xxLarge)
        XCTAssertGreaterThan(big, small, "bubble text must grow with the step (small \(small), xxLarge \(big))")
    }

    func testScaledKeepsTheHierarchy() {
        let a = NSMutableAttributedString(string: "Head", attributes: [.font: UIFont.systemFont(ofSize: 22, weight: .bold)])
        a.append(NSAttributedString(string: " body", attributes: [.font: UIFont.systemFont(ofSize: 17)]))
        let s = a.scaled(by: 2)
        XCTAssertEqual((s.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize, 44)
        XCTAssertEqual((s.attribute(.font, at: 5, effectiveRange: nil) as? UIFont)?.pointSize, 34)
        XCTAssertTrue(a.scaled(by: 1) === a, "factor 1 hands the same string back")
        XCTAssertGreaterThan(TypeScale.factor(for: .xxLarge), TypeScale.factor(for: .small))
    }

    func testScalesWithTintAndSchemeAfterIt() {
        grows { box in Probe(box: box).modifier(TextSizeModifier()).tint(.orange).preferredColorScheme(.dark) }
    }

    func testChangingTheSettingWhileOnScreenReRenders() {
        UserDefaults.standard.set("small", forKey: key)
        let h = host(Text("The quick brown fox").modifier(TextSizeModifier()))
        let before = measured(h)
        UserDefaults.standard.set("large", forKey: key)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let after = measured(h)
        XCTAssertGreaterThan(after, before, "the view must follow the setting live (before \(before), after \(after))")
    }
}
