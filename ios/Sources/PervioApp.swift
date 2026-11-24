import SwiftUI
import UIKit
import UserNotifications

@main
struct PervioApp: App {
    // Owns app-level notification plumbing (asks permission once, keeps "task
    // finished" banners visible while the app is open). SwiftUI has no App-level
    // launch hook, so we bridge through a UIApplicationDelegate.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    #if DEBUG
    /// Runs BEFORE `AppStore()` does: `@StateObject`'s wrapped value is an
    /// autoclosure, so the store is not built until the first body evaluation —
    /// long after this. That ordering is the whole point; the store must read
    /// defaults the seam has already written. No-op without the launch argument,
    /// and the whole thing is compiled out of Release.
    init() { UITestBootstrap.applyIfRequested() }
    #endif

    var body: some Scene {
        WindowGroup {
            TextSized {        // the person's text size (Settings) — the whole scene
            RootView()
                .task {
                    // Launch-time cache janitor: off the main actor, once per
                    // process; keeps the figure pile under 500MB / 90 days.
                    await Task.detached(priority: .utility) {
                        FigureStore.trimDisk()
                    }.value
                }
                .environmentObject(store)
                // The saved computers as a plain value, for the pickers that
                // can read from another one (SavedServersKey).
                .environment(\.savedServers, store.profiles)
                .tint(Palette.accent)
                .preferredColorScheme(.dark)
                .task {
                    // A tapped notification steers the UI through the store;
                    // RootView watches `notificationRoute` and navigates. Wired
                    // FIRST: setting it replays any tap buffered during a cold
                    // launch, and that replay must find the publisher ready.
                    appDelegate.onNotificationTap = { [weak store] route in
                        Task { @MainActor in store?.notificationRoute = route }
                    }
                    // Hand the delegate a way to ship an APNs token to the home
                    // server. Done here (not in the delegate) because the delegate
                    // is built before the store; a `.task` runs once the store and
                    // its persisted home profile are available.
                    appDelegate.onDeviceToken = { [weak store] token in
                        guard let store, let profile = store.homeProfile else { return }
                        let secret = store.secret(for: profile)
                        Task {
                            let push = PushTokenStore()
                            // Upload first, THEN ask: `pervio-push check` only reports
                            // READY once a token is on disk, so on a first-ever launch
                            // the order is what makes the answer true.
                            await push.uploadIfNeeded(deviceToken: token, profile: profile,
                                                      secret: secret)
                            // Decides whether this app posts its own "task finished"
                            // banner or leaves that to the Mac's push. Only reached
                            // when APNs handed us a token — a phone that never got one
                            // can't be pushed to, and leaving the flag false is exactly
                            // right there.
                            await push.probePushReadiness(profile: profile, secret: secret)
                        }
                    }
                }
            }
        }
    }
}

#if DEBUG
/// Test-only seam for the end-to-end smoke test (ios/UITests/SmokeTests.swift).
///
/// The app has no other way in: a server profile is hand-typed into the editor
/// and its key lives in the Keychain, which a UI test cannot reach. So the test
/// hands the whole profile over on the command line and this writes it exactly
/// where `AppStore.load()` will look for it — no production code path changes,
/// no test-only branch inside the store, no widened AppStore API.
///
///     --pervio-uitest-reset                 # forget saved servers first
///     --pervio-uitest-config=<base64 JSON>  # seed one server + its private key
///
/// The JSON is `server/tests/e2e_ios/setup.sh`'s config.json verbatim.
///
/// Two independent locks keep this away from users: it is `#if DEBUG`, so a
/// Release/TestFlight build does not contain it at all, and even in Debug it
/// returns immediately unless the process was launched with the argument — which
/// only an XCUITest harness can set (arguments come from the launching process,
/// and a tapped app icon supplies none).
enum UITestBootstrap {
    private static let configPrefix = "--pervio-uitest-config="
    private static let resetFlag = "--pervio-uitest-reset"

    /// The keys AppStore persists under. Deliberately duplicated instead of
    /// exposed from AppStore: the seam must not widen the app's own surface.
    private static let profilesKey = "pervio.profiles.v1"
    private static let paramsKey = "pervio.sessionParams.v1"
    private static let scopedParamsKey = "pervio.convParams.v2"
    private static let homeKey = "pervio.homeProfileId.v1"

    /// Fixed, so a rerun overwrites one Keychain entry instead of littering the
    /// simulator with a new secret per launch.
    private static let profileId = UUID(uuidString: "E2E00000-0000-4000-8000-000000000001")!
    /// The optional second server (`second` in the config): the same sandbox
    /// under another name and folder — to the app, another computer.
    private static let secondId = UUID(uuidString: "E2E00000-0000-4000-8000-000000000002")!

    /// Only the fields a test server needs; everything else keeps ServerProfile's
    /// own defaults, so the smoke test exercises the shipping defaults.
    private struct Config: Decodable {
        let host: String
        let port: Int
        let username: String
        let privateKey: String
        let pinnedHostKey: String
        var name: String?
        var projectDir: String?
        var launcherDir: String?
        var model: String?
        var effort: String?
        var permissionMode: String?
        /// A second saved server on the same endpoint and key, for the flows
        /// that need two computers (a file brought from one to the other).
        var second: Second?
        struct Second: Decodable {
            let name: String
            var projectDir: String?
            /// Reach it THROUGH the sandbox's jump host (`jump` below). Two
            /// entries on one endpoint by one path are one Mac to the app
            /// (ServerProfile.reachesSameMachine); a different path makes it
            /// another computer, and walks a route while it is at it.
            var viaJump: Bool?
        }
        /// The sandbox's jump host, as its config.json describes it.
        var jump: Hop?
        struct Hop: Decodable {
            let host: String
            let port: Int
            let pinnedHostKey: String
        }
    }

    static func applyIfRequested() {
        let args = ProcessInfo.processInfo.arguments

        // A simulator keeps its container between runs, so an earlier run's
        // servers would still be listed. Clear only Pervio's OWN keys.
        if args.contains(resetFlag) {
            // The app language too: it lives in the same defaults, and the unit
            // tests — hosted in this app, on this simulator — pin their own while
            // they run. One of them crashing between its setUp and tearDown left
            // the app in Chinese, and the next smoke run failed on English button
            // names (2026-11-22). Every smoke test starts from the shipped default.
            for key in [profilesKey, paramsKey, scopedParamsKey, homeKey, TextSize.defaultsKey, PromptLanguage.defaultsKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            Keychain.delete(profileId.uuidString)
            Keychain.delete(secondId.uuidString)
        }

        guard let arg = args.first(where: { $0.hasPrefix(configPrefix) }) else { return }
        guard let data = Data(base64Encoded: String(arg.dropFirst(configPrefix.count))),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            NSLog("[Pervio] UITestBootstrap: %@ is not base64 JSON — ignored", configPrefix)
            return
        }

        var profile = ServerProfile()
        profile.id = profileId
        profile.name = cfg.name ?? "E2E Sandbox"
        profile.host = cfg.host
        profile.port = cfg.port
        profile.username = cfg.username
        profile.authKind = .privateKey
        profile.pinnedHostKey = cfg.pinnedHostKey
        if let v = cfg.projectDir { profile.projectDir = v }
        if let v = cfg.launcherDir { profile.launcherDir = v }
        if let v = cfg.model { profile.model = v }
        if let v = cfg.effort { profile.effort = v }
        if let v = cfg.permissionMode { profile.permissionMode = v }

        var profiles = [profile]
        if let second = cfg.second {
            var other = profile
            other.id = secondId
            other.name = second.name
            if let v = second.projectDir { other.projectDir = v }
            if second.viaJump == true, let jump = cfg.jump {
                var hop = JumpHop()
                hop.host = jump.host
                hop.port = jump.port
                hop.pinnedHostKey = jump.pinnedHostKey
                other.route = [hop]
            }
            profiles.append(other)
            Keychain.set(cfg.privateKey, for: secondId.uuidString)
        }
        guard let encoded = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(encoded, forKey: profilesKey)
        UserDefaults.standard.set(profileId.uuidString, forKey: homeKey)
        Keychain.set(cfg.privateKey, for: profileId.uuidString)
        NSLog("[Pervio] UITestBootstrap: seeded %@ (%@@%@:%d)",
              profile.name, profile.username, profile.host, profile.port)
    }
}
#endif

/// App delegate for notification plumbing — BOTH tiers now:
///   * Tier 1 (local): asks permission at launch and keeps "task finished" banners
///     visible while the app is open. Works only while the app is alive.
///   * Tier 2 (remote/APNs): registers for remote notifications, and hands the
///     resulting device token to `onDeviceToken` (set by PervioApp) which uploads
///     it to the Mac. The Mac's `pervio-push` then reaches the phone through Apple
///     even after iOS has suspended the app and reclaimed the SSH socket — closing
///     the gap Tier 1 can't (a 6:30am digest, a failure, an approval while locked).
///
/// Registration is harmless without a provisioned APNs key: if the app's
/// aps-environment / push capability isn't set up yet, iOS calls
/// `didFailToRegisterForRemoteNotifications` and we simply log it — no token, no
/// upload, no crash. The moment the capability and server key are in place it all
/// starts working with no code change.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by PervioApp once the store (and its home profile) exist. Receives the
    /// raw APNs token bytes to upload. nil until then — an early token is dropped,
    /// and iOS re-delivers it on the next launch.
    var onDeviceToken: ((Data) -> Void)?

    /// A notification tap's parsed destination, handed up to the app. Unlike the
    /// token, a tap must NOT be dropped when it beats the store into existence —
    /// tapping a push is the one way users cold-launch this app with intent, and
    /// iOS does not re-deliver it. So an early tap is BUFFERED here and replayed
    /// the moment PervioApp wires the closure.
    var onNotificationTap: ((NotificationRoute) -> Void)? {
        didSet {
            if let route = bufferedTap, let deliver = onNotificationTap {
                bufferedTap = nil
                deliver(route)
            }
        }
    }
    private var bufferedTap: NotificationRoute?

    /// The tap logic behind `didReceive`, split from the UN* plumbing because a
    /// test cannot construct a UNNotificationResponse.
    func handleTap(userInfo: [AnyHashable: Any]) {
        guard let route = NotificationRoute.parse(userInfo: userInfo) else { return }
        if let deliver = onNotificationTap {
            deliver(route)
        } else {
            bufferedTap = route
        }
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            // Remote registration must happen on the main thread; do it whether or
            // not the alert permission was granted (a token is still useful for
            // silent/thread bookkeeping, and the user may enable alerts later).
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    /// APNs handed us a device token — pass it up to be shipped to the Mac.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        onDeviceToken?(deviceToken)
    }

    /// Registration failed (no push capability / no network / not provisioned yet).
    /// Non-fatal by design — Tier 1 still works and the next launch retries.
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[Pervio] remote notification registration failed (Tier-2 push off until "
              + "an APNs key + capability are set up): %@", String(reflecting: error))
    }

    /// Foreground presentation. Two sources land here and want opposite things:
    ///   * a LOCAL Tier-1 banner (CompletionNotifier) is posted precisely because
    ///     the user is away from that conversation — keep showing it (banner+sound);
    ///   * a REMOTE Tier-2 push that arrives while the app is OPEN is redundant (the
    ///     live app already reflects that state), so stay silent and don't interrupt.
    /// We tell them apart by the presence of an `aps` payload, which only a remote
    /// notification carries.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let isRemote = notification.request.content.userInfo["aps"] != nil
        completionHandler(isRemote ? [] : [.banner, .sound, .list])
    }

    /// The user TAPPED a notification — route to what it was about (the run's
    /// conversation, the workflow's monitor, home for the digest/approval), not
    /// merely to wherever the app happened to be. Only the default open action
    /// routes; a dismissed banner must not steer the app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            handleTap(userInfo: response.notification.request.content.userInfo)
        }
        completionHandler()
    }
}

/// Claude's brand palette (warm-dark variant). Terracotta accent on warm
/// near-black surfaces — matches the Claude consumer app's look.
/// Source hexes: accent #D97757, deep #C15F3C, dark #141413, mid-gray #B0AEA5.
enum Palette {
    static let accent     = Color(hex: 0xD97757)   // Claude terracotta
    static let accentDeep = Color(hex: 0xC15F3C)   // Crail (deeper)
    static let bg         = Color(hex: 0x1A1916)   // app background (warm near-black)
    static let surface    = Color(hex: 0x262421)   // chips, input, cards
    static let surface2   = Color(hex: 0x312D28)   // user bubble / elevated
    static let hairline   = Color(hex: 0x3A3631)
    static let midGray    = Color(hex: 0xB0AEA5)
}

extension Color {
    /// Build a Color from a 0xRRGGBB literal.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue:  Double(hex & 0xFF) / 255.0,
                  opacity: 1.0)
    }
}

extension View {
    /// Warm Claude background for a scrollable screen (List/ScrollView/Form).
    func pervioBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Palette.bg.ignoresSafeArea())
    }
}

/// Lightweight haptic feedback (key taps, send, upload).
enum Haptics {
    static func tick() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// Tier-1 "task finished" reminder: posts a local notification the moment the LIVE
/// app detects a Claude Code turn/run completing — banner+sound when you're away
/// from that conversation, a light haptic when you're watching it finish. It works
/// only while the app is running (foreground, or the brief background grace window);
/// once iOS suspends the app no code runs and the SSH socket is reclaimed, so a task
/// finishing then can't be caught here — that gap is what a server→APNs push closes.
///
/// A finished detached run can be seen by BOTH the live tail (ChatStore `.result`)
/// and RunMonitor's poll diff. `dedupeKey` (the runId) collapses that to one ping.
///
/// THE OTHER HALF OF THE DE-DUPE — the one that spans two processes. The Mac also
/// announces a finished detached run (pervio-run's wrapper) and a finished workflow
/// (pervio-orchestrate) straight to APNs, and the user was getting BOTH: the Mac's
/// lock-screen push AND this banner, side by side, for one piece of work. They
/// cannot be collapsed by talking to each other — the Mac's push is alert-only
/// (`pervio-push` `build_payload` sets no `content-available`), so a suspended app
/// is never told it arrived, and a suspended app is precisely the case the Mac's
/// push exists for. So the split is by OWNERSHIP instead: unless the Mac has told
/// us outright that it CAN'T push (`serverPush == .notReady`), it owns the banner
/// for anything it pushes about, and this notifier stands down to a haptic. Only an
/// explicit "the Mac can't push" (no APNs key, no uploaded token) hands the banner
/// back — `.unknown`, a probe that never finished, defers all the same, because
/// that in-flight window is exactly where RunMonitor's poll-after-wake used to fire
/// a second banner beside the Mac's push.
@MainActor
enum CompletionNotifier {
    private static var recent: [String: Date] = [:]

    /// Can the Mac's own lock-screen push reach this phone? THREE states, not two,
    /// because the old boolean flipped between only "yes" and "assume no" — and
    /// "assume no" was a lie in the one case that bit the user.
    ///
    /// The probe (`PushTokenStore.probePushReadiness`) is slow (an SSH round trip,
    /// gated behind an APNs token that iOS may deliver *after* the store is built,
    /// so it's dropped and only retried next launch) while RunMonitor's poll is
    /// fast — it notices a run that finished during suspend on the very first poll
    /// after we wake, which routinely lands BEFORE the probe answers. With the old
    /// boolean still `false` at that instant, RunMonitor posted its banner right
    /// beside the Mac's push: the double.
    ///
    /// So `.unknown` (never probed / probe failed / in flight) is now distinct from
    /// `.notReady` (the Mac ANSWERED that it can't push). For a DETACHED run —
    /// whose server-side wrapper pushes unconditionally the moment an APNs key and
    /// token exist — `.unknown` defers to that push (fail-closed): a live app that
    /// hasn't finished probing is overwhelmingly one whose probe is merely in
    /// flight, not one whose Mac is permanently mute, and a suspended-then-woken
    /// app is exactly where the Mac's push is the one that actually arrived. Only
    /// `.notReady`, an explicit "no", brings the local fallback banner back.
    enum ServerPushState { case unknown, ready, notReady }
    static var serverPush: ServerPushState = .unknown

    /// "Is the app in front right now." A seam, because a unit test has no
    /// UIApplication worth asking and the answer decides whether a suppressed
    /// banner still leaves a haptic behind.
    static var appIsActive: () -> Bool = { UIApplication.shared.applicationState == .active }

    /// Where a banner goes. Production hands it to iOS; a test swaps in a recorder,
    /// because UNUserNotificationCenter cannot be read back from a unit test (and a
    /// test that really posted would spray banners over the machine).
    static var deliver: (UNNotificationRequest) -> Void = { req in
        UNUserNotificationCenter.current().add(req)
    }

    /// First caller for a key within the window wins; later ones are dropped. A nil
    /// key means "no de-dupe" — independent completions (e.g. plain chat turns, which
    /// share a session id across turns and must each notify).
    private static func claim(_ key: String?) -> Bool {
        guard let key else { return true }
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 60 }   // prune
        if let t = recent[key], now.timeIntervalSince(t) < 30 { return false }
        recent[key] = now
        return true
    }

    /// Banner + sound for a task that finished while the user was NOT watching it
    /// (app backgrounded, or on another screen).
    ///
    /// `serverPushes` marks the completions the Mac ALSO announces by itself —
    /// detached runs and workflows. Plain chat turns are not among them (they only
    /// exist while the SSH channel is live, so no push is ever sent for one) and
    /// must keep bannering from here whatever the Mac can do.
    static func taskFinished(ok: Bool, project: String, summary: String,
                             dedupeKey: String?, serverPushes: Bool = false) {
        guard claim(dedupeKey) else { return }
        // A detached run / workflow: the Mac pushes it itself, so this banner stands
        // down UNLESS the Mac has explicitly said it can't (`.notReady`). `.unknown`
        // — the probe still in flight, or a token iOS dropped before the store could
        // ship it — now defers too: on a live-but-still-probing app the Mac's push
        // is the one that already arrived (this is the poll-after-wake case), so a
        // second banner here is the double. Only an outright "the Mac can't push"
        // brings the fallback back.
        if serverPushes && serverPush != .notReady {
            // Foreground, iOS hands the Mac's push to `willPresent` below, which
            // swallows it — so leave a light tap here rather than nothing at all.
            if appIsActive() { Haptics.tick() }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = ok ? L.taskFinishedTitle() : L.taskFailedTitle()
        if !project.isEmpty { content.subtitle = project }
        let body = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = body.isEmpty ? (ok ? L.taskFinishedBody() : L.taskFailedBody()) : body
        content.sound = .default
        let id = dedupeKey ?? UUID().uuidString
        deliver(UNNotificationRequest(identifier: "finish-\(id)", content: content, trigger: nil))
    }

    /// The user watched this finish on screen — no banner, just a light haptic, plus
    /// a claim so a trailing poll for the same run doesn't follow up with a banner.
    static func watched(dedupeKey: String?) {
        guard claim(dedupeKey) else { return }
        Haptics.tick()
    }
}

/// User-facing error text. Logs the full technical detail to the device log only
/// (never the UI) and returns a clean message, so server paths / usernames /
/// internals don't surface in the chat. Curated connection errors (which carry
/// actionable setup guidance) pass through; everything else gets `generic`.
func pervioErrorText(_ error: Error, _ generic: String) -> String {
    NSLog("[Pervio] %@ — %@", generic, String(reflecting: error))
    if let conn = error as? SSHService.ConnectionError { return conn.message }
    return generic
}
