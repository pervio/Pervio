import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Uploads this device's APNs token to the Mac over the SAME SSH channel the app
/// already uses — no third-party push service, no extra network permission. The
/// Mac's `pervio-push` later reads these files to reach the phone through Apple.
///
/// WHERE IT LANDS. `~/.pervio/push/tokens/<device>` on the server, one hex token
/// per file. The filename is this install's `identifierForVendor`, so:
///   * re-registering (every launch) OVERWRITES the same file — no pile-up;
///   * a token ROTATION (Apple issues a new one) writes new bytes to that file,
///     which we detect and re-upload;
///   * two different phones are two different files — the Mac fans out to both.
/// The phone's language rides the same command into `~/.pervio/push/lang` — the
/// file every server-authored push body branches on, so the Mac's lock-screen
/// copy follows the app's Settings toggle instead of staying Chinese forever.
///
/// CHEAP BY DEFAULT. iOS hands us a token on every launch, but it rarely changes.
/// We remember the last hex we successfully uploaded (per device, in UserDefaults)
/// and skip the whole SSH round trip when it's unchanged — so a normal launch
/// costs nothing, and only an actual rotation opens a connection.
///
/// BEST-EFFORT. A failed upload is swallowed (logged to the device log only): the
/// phone still works, and the next launch retries. Nothing user-facing depends on
/// this succeeding right now.
@MainActor
final class PushTokenStore {
    /// The SSH seam — the real socket in the app, a `FakeSSH` in tests.
    private let ssh: any SSHCommanding
    /// Remembers the last hex uploaded, keyed per device id, so an unchanged token
    /// is a no-op. Injected so a test can start from a clean slate.
    private let defaults: UserDefaults

    /// Overridable so a test doesn't depend on the simulator's vendor id.
    private let deviceId: String

    init(ssh: any SSHCommanding = SSHService(),
         defaults: UserDefaults = .standard,
         deviceId: String? = nil) {
        self.ssh = ssh
        self.defaults = defaults
        self.deviceId = PushTokenStore.sanitizeDeviceId(deviceId ?? PushTokenStore.vendorId())
    }

    /// APNs gives the token as raw bytes; the wire/file form is lowercase hex.
    nonisolated static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    private static func vendorId() -> String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        #else
        return "unknown-device"
        #endif
    }

    /// This phone's id as the Mac files its push token under — what a run is
    /// tagged with when started here, so its completion push reaches only this
    /// phone (`pervio-run start --device`, `pervio-push send --device`).
    static var currentDeviceId: String { sanitizeDeviceId(vendorId()) }

    /// A filename safe to drop into a shell command and a directory listing: only
    /// `[A-Za-z0-9._-]`, never empty. (identifierForVendor is already a UUID, but a
    /// future override must not be able to smuggle a path or a shell metacharacter.)
    nonisolated static func sanitizeDeviceId(_ raw: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let cleaned = String(raw.filter { allowed.contains($0) })
        return cleaned.isEmpty ? "unknown-device" : cleaned
    }

    /// Keyed per device AND per server: the token has to reach EVERY Mac the
    /// app talks to. When the memo was per device only, a token uploaded to the
    /// first Mac counted as "done" for a second one — the new mini never got
    /// it, and every push from there was a silent no-op (2026-10-13).
    private func lastUploadedKey(_ profile: ServerProfile) -> String {
        "pervio.push.token.\(deviceId).\(profile.id.uuidString)"
    }

    /// What the memo remembers: everything the sync command writes — token AND
    /// language, because a change to EITHER must reopen the connection. When the
    /// memo was hex alone, a Settings language flip with an unchanged token was
    /// "already uploaded", and the Mac kept pushing in the old language forever.
    /// (An old install's pure-hex memo never equals a combined one, so the first
    /// launch after this change re-syncs once and provisions the lang file.)
    private func memo(_ hexToken: String, _ lang: String) -> String {
        hexToken + "|" + lang
    }

    /// Upload `token` (and the phone's language) to `profile` if either differs
    /// from the last sync. Returns true if it actually wrote to the server, false
    /// if it was skipped (unchanged) or failed. Never throws — this is
    /// fire-and-forget from the app delegate.
    @discardableResult
    func uploadIfNeeded(deviceToken token: Data,
                        profile: ServerProfile,
                        secret: String?,
                        lang: String = PromptLanguage.current.rawValue) async -> Bool {
        let hexToken = PushTokenStore.hex(token)
        guard !hexToken.isEmpty else { return false }
        return await sync(hexToken: hexToken, profile: profile, secret: secret, lang: lang)
    }

    /// The Settings language toggle flipped with no APNs callback in sight, so
    /// there is no fresh token Data to upload — re-run the sync with the
    /// REMEMBERED hex instead. Silent no-op when nothing was ever uploaded (the
    /// launch path will carry the language once a token exists) or when the
    /// language hasn't actually changed.
    @discardableResult
    func resyncLanguageIfNeeded(profile: ServerProfile, secret: String?,
                                lang: String = PromptLanguage.current.rawValue) async -> Bool {
        guard let remembered = defaults.string(forKey: lastUploadedKey(profile)),
              let hexToken = remembered.split(separator: "|").first.map(String.init),
              !hexToken.isEmpty else { return false }
        return await sync(hexToken: hexToken, profile: profile, secret: secret, lang: lang)
    }

    private func sync(hexToken: String, profile: ServerProfile,
                      secret: String?, lang: String) async -> Bool {
        // Unchanged since last success → skip the round trip entirely.
        if defaults.string(forKey: lastUploadedKey(profile)) == memo(hexToken, lang) { return false }
        guard let secret, !secret.isEmpty else { return false }

        do {
            try await ssh.connect(profile: profile, secret: secret)
            _ = try await ssh.runCommand(Self.uploadCommand(hexToken: hexToken,
                                                            deviceId: deviceId,
                                                            lang: lang))
            defaults.set(memo(hexToken, lang), forKey: lastUploadedKey(profile))
            await ssh.disconnect()
            return true
        } catch {
            NSLog("[Pervio] push-token upload failed — will retry next launch: %@",
                  String(reflecting: error))
            await ssh.disconnect()
            return false
        }
    }

    /// Ask the Mac whether a push from it would actually reach a phone, and record
    /// the answer in `CompletionNotifier.serverPush`.
    ///
    /// WHY THE APP NEEDS TO KNOW. The Mac announces every finished detached run and
    /// workflow to APNs by itself. While it can do that, the app must NOT post its
    /// own banner for the same event — that pair, arriving together, is the double
    /// notification the user saw. But the Mac only pushes once an APNs key and a
    /// device token are both in place, and until then the app's banner is the ONLY
    /// notice there is. So the app asks, rather than assumes, and re-asks on every
    /// launch (the key can be provisioned — or revoked — between two of them).
    ///
    /// `pervio-push check` is the Mac's own answer to exactly this question; it
    /// exits 0 for READY and 1 otherwise, so the shell reduces it to one word and a
    /// server too old to have the subcommand simply reports OFF.
    ///
    /// THREE outcomes, not two. A clean READY sets `.ready`; an explicit OFF (a
    /// reachable Mac that answered "no key / no token") sets `.notReady`, which is
    /// the ONE state that re-arms the local fallback banner. A probe we couldn't
    /// even run — no reachable server, a thrown SSH error, or (the launcher off the
    /// happy path) neither marker in the output — leaves the state `.unknown`: we
    /// must NOT downgrade to `.notReady` on a mere failure, because `.notReady`
    /// would turn the local banner back on and re-create the double the moment the
    /// Mac's push is in fact working (the failure was our probe, not its push).
    @discardableResult
    func probePushReadiness(profile: ServerProfile, secret: String?) async -> CompletionNotifier.ServerPushState {
        guard let secret, !secret.isEmpty else { return CompletionNotifier.serverPush }
        var state: CompletionNotifier.ServerPushState = .unknown
        do {
            try await ssh.connect(profile: profile, secret: secret)
            let out = try await ssh.runCommand(Self.readinessCommand(profile: profile))
            if out.contains("PERVIO-PUSH-READY") { state = .ready }
            else if out.contains("PERVIO-PUSH-OFF") { state = .notReady }
            // Neither marker (garbled output / a launcher that isn't ours) → keep
            // `.unknown`: don't let noise masquerade as a definite "can't push".
        } catch {
            NSLog("[Pervio] push-readiness probe failed — leaving readiness UNKNOWN "
                  + "(the Mac may well be pushing; a failed probe must not re-enable "
                  + "the local banner and double it): %@", String(reflecting: error))
        }
        await ssh.disconnect()
        // A successful probe overwrites whatever was there; a failure preserves the
        // last known state (a prior launch may have established `.ready`).
        if state != .unknown { CompletionNotifier.serverPush = state }
        return CompletionNotifier.serverPush
    }

    /// One word back, whatever happens: the markers are printed only on a clean
    /// `check` (READY) or a clean non-zero exit (OFF). `2>/dev/null` keeps the
    /// human-readable status report out of it.
    nonisolated static func readinessCommand(profile: ServerProfile) -> String {
        "\(profile.pushLauncher) check >/dev/null 2>&1 "
            + "&& echo PERVIO-PUSH-READY || echo PERVIO-PUSH-OFF"
    }

    /// The one remote command: make the tokens dir (0700), write the hex token to
    /// this device's file, and record the phone's language beside it — the file
    /// every server-authored push body (pervio-run, pervio-orchestrate,
    /// pervio-approve) branches on. One round trip for both, because they change
    /// together or not at all. All interpolations are shell-quoted; `~` is left
    /// UNQUOTED so the login shell expands it to the server's home (same rule the
    /// upload/launcher paths use elsewhere).
    nonisolated static func uploadCommand(hexToken: String, deviceId: String,
                                          lang: String) -> String {
        let dir = "~/.pervio/push/tokens"
        let file = "\(dir)/\(shq(deviceId))"
        return "mkdir -p \(dir) && chmod 700 ~/.pervio/push ~/.pervio/push/tokens 2>/dev/null; "
             + "printf '%s' \(shq(hexToken)) > \(file); "
             + "printf '%s' \(shq(lang)) > ~/.pervio/push/lang"
    }

    /// Single-quote for the remote shell, escaping embedded quotes — the exact
    /// idiom SSHService uses so tokens/ids can never break out of the command.
    nonisolated static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
