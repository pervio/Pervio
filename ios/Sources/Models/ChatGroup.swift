import Foundation

/// A project's "group" as pervio-group stores it on the Mac: one primary
/// conversation plus partners that answer the same message in parallel; the
/// primary synthesises each round and the synthesis flows back. The phone
/// never owns this state — it sends `say` and polls `tick`.
struct ChatGroup: Codable, Identifiable, Hashable {
    struct Member: Codable, Hashable {
        var session: String          // "" until the first run creates the conversation
        var backend: String          // "claude" | "codex"
        var model: String?
        var effort: String?
        var perm: String?
        var sandbox: String?
        var agent: AgentBackend { backend == "codex" ? .codex : .claude }
        /// Can this member change files? Claude: any mode but plan; Codex: any
        /// sandbox but read-only. Missing = the engine's default, which writes.
        var canWrite: Bool {
            agent == .codex ? (sandbox ?? "workspace-write") != "read-only" : (perm ?? "default") != "plan"
        }
    }
    /// Duo mode (双窗): which window is answering now (`live`, key → run) and
    /// each window's last finished run (`last`) — what a critique quotes.
    struct Duo: Codable, Hashable {
        var live: [String: String]
        var last: [String: String]
    }
    struct Round: Codable, Hashable {
        var n: Int
        var state: String            // idle | answering | synthesizing | relaying | done
        var text: String
        var runs: [String: String]
        var answers: [String: String]
        var synthRun: String
        var synth: String
        var relayRuns: [String: String]
        var isBusy: Bool { ["answering", "synthesizing", "relaying"].contains(state) }
    }
    /// Watch mode (监督) is a review loop: one message from the person = one
    /// TASK; each round the primary works, then the watcher reviews and ends
    /// with a verdict (通过 / 继续 / 需要你). Cap 3 rounds.
    struct WatchRound: Codable, Hashable {
        var round: Int
        var p: String            // the primary's run
        var w: String            // the watcher's run ("" until the review starts)
        var verdict: String      // "" | 通过 | 继续 | 需要你
        var text: String         // the watcher's words for this round
    }
    struct WatchDecision: Codable, Hashable {
        var question: String
        var answer: String
    }
    struct WatchTask: Codable, Hashable {
        var n: Int
        var goal: String
        var round: Int
        var state: String        // working | reviewing | passed | waiting | capped | failed | stopped
        var rounds: [WatchRound]
        var question: String     // the 需要你 question
        var decision: WatchDecision?
        var summary: String      // the 通过 summary
        var error: String
        var isBusy: Bool { state == "working" || state == "reviewing" }
        var isEnded: Bool { !isBusy }
    }
    struct Watch: Codable, Hashable {
        var task: WatchTask?
        var history: [WatchTask]?
    }
    let id: String
    var dir: String
    var mode: String
    var autoSynth: Bool
    var maxRounds: Int
    var primary: Member
    var members: [Member]
    var createdAt: Int
    var round: Round
    /// Bumped by the Mac on every change (round opened, answer in, synthesis,
    /// a private word) — the phone refreshes its panes when it moves.
    var rev: Int?
    /// Last round's synthesis; rides into the partners' next round.
    var lastSynth: String?
    var watch: Watch?
    var duo: Duo?
    var isWatch: Bool { mode == "watch" }
    var isDuo: Bool { mode == "duo" }
    /// "parallel" on the wire; 头脑风暴 to the person.
    var isBrainstorm: Bool { mode == "parallel" }
    var task: WatchTask? { watch?.task }
    /// Something is going on that the page should keep polling for.
    var watchActive: Bool { isWatch && task?.isBusy == true }
    var duoActive: Bool { isDuo && !(duo?.live.isEmpty ?? true) }
    /// Any mode: a run of the group's is in flight.
    var isActive: Bool { round.isBusy || watchActive || duoActive }
    func isLive(_ key: String) -> Bool { duo?.live[key] != nil }
    func hasReply(_ key: String) -> Bool { duo?.last[key] != nil }
    /// Members that can change files — two or more share one directory.
    var writers: [String] { keyedMembers.filter { $0.member.canWrite }.map(\.key) }

    /// Positional keys as the Mac addresses members: "p", then "m0", "m1" …
    var keyedMembers: [(key: String, member: Member)] {
        [("p", primary)] + members.enumerated().map { ("m\($0.offset)", $0.element) }
    }
}

/// What a user turn delivered by a group was — the header's `from=`, as the
/// phone names it. "human" is the person's own words (a normal bubble); every
/// other kind is text the GROUP composed, folded to one line in the transcript.
enum GroupVia {
    static func label(_ via: String) -> String {
        switch via {
        case "synth":    return L.groupViaSynth()
        case "relay":    return L.groupViaRelay()
        case "watcher":  return L.groupViaWatcher()
        case "review":   return L.groupViaReview()
        case "fix":      return L.groupViaFix()
        case "critique": return L.groupViaCritique()
        default:         return L.groupViaHuman()
        }
    }
    /// Composed by the system (or on the person's tap), not typed: fold it.
    static func isInjected(_ via: String?) -> Bool { via != nil && via != "human" }
}
