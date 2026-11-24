import XCTest
import SwiftUI
import UIKit
@testable import Pervio

/// The transcript scroll contract, measured on the REAL scroll view (hosted in
/// a window on the simulator, offsets read back from UIKit), not inferred from
/// code: growth below a reader who scrolled up must not move them; a reader at
/// the end must be carried along; a reopened transcript opens at its end.
/// The root-cause test documents what the fix exists for — if an OS update
/// ever makes it fail, the modifier can be simplified, not the other way round.
@MainActor
final class TranscriptAnchoringTests: XCTestCase {

    final class Rows: ObservableObject {
        @Published var items: [String] = (0..<40).map { "row \($0)" }
        @Published var tail = ""
    }

    /// `legacy`: the bare `.defaultScrollAnchor(.bottom)` the transcript used
    /// to carry. `initialOnly`: iOS 18's `.initialOffset` role alone. `none`:
    /// no anchor at all. `app`: TranscriptAnchoring as shipped.
    enum Mode { case legacy, initialOnly, none, app }

    /// Mirrors the transcript: rows, a growing tail, a trailing marker, and the
    /// view's own follow-at-the-end scrollTo (unanimated) when the reader is at
    /// the end, plus the load-time scrollToEnd.
    struct Probe: View {
        @ObservedObject var rows: Rows
        let mode: Mode
        let atBottom: Bool
        var body: some View {
            ScrollViewReader { proxy in
                let list = ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(rows.items, id: \.self) { Text($0).frame(height: 40) }
                        Text(rows.tail)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .onChange(of: rows.tail) { _, _ in
                    if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear {
                    if atBottom { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                switch mode {
                case .legacy: list.defaultScrollAnchor(.bottom)
                case .initialOnly:
                    if #available(iOS 18.0, *) { list.defaultScrollAnchor(.bottom, for: .initialOffset) } else { list }
                case .none: list
                case .app: list.modifier(TranscriptAnchoring(atBottom: atBottom))
                }
            }
        }
    }

    private var window: UIWindow?

    private func host(_ probe: Probe) -> UIScrollView {
        let host = UIHostingController(rootView: probe)
        // A scene-based app only renders windows that belong to a scene: a bare
        // UIWindow never lays out, and the SwiftUI tree under it stays empty.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        w.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        w.rootViewController = host
        w.makeKeyAndVisible()
        window = w
        host.view.frame = w.bounds
        host.view.layoutIfNeeded()
        pump(0.5)
        guard let sv = Self.scrollView(in: host.view) else {
            XCTFail("no UIScrollView under the hosted ScrollView (scene: \(scene != nil))"); return UIScrollView()
        }
        return sv
    }

    private func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private static func scrollView(in v: UIView) -> UIScrollView? {
        if let s = v as? UIScrollView { return s }
        for c in v.subviews { if let s = scrollView(in: c) { return s } }
        return nil
    }

    /// The reply grows by this much (well over a screen), as a long streamed turn does.
    private let growth = String(repeating: "more of the reply\n", count: 60)

    /// Reader at the top, the reply grows: how far did the offset move?
    private func driftWhenScrolledUp(_ mode: Mode) -> CGFloat {
        let rows = Rows()
        let sv = host(Probe(rows: rows, mode: mode, atBottom: false))
        sv.setContentOffset(.zero, animated: false); pump(0.2)
        let before = sv.contentOffset.y
        rows.tail = growth; pump(0.4)
        return sv.contentOffset.y - before
    }

    /// Root cause, part three (measured 2026-10-15): a GeometryReader
    /// preference inside the content is re-read on LAYOUT, not on a plain
    /// scroll — so "am I at the end?" computed from it goes stale when the
    /// reader scrolls during a quiet stretch. The scroll-geometry path sees
    /// the scroll. Both measured on the real scroll view.
    final class Seen: ObservableObject { var preference: [CGFloat] = []; var geometry: [CGFloat] = [] }
    struct TrackingProbe: View {
        @ObservedObject var rows: Rows
        let seen: Seen
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows.items, id: \.self) { Text($0).frame(height: 40) }
                    Color.clear.frame(height: 1).id("bottom")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: MarkerKey.self, value: g.frame(in: .named("probe")).minY)
                        })
                }
            }
            .coordinateSpace(name: "probe")
            // The observer on the ScrollView itself (an ancestor of the marker);
            // in a `.background { … }` it is a sibling and never fires — which is
            // exactly how the app's flag had been dead (first measurement: nil).
            .onPreferenceChange(MarkerKey.self) { y in seen.preference.append(y) }
            .modifier(TranscriptEndTracking(onDistance: { d, _, _ in seen.geometry.append(d) }))
        }
    }
    struct MarkerKey: PreferenceKey {
        static var defaultValue: CGFloat = .infinity
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
    }

    func testRootCause3_markerPreferenceMissesAPlainScrollButScrollGeometrySeesIt() {
        let rows = Rows(); let seen = Seen()
        let host = UIHostingController(rootView: TrackingProbe(rows: rows, seen: seen))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        w.frame = CGRect(x: 0, y: 0, width: 390, height: 600); w.rootViewController = host; w.makeKeyAndVisible(); window = w
        host.view.frame = w.bounds; host.view.layoutIfNeeded(); pump(0.5)
        guard let sv = Self.scrollView(in: host.view) else { XCTFail("no scroll view"); return }
        // Start at the end (as a chat opens), then a plain scroll to the top.
        sv.setContentOffset(CGPoint(x: 0, y: sv.contentSize.height - sv.bounds.height), animated: false); pump(0.3)
        let prefAtEnd = seen.preference.last, geoAtEnd = seen.geometry.last
        sv.setContentOffset(.zero, animated: false); pump(0.4)
        let prefAfter = seen.preference.last, geoAfter = seen.geometry.last
        if #available(iOS 18.0, *) {
            XCTAssertNotNil(geoAtEnd); XCTAssertNotNil(geoAfter)
            // visibleRect accounts for the insets, so the very end reads ~0.
            XCTAssertLessThanOrEqual(geoAtEnd ?? 999, 2, "at the end the distance must read ~0")
            XCTAssertGreaterThan(geoAfter ?? 0, 1000, "after scrolling to the top the geometry path must report a large distance from the end")
        }
        XCTAssertNotNil(prefAtEnd, "the marker preference never reaches an observer on the ScrollView itself")
        // Documented, not required: the preference path. If it ever starts
        // seeing plain scrolls, the iOS 17 fallback is as good as the geometry.
        print("marker preference: at end \(String(describing: prefAtEnd)), after scrolling up \(String(describing: prefAfter)); geometry: \(String(describing: geoAtEnd)) → \(String(describing: geoAfter))")
    }

    func testRootCause_bareBottomAnchorMovesAReaderWhoScrolledUp() {
        XCTAssertGreaterThan(driftWhenScrolledUp(.legacy), 100,
                             "a bare .defaultScrollAnchor(.bottom) no longer re-pins the end on growth "
                             + "on this OS — TranscriptAnchoring may be simplifiable")
    }

    /// Root cause, part two (measured 2026-10-15 on iOS 26): the
    /// `.initialOffset` role ALONE also re-pins the end on growth, which is why
    /// TranscriptAnchoring uses no defaultScrollAnchor at all. If this ever
    /// fails, the OS now separates the roles and the modifier could use
    /// `.initialOffset` to open at the end without the load-time scroll.
    func testRootCause2_initialOffsetRoleAloneAlsoMovesAScrolledUpReader() {
        XCTAssertGreaterThan(driftWhenScrolledUp(.initialOnly), 100)
    }

    func testMeasure_noAnchorKeepsAScrolledUpReaderPut() {
        XCTAssertEqual(driftWhenScrolledUp(.none), 0, accuracy: 2)
    }

    func testScrolledUpReaderStaysPutWhenTheReplyGrows() {
        XCTAssertEqual(driftWhenScrolledUp(.app), 0, accuracy: 2,
                       "growth below moved a reader who had scrolled up")
    }

    func testOpensAtTheEnd() {
        let rows = Rows()
        let sv = host(Probe(rows: rows, mode: .app, atBottom: true))
        let end = sv.contentSize.height - sv.bounds.height
        XCTAssertEqual(sv.contentOffset.y, end, accuracy: 2, "a reopened transcript must open at its end")
    }

    func testReaderAtTheEndIsCarriedAlong() {
        let rows = Rows()
        let sv = host(Probe(rows: rows, mode: .app, atBottom: true))
        let end = max(0, sv.contentSize.height - sv.bounds.height)
        sv.setContentOffset(CGPoint(x: 0, y: end), animated: false); pump(0.2)
        rows.tail = growth; pump(0.4)
        let newEnd = sv.contentSize.height - sv.bounds.height
        XCTAssertEqual(sv.contentOffset.y, newEnd, accuracy: 2,
                       "a reader at the end was not carried to the new end")
        XCTAssertGreaterThan(newEnd, end + 100, "the probe's growth did not change the content size")
    }
}
