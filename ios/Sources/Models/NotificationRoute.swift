import Foundation

/// Where a tapped notification should land the user. Parsed from the push's
/// `thread-id` — the server already stamps one on every push it sends
/// (`pervio-run-<runId>`, `pervio-wf-<wfId>`, `pervio-digest`,
/// `pervio-approve`, `pervio-deploy`), so the route rides data that is ALREADY
/// on the wire: no payload change, no server/app ship-together dance, and a
/// push from an older Mac routes exactly as well as a new one's.
///
/// `.home` is a real destination, not a fallback: the digest strip and the
/// recent conversations live on the home page, so 晨报/审批/发版 taps land
/// there by design. A thread we don't recognize parses to nil — the tap then
/// just opens the app wherever it was, which is yesterday's behavior and the
/// right thing for a notification we can't place.
enum NotificationRoute: Equatable {
    /// A detached run finished — open the conversation it belongs to (resolved
    /// to a dir + session by asking the Mac's run list at tap time).
    case run(String)
    /// A workflow finished / failed — open its monitor.
    case workflow(String)
    /// 晨报送达 / 审批等待 / 发版完成 — the home page is where those live.
    case home

    /// The wire form: a remote push's `userInfo["aps"]["thread-id"]`.
    static func parse(userInfo: [AnyHashable: Any]) -> NotificationRoute? {
        guard let aps = userInfo["aps"] as? [String: Any],
              let thread = aps["thread-id"] as? String else { return nil }
        return parse(thread: thread)
    }

    static func parse(thread: String) -> NotificationRoute? {
        if thread.hasPrefix("pervio-run-") {
            let id = String(thread.dropFirst("pervio-run-".count))
            return id.isEmpty ? nil : .run(id)
        }
        if thread.hasPrefix("pervio-wf-") {
            let id = String(thread.dropFirst("pervio-wf-".count))
            return id.isEmpty ? nil : .workflow(id)
        }
        switch thread {
        case "pervio-digest", "pervio-approve", "pervio-deploy": return .home
        default: return nil
        }
    }
}
