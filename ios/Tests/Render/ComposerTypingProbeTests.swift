import XCTest
import SwiftUI
import UIKit
import ObjectiveC
@testable import Pervio

/// The chat page under a keystroke and under a streamed chunk, measured on the
/// REAL page (ChatView hosted in a window on the simulator, its transcript
/// loaded through a scripted Mac), not inferred from the code. Two counters
/// from swizzled UIKit methods say what the transcript did: how many
/// UITextViews were re-measured (sizeThatFits) and how many had their text
/// re-set (setAttributedText), per text view, so the views that were already
/// on the page (the history) can be told from the composer and the bubble
/// being written.
///
/// The contract these tests pin (2026-11-18): the history is not touched by a
/// keystroke, nor by a landing. Before: the two link-routing closures the page
/// wrote into the environment on every body were new values each time, so
/// every text view re-ran its update — 180 sets and 485 measurements per key
/// at 60 turns, 153 ms a key; 151 ms a landing with 62 % of frames dropped.
/// After (LinkRouter, the text view's own guard, the composer as a view of its
/// own, the folder cache): 12 ms a key, 35–40 ms a landing, history 0 / 0.
/// The CPU and frame figures are printed (PROBE| lines) for the next person
/// who touches ChatView, MessageRow or SelectableText; only the counters are
/// asserted, since CPU time varies with the machine.
@MainActor
final class ComposerTypingProbeTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: - counters (swizzled once for the process)

    enum Tally {
        static var sizeThatFits = 0
        static var setAttributed = 0
        /// Per text view, so a test can ask about the views that were already
        /// on the page before the keystroke / landing (the history), apart from
        /// the composer and the bubble being written.
        static var fitsBy: [ObjectIdentifier: Int] = [:]
        static var setsBy: [ObjectIdentifier: Int] = [:]
        static func reset() { sizeThatFits = 0; setAttributed = 0; fitsBy = [:]; setsBy = [:] }
        static func sets(on ids: Set<ObjectIdentifier>) -> Int { ids.reduce(0) { $0 + (setsBy[$1] ?? 0) } }
        static func fits(on ids: Set<ObjectIdentifier>) -> Int { ids.reduce(0) { $0 + (fitsBy[$1] ?? 0) } }
        static let install: Void = {
            swap(#selector(UITextView.sizeThatFits(_:)), #selector(UITextView.probe_sizeThatFits(_:)))
            swap(#selector(setter: UITextView.attributedText), #selector(UITextView.probe_setAttributedText(_:)))
        }()
        private static func swap(_ a: Selector, _ b: Selector) {
            guard let m1 = class_getInstanceMethod(UITextView.self, a),
                  let m2 = class_getInstanceMethod(UITextView.self, b) else { return }
            method_exchangeImplementations(m1, m2)
        }
    }

    // MARK: - a conversation shaped like the real one (2 tool rows per turn)

    private static let para = "这一轮我核对了 **三个文件** 的改动:`server/bin/pervio-chat` 的参数解析、"
        + "`ios/Sources/Services/ChatStore.swift` 的历史加载,以及对应的测试。结论是加载路径没有问题,"
        + "但渲染路径每次都会重新测量。" + String(repeating: " 下面是更多说明,用来把这条消息撑到真实长度。", count: 8)

    private static func transcript(turns n: Int) -> String {
        var rows: [[String: Any]] = []
        for i in 0..<n {
            rows.append(["role": "user", "text": "第 \(i) 个问题:这里为什么会卡?", "tools": []])
            rows.append(["role": "assistant", "text": para, "tools": ["Bash ls -la", "Read ChatView.swift"],
                         "blocks": [
                            ["t": "text", "v": para],
                            ["t": "tool", "v": "Bash ls -la", "name": "Bash", "id": "toolu_\(i)a", "command": "ls -la"],
                            ["t": "tool", "v": "Read ChatView.swift", "name": "Read", "id": "toolu_\(i)b",
                             "filePath": "/srv/proj/ChatView.swift"],
                            ["t": "text", "v": "结论:" + para],
                         ]])
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
    }

    private func fake(turns: Int) -> FakeSSH {
        let f = FakeSSH()
        f.script("transcript", Self.transcript(turns: turns))
        f.script("context --dir", #"{"used": 1234, "model": "claude-fable-5"}"#)
        f.script("pervio-sessions usage", "{}")
        return f
    }

    // MARK: - hosting

    private func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    private static func textViews(in v: UIView) -> [UITextView] {
        var out: [UITextView] = []
        if let tv = v as? UITextView { out.append(tv) }
        for c in v.subviews { out += textViews(in: c) }
        return out
    }

    private static func editable(in v: UIView) -> UIView? {
        if let tv = v as? UITextView, tv.isEditable { return tv }
        if let tf = v as? UITextField { return tf }
        for c in v.subviews { if let e = editable(in: c) { return e } }
        return nil
    }

    private func host(turns: Int) -> (UIView, FakeSSH) {
        let (root, f, _) = hostWithStore(turns: turns)
        return (root, f)
    }

    private func hostWithStore(turns: Int) -> (UIView, FakeSSH, ChatStore) {
        _ = Tally.install
        let f = fake(turns: turns)
        let sid: String? = turns > 0 ? "sess-probe-\(turns)" : nil
        let store = ChatStore(profile: TestFactory.profile(), secret: "s", resumeSessionId: sid, ssh: f)
        let view = ChatView(profile: TestFactory.profile(), secret: "s", resumeSessionId: sid, store: store)
            .environmentObject(AppStore())
        let host = UIHostingController(rootView: view)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        w.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        w.rootViewController = host
        w.makeKeyAndVisible()
        window = w
        host.view.frame = w.bounds
        host.view.layoutIfNeeded()
        // Wait for the transcript to land: every turn becomes at least one text view.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            pump(0.2)
            let n = Self.textViews(in: host.view).count
            if turns == 0 ? n >= 1 : n >= turns * 2 { break }
        }
        pump(1.0)   // let the load-time scroll-to-end and uuid back-fill settle
        return (host.view, f, store)
    }

    /// Spin the main run loop until a 50 ms slice of it burns under 1 ms of CPU
    /// (the keystroke's work is over), or 4 s pass. Returns (cpu ms, wall ms).
    private func settleAfterKey() -> (Double, Double) {
        let c0 = threadCPU(), w0 = CACurrentMediaTime()
        var idle = 0
        while CACurrentMediaTime() - w0 < 4 {
            let a = threadCPU()
            pump(0.05)
            if threadCPU() - a < 0.001 { idle += 1; if idle >= 2 { break } } else { idle = 0 }
        }
        return ((threadCPU() - c0) * 1000, (CACurrentMediaTime() - w0) * 1000)
    }

    private struct Sample { var cpu: Double; var wall: Double; var fits: Int; var sets: Int; var histSets: Int; var histFits: Int }

    /// The transcript's text views: every UITextView on the page but the composer.
    private static func historyIds(in root: UIView) -> Set<ObjectIdentifier> {
        Set(textViews(in: root).filter { !$0.isEditable }.map { ObjectIdentifier($0) })
    }

    private func typeAndMeasure(into root: UIView, keys: Int) -> [Sample] {
        guard let field = Self.editable(in: root) as? (UIView & UIKeyInput) else {
            XCTFail("no editable text field under the composer"); return []
        }
        field.becomeFirstResponder()
        pump(0.8)                                  // keyboard up, safe-area settled
        for _ in 0..<2 { field.insertText("w"); _ = settleAfterKey() }   // warm-up keys
        let history = Self.historyIds(in: root)
        var out: [Sample] = []
        for k in 0..<10 {
            Tally.reset()
            field.insertText(k % 3 == 2 ? "字" : "a")
            let (cpu, wall) = settleAfterKey()
            out.append(Sample(cpu: cpu, wall: wall, fits: Tally.sizeThatFits, sets: Tally.setAttributed,
                              histSets: Tally.sets(on: history), histFits: Tally.fits(on: history)))
        }
        return out
    }

    private func median(_ xs: [Double]) -> Double {
        let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2]
    }

    // MARK: - the measurement

    func testWhatOneKeystrokeCostsByConversationLength() {
        var report: [String] = []
        for turns in [0, 10, 30, 60] {
            let (root, _) = host(turns: turns)
            let tvs = Self.textViews(in: root).count
            // idle baseline: the page doing nothing for the same spin
            let (idleCPU, _) = settleAfterKey()
            let samples = typeAndMeasure(into: root, keys: 10)
            let line = String(format: "PROBE| turns %2d  textViews %3d  idle %.1f ms | per key: cpu median %.1f ms (max %.1f)  wall median %.0f ms  sizeThatFits median %d  setAttributedText median %d  on history: sets %d fits %d",
                              turns, tvs, idleCPU,
                              median(samples.map(\.cpu)), samples.map(\.cpu).max() ?? 0,
                              median(samples.map(\.wall)),
                              Int(median(samples.map { Double($0.fits) })),
                              Int(median(samples.map { Double($0.sets) })),
                              samples.map(\.histSets).max() ?? 0, samples.map(\.histFits).max() ?? 0)
            report.append(line)
            print(line)
            for (i, s) in samples.enumerated() {
                print(String(format: "PROBE|   key %d: cpu %.1f ms wall %.0f ms fits %d sets %d history sets %d fits %d", i, s.cpu, s.wall, s.fits, s.sets, s.histSets, s.histFits))
            }
            // The contract: a keystroke is the composer's business alone. Before
            // 2026-11-18 each key re-set and re-measured every text view of the
            // transcript (180 sets, 485 measurements, 153 ms a key at 60 turns).
            XCTAssertEqual(samples.map(\.histSets).max() ?? 0, 0,
                           "a keystroke must not re-set the text of any bubble (\(turns) turns)")
            XCTAssertEqual(samples.map(\.histFits).max() ?? 0, 0,
                           "a keystroke must not re-measure any bubble (\(turns) turns)")
            XCTAssertEqual(samples.count, 10)
            window?.isHidden = true
            window = nil
            pump(0.3)
        }
        print(report.joined(separator: "\n"))
    }

    // MARK: - a reply streaming into a long conversation (the scroll-while-generating lag)

    /// Counts the frames the main thread actually delivered.
    private final class Frames {
        var count = 0
        private var link: CADisplayLink?
        func start() {
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common); link = l
        }
        @objc private func tick() { count += 1 }
        func stop() { link?.invalidate(); link = nil }
    }

    /// A reply streams into the conversation on screen at a real reply's pace
    /// (16 deltas a second, ~20 chars each, through the fake's pause gates), on
    /// a 1-turn and a 60-turn conversation: main-thread CPU, frames delivered,
    /// and how many transcript text views were re-set / re-measured meanwhile.
    func testWhatAStreamingReplyCostsByConversationLength() async {
        for turns in [1, 60] {
            let (root, f, store) = hostWithStore(turns: turns)
            let tvs = Self.textViews(in: root).count
            let deltas = 120
            let events = (0..<deltas).map { AgentEvent.textDelta("这是第 \($0) 块流式输出的文字,还在继续写。") }
                + [.result(text: "", sessionId: "sess-probe-\(turns)", costUSD: nil, isError: false, contextWindow: nil)]
            f.chatEvents(events)
            for i in 0..<deltas { f.pauseChat(before: i) }
            let history = Self.historyIds(in: root)
            Tally.reset()
            let frames = Frames(); frames.start()
            let c0 = threadCPU(), w0 = CACurrentMediaTime()
            let turn = Task { await store.send("继续") }
            // One delta per landing, at the coalescer's own rhythm (≤16 a second):
            // let delta i through, wait until it is on the page, breathe, repeat.
            for i in 0..<deltas {
                await f.awaitChatPaused()
                f.releaseChat()
                let needle = "第 \(i) 块"
                let dl = Date().addingTimeInterval(3)
                while Date() < dl, !(store.messages.last?.text.contains(needle) ?? false) {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                try? await Task.sleep(nanoseconds: 45_000_000)
            }
            let deadline = Date().addingTimeInterval(5)
            while store.isBusy && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            let streamCPU = (threadCPU() - c0) * 1000
            let wall = CACurrentMediaTime() - w0
            frames.stop()
            turn.cancel()
            let reply = store.messages.last { $0.role == .assistant }
            XCTAssertEqual(reply?.text.contains("第 \(deltas - 1) 块"), true, "every delta must have landed on the page")
            let expected = Int(wall * 60)
            print(String(format: "PROBE| stream turns %2d  textViews %3d | %d landings in %.1f s: cpu %.0f ms (%.1f ms per landing)  frames %d of %d expected  sizeThatFits %d  setAttributedText %d  on history: sets %d fits %d",
                         turns, tvs, deltas, wall, streamCPU, streamCPU / Double(deltas), frames.count, expected,
                         Tally.sizeThatFits, Tally.setAttributed, Tally.sets(on: history), Tally.fits(on: history)))
            // The contract: a streamed chunk touches the bubble being written and
            // nothing above it. Before 2026-11-18 every landing re-set every text
            // view of the transcript (22 987 sets over these 120 landings at 60
            // turns, 151 ms a landing, 62 % of frames dropped).
            XCTAssertEqual(Tally.sets(on: history), 0,
                           "a streamed chunk must not re-set the text of any earlier bubble (\(turns) turns)")
            XCTAssertLessThanOrEqual(Tally.fits(on: history), 10,
                                     "earlier bubbles must not be re-measured on every landing (\(turns) turns)")
            window?.isHidden = true
            window = nil
            pump(0.3)
        }
    }
}

extension UITextView {
    @objc dynamic func probe_sizeThatFits(_ size: CGSize) -> CGSize {
        ComposerTypingProbeTests.Tally.sizeThatFits += 1
        ComposerTypingProbeTests.Tally.fitsBy[ObjectIdentifier(self), default: 0] += 1
        return probe_sizeThatFits(size)      // exchanged: this is the original
    }
    @objc dynamic func probe_setAttributedText(_ t: NSAttributedString?) {
        ComposerTypingProbeTests.Tally.setAttributed += 1
        ComposerTypingProbeTests.Tally.setsBy[ObjectIdentifier(self), default: 0] += 1
        probe_setAttributedText(t)
    }
}
