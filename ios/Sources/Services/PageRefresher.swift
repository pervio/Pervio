import SwiftUI

/// Keeps a page that shows what the Mac says true to the Mac, without the
/// person's help — the same rules on every such page (2026-11-22, the person:
/// "主页如果连接不上…每次都是退出app重新进去才能好", then "都开始吧"):
///
///   * The Mac is read when the page opens, when it is pulled, when it is come
///     back to from another page, and when the app comes back to the front.
///   * A read that could not REACH the Mac is tried again by itself — after
///     2, 4, 8, 15 seconds, then every 30 — until one gets through or the page
///     is left. Every fresh read starts that count over.
///   * What was read before stays on the page meanwhile.
///   * A read the Mac REFUSED (a rejected key or password, a host key that is
///     not the pinned one) is not repeated: waiting cures none of those, and
///     a password sent again and again is how an address gets banned.
///
/// What the page shows of it is `MacProblemRow`. Nothing here watches the
/// network or offers a retry key: a failed read is the one signal, a pull the
/// one way to ask sooner (the person's call — "就通过读失败就行").
@MainActor
final class PageRefresher: ObservableObject {

    /// How one read of the page ended.
    enum Outcome: Equatable {
        case reached                  // the Mac answered
        case unreachable(String)      // no answer — the network, the Mac asleep, a timeout; said in these words
        case refused(String)          // the Mac, or this phone's own settings, said no; not cured by waiting

        var isUnreachable: Bool { if case .unreachable = self { return true } else { return false } }

        /// Two blocks' outcomes as one: the page is true only when both were read.
        static func worst(_ a: Outcome, _ b: Outcome) -> Outcome {
            if a.isUnreachable { return a }
            if b.isUnreachable { return b }
            return a == .reached ? b : a
        }

        /// What a thrown error says about trying again, in the words the page shows.
        static func of(_ error: Error, _ generic: String) -> Outcome {
            let words = pervioErrorText(error, generic)
            guard let conn = error as? SSHService.ConnectionError else { return .unreachable(words) }
            switch conn.kind {
            case .noPin, .unusablePin, .hostKeyMismatch, .badPrivateKey, .missingSecret, .authRejected:
                return .refused(words)
            case .hostNotFound, .portClosed, .other:
                return .unreachable(words)
            }
        }
    }

    /// What is wrong, after a read that did not get through; nil while the page is true
    /// (or has not been read yet).
    @Published private(set) var problem: Outcome?
    /// The last read could not reach the Mac and another one is coming by itself.
    @Published private(set) var retrying = false
    /// Reads started — for a pull to wait on, and for the tests.
    @Published private(set) var attempts = 0

    /// Seconds before the 1st, 2nd, … retry; the last one repeats for as long as the page is shown.
    var delays: [TimeInterval] = [2, 4, 8, 15, 30]
    /// A read that has not answered by then counts as one that did not reach
    /// the Mac; the next goes out, and that read's answer, should it ever
    /// come, is dropped by the page that asked (`LoadTicket`).
    var patience: TimeInterval = 15

    private var work: (() async -> Outcome)?
    private var loop: Task<Void, Never>?
    private var shown = false
    private var attemptStarted: Date?

    /// Read now with `work`, and keep at it while the Mac cannot be reached.
    func refresh(_ work: @escaping () async -> Outcome) {
        self.work = work
        refresh()
    }

    /// Read again now with the same work.
    func refresh() {
        guard work != nil else { return }
        start(after: 0, failures: 0)
    }

    /// The same, for a pull: returns when that read has answered (or run out of patience).
    func refreshAndWait() async {
        guard work != nil else { return }
        let before = attempts
        refresh()
        let deadline = Date().addingTimeInterval(patience + 2)
        while Date() < deadline, attempts == before || attemptStarted != nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The page is on screen and the app is in front: retries may run. One
    /// that was waiting when the page was covered goes out at once.
    func resume() {
        shown = true
        if problem?.isUnreachable == true, loop == nil { start(after: 0, failures: 0) }
    }

    /// The page is covered, or the app is in the background: nothing retries.
    func pause() {
        shown = false
        loop?.cancel(); loop = nil
        attemptStarted = nil
    }

    private func start(after delay: TimeInterval, failures: Int) {
        loop?.cancel()
        attemptStarted = nil
        loop = Task { [weak self] in
            var failed = failures
            var wait = delay
            while !Task.isCancelled {
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    if Task.isCancelled { return }
                }
                guard let self else { return }
                let outcome = await self.attempt()
                if Task.isCancelled { return }
                self.problem = outcome == .reached ? nil : outcome
                guard outcome.isUnreachable, self.shown else {
                    self.retrying = false
                    self.loop = nil
                    return
                }
                self.retrying = true
                wait = self.delays.isEmpty ? 30 : self.delays[min(failed, self.delays.count - 1)]
                failed += 1
            }
        }
    }

    /// One read. Not awaited as a child: a read that hangs (a socket the
    /// network dropped without a word) must not hang the loop with it.
    private func attempt() async -> Outcome {
        guard let work else { return .reached }
        attempts += 1
        let began = Date()
        attemptStarted = began
        defer { if attemptStarted == began { attemptStarted = nil } }
        let box = OutcomeBox()
        let mine = attempts
        Task {
            let outcome = await work()
            box.value = outcome
            guard self.attempts == mine else { return }       // a newer read is out: its answer is the page's
            if self.attemptStarted == began { return }        // the loop is still waiting for this one
            // The loop had stopped waiting (patience ran out, or the page was
            // covered meanwhile). The answer still counts as what is known of
            // the Mac: one that got through after all ends the retrying, and
            // "no answer" with nothing scheduled starts it.
            self.problem = outcome == .reached ? nil : outcome
            if outcome == .reached {
                self.loop?.cancel(); self.loop = nil
                self.retrying = false
            } else if outcome.isUnreachable, self.shown, self.loop == nil {
                self.retrying = true
                self.start(after: self.delays.first ?? 30, failures: 1)
            }
        }
        await Task.yield()
        while box.value == nil {
            if Task.isCancelled { return .unreachable(L.homeUnreachable()) }
            if Date().timeIntervalSince(began) > patience { return .unreachable(L.homeUnreachable()) }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return box.value ?? .unreachable(L.homeUnreachable())
    }
}

@MainActor
private final class OutcomeBox {
    var value: PageRefresher.Outcome?
}

/// "The newest read's answer is the page's." Each read of a page takes a
/// ticket; when it comes back it applies what it found only if no later read
/// has been started meanwhile. Without it a slow failure that finally gives up
/// writes over the answer of the retry that already succeeded.
struct LoadTicket {
    private var latest = 0
    mutating func take() -> Int { latest += 1; return latest }
    func isLatest(_ ticket: Int) -> Bool { ticket == latest }
}

// MARK: - The four times a page reads

/// Wires a page to its refresher: read on opening and on coming back to the
/// page (`onAppear` fires for both; `.task` only for the first), on a pull,
/// and when the app returns from the background; nothing retries while the
/// page is covered or the app is away.
private struct ReadsTheMac: ViewModifier {
    @ObservedObject var refresher: PageRefresher
    let work: () async -> PageRefresher.Outcome
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false
    @State private var wasAway = false

    func body(content: Content) -> some View {
        content
            .refreshable { await refresher.refreshAndWait() }
            .onAppear {
                onScreen = true
                guard scenePhase != .background else { return }
                refresher.resume()
                refresher.refresh(work)
            }
            .onDisappear {
                onScreen = false
                refresher.pause()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    wasAway = true
                    refresher.pause()
                    return
                }
                guard phase == .active, onScreen else { return }
                refresher.resume()
                // Back from the background — not from a glance at the app
                // switcher, which never left: that one reads nothing new.
                if wasAway {
                    wasAway = false
                    refresher.refresh(work)
                }
            }
    }
}

extension View {
    /// This page shows what the Mac says: read it at the four times, and keep
    /// trying by itself while the Mac cannot be reached (see `PageRefresher`).
    func readsTheMac(_ refresher: PageRefresher, _ work: @escaping () async -> PageRefresher.Outcome) -> some View {
        modifier(ReadsTheMac(refresher: refresher, work: work))
    }
}

// MARK: - What the page shows of it

/// The one way every page says the Mac is not answering. Nothing while all is
/// well. Orange when it cannot be reached: the reason, "trying again by
/// itself", and the checkup. Red when the Mac refused — or this phone's own
/// settings are not usable: the reason and the way to the server's settings,
/// and no retrying. Gone the moment a read gets through.
struct MacProblemRow: View {
    let problem: PageRefresher.Outcome?
    let retrying: Bool
    let profile: ServerProfile
    let secret: String
    /// Read the page again — after the checkup, after the settings.
    var reread: () -> Void = {}

    @EnvironmentObject private var store: AppStore
    @State private var showDoctor = false
    @State private var editing: ServerProfile?
    /// What the settings were when they were opened, to tell an edit from a look.
    @State private var before: Snapshot?
    private struct Snapshot: Equatable { let profile: ServerProfile?; let secret: String? }

    private var live: ServerProfile { store.profiles.first { $0.id == profile.id } ?? profile }
    private func snapshot() -> Snapshot {
        let p = store.profiles.first { $0.id == profile.id }
        return Snapshot(profile: p, secret: p.flatMap { store.secret(for: $0) })
    }

    var body: some View {
        switch problem {
        case .unreachable(let why):
            VStack(alignment: .leading, spacing: 6) {
                Label(why, systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.orange).lineLimit(3)
                if retrying {
                    HStack(spacing: 6) {
                        BreathingDot(date: Date())       // the app's "still going" mark
                        Text(L.macRetrying()).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mac-retrying")
                }
                // 天书报错的出口(roadmap 3.3):一键逐项体检,人话结论。
                Button { showDoctor = true } label: {
                    Label(L.doctorOpen(), systemImage: "stethoscope").font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("mac-checkup")
            }
            // A container of its own: an identifier set on a plain stack is
            // handed down to every element in it, over their own names.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mac-unreachable")
            // The checkup closed: whatever it found, read the page again.
            .sheet(isPresented: $showDoctor, onDismiss: reread) {
                ConnectDoctorView(profile: live, secret: store.secret(for: live) ?? secret)
            }
        case .refused(let why):
            VStack(alignment: .leading, spacing: 6) {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(5)
                Button {
                    before = snapshot()
                    editing = live
                } label: {
                    Label(L.macOpenSettings(), systemImage: "gearshape").font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("mac-settings")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mac-refused")
            .sheet(item: $editing, onDismiss: settingsClosed) { p in
                ProfileEditView(profile: p).environmentObject(store)
            }
        default:
            EmptyView()
        }
    }

    /// Settings were changed: every page under this one was opened with the
    /// old ones, so the way on starts from the home page, which reads the
    /// server as it is saved now. Only looked at: this page reads again.
    private func settingsClosed() {
        if let before, before != snapshot() {
            store.notificationRoute = .home
        }
        before = nil
        reread()
    }
}
