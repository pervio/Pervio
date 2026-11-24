import Foundation

/// Ships ONE Live Activity's APNs push token to the Mac, and takes it back when the
/// activity ends. Same SSH channel, same `~/.pervio/push/` tree, same fire-and-forget
/// manners as `PushTokenStore` — this is the per-activity sibling of that per-device
/// path.
///
/// WHY IT EXISTS. Every `Activity.end(...)` in this app runs in the APP PROCESS. Send
/// a Run, leave the app, and iOS suspends us within seconds; when the run finishes on
/// the Mac there is no Swift code left to end the card, so the Dynamic Island keeps
/// counting forever. The lock-screen banner still arrives because the Mac talks to
/// APNs directly — and an ActivityKit push is that same channel, addressed to a
/// SINGLE ACTIVITY instead of the device. That push needs this token.
///
/// WHERE IT LANDS. `~/.pervio/push/liveactivity/<runId>`, one hex token per file —
/// exactly what `pervio-push liveactivity --run <runId>` reads. The runId is the key
/// because it is the one identifier both ends already agree on: the phone gets it
/// from `pervio-run start`, and the Mac's run wrapper has it when the work finishes.
///
/// LIFECYCLE. Written when ActivityKit hands over a token (and again on rotation —
/// the token can change mid-activity), deleted when the activity ends. Both ends
/// delete: the phone here when it ends the card itself, and `pervio-push` after a
/// successful end push, so neither a crash nor a suspend can strand a dead token.
///
/// BEST-EFFORT, ALWAYS. Every failure is swallowed to the device log. The island is
/// a convenience; nothing user-facing may break because the Mac was unreachable for
/// a second, and the `staleDate` backstop in `RunLiveActivityController` covers the
/// case where the token never makes it at all.
@MainActor
final class LiveActivityTokenStore {
    /// The SSH seam — the real socket in the app, a `FakeSSH` in tests.
    private let ssh: any SSHCommanding

    init(ssh: any SSHCommanding = SSHService()) {
        self.ssh = ssh
    }

    /// Directory on the Mac. Unquoted `~` so the login shell expands it to the
    /// server's home (the same rule every other remote path here uses).
    private static let dir = "~/.pervio/push/liveactivity"

    /// A run id is a server-supplied string used as a FILENAME and inside a shell
    /// command, so it is VALIDATED down to `[A-Za-z0-9._-]` rather than merely
    /// escaped — it can neither traverse out of the directory nor reach the shell.
    /// Returns "" for anything left empty, which every caller treats as "do nothing".
    /// (pervio-run's ids are 12 hex chars, so this is a no-op in practice.)
    nonisolated static func sanitizeRunId(_ raw: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return String(raw.filter { allowed.contains($0) })
    }

    /// Make the dir (0700 — a push token is a bearer credential) and write the hex
    /// token to this run's file. `printf` rather than `echo`: no trailing newline, so
    /// the Mac reads the token back byte-identical.
    nonisolated static func uploadCommand(hexToken: String, runId: String) -> String {
        let file = "\(dir)/\(PushTokenStore.shq(runId))"
        return "mkdir -p \(dir) && chmod 700 ~/.pervio/push \(dir) 2>/dev/null; "
             + "printf '%s' \(PushTokenStore.shq(hexToken)) > \(file)"
    }

    /// Retire one spent token. `rm -f` so a token the server already cleaned up (it
    /// deletes the file after a successful end push) isn't an error.
    nonisolated static func clearCommand(runId: String) -> String {
        "rm -f \(dir)/\(PushTokenStore.shq(runId))"
    }

    /// Publish this activity's token so the Mac can end the card without us.
    /// Returns true only if it actually reached the server.
    @discardableResult
    func upload(token: Data, runId: String,
                profile: ServerProfile, secret: String?) async -> Bool {
        let hex = PushTokenStore.hex(token)
        let id = Self.sanitizeRunId(runId)
        guard !hex.isEmpty, !id.isEmpty else { return false }
        return await run(Self.uploadCommand(hexToken: hex, runId: id),
                         profile: profile, secret: secret, what: "upload")
    }

    /// Drop this activity's token — the activity is over and the token is dead.
    @discardableResult
    func clear(runId: String, profile: ServerProfile, secret: String?) async -> Bool {
        let id = Self.sanitizeRunId(runId)
        // An empty id would turn the command into `rm -f <dir>/''` — never send it.
        guard !id.isEmpty else { return false }
        return await run(Self.clearCommand(runId: id),
                         profile: profile, secret: secret, what: "clear")
    }

    /// One short-lived connection per call. Deliberately NOT the caller's live
    /// channel: that one is busy streaming a turn, and interleaving a token write
    /// into it would risk the thing the user is actually watching.
    private func run(_ command: String, profile: ServerProfile, secret: String?,
                     what: String) async -> Bool {
        guard let secret, !secret.isEmpty else { return false }
        do {
            try await ssh.connect(profile: profile, secret: secret)
            _ = try await ssh.runCommand(command)
            await ssh.disconnect()
            return true
        } catch {
            NSLog("[Pervio] live-activity token %@ failed (island may linger until it "
                  + "goes stale): %@", what, String(reflecting: error))
            await ssh.disconnect()
            return false
        }
    }
}
