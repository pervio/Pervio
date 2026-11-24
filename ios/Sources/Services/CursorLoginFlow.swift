import Foundation

/// Logging Cursor's agent in to its FILE credential store on the Mac — the
/// store an SSH session can read, unlike the keychain one (`Run security
/// unlock-keychain and try again`, 2026-10-16). The Mac side is
/// `pervio-provider cursor-login --start | --status | --cancel`; this is the
/// phone's half: start, hand the link to the browser, poll until the person
/// has signed in. Pure over two closures so the chat store, the settings page
/// and the tests drive the same loop.
struct CursorLoginState: Equatable {
    enum Phase: String { case idle, waiting, done, failed }
    var phase: Phase = .idle
    var url: URL? = nil
    var account: String = ""
    var error: String = ""
    /// ~/.cursor/auth.json is on the Mac (a file-store login exists).
    var login: Bool = false

    /// The verb's one-line JSON, tolerant of a noisy shell around it.
    static func parse(_ out: String) -> CursorLoginState? {
        guard let open = out.firstIndex(of: "{"), let close = out.lastIndex(of: "}"), open <= close,
              let o = try? JSONSerialization.jsonObject(with: Data(String(out[open...close]).utf8)) as? [String: Any],
              let phase = Phase(rawValue: (o["state"] as? String) ?? "")
        else { return nil }
        var s = CursorLoginState(phase: phase)
        if let u = o["url"] as? String, !u.isEmpty { s.url = URL(string: u) }
        s.account = (o["account"] as? String) ?? ""
        s.error = (o["error"] as? String) ?? ""
        s.login = (o["login"] as? Bool) ?? false
        return s
    }
}

enum CursorLoginFlow {
    static func command(_ launcher: String, _ action: String) -> String {
        "\(launcher) cursor-login --\(action) 2>&1; true"
    }

    /// Start the login, open its link, poll until done/failed or `timeout`.
    /// `run` executes one verb (start/status) and returns its stdout; `open`
    /// receives the link once. Returns the final state (a timeout is `failed`).
    static func run(run: (String) async throws -> String, open: (URL) -> Void,
                    poll: TimeInterval = 2, timeout: TimeInterval = 300) async -> CursorLoginState {
        do {
            guard let started = CursorLoginState.parse(try await run("start")) else {
                return CursorLoginState(phase: .failed, error: "cursor-login: no answer from the Mac")
            }
            if started.phase == .done { return started }
            guard started.phase == .waiting, let url = started.url else { return started }
            open(url)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
                if Task.isCancelled { break }
                guard let st = CursorLoginState.parse(try await run("status")) else { continue }
                if st.phase == .done || st.phase == .failed { return st }
                if st.phase == .idle { return CursorLoginState(phase: .failed, error: "login stopped") }
            }
            _ = try? await run("cancel")
            return CursorLoginState(phase: .failed, error: "timed out waiting for the sign-in")
        } catch {
            return CursorLoginState(phase: .failed, error: pervioErrorText(error, "SSH"))
        }
    }
}
