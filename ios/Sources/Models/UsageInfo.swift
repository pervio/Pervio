import Foundation

/// A usage snapshot from `pervio-sessions usage` — ONE agent's quota, never a mix.
///
/// The two backends bill against completely separate pools, and they don't even
/// share a source: Claude's 5-hour / 7-day windows come from the OAuth endpoint
/// (`usage`), while Codex's plan window is stamped onto every `token_count` line
/// of its own rollout and read back with `usage --backend codex` — no network.
/// `utilization` is a 0–100 percentage; `resetsAt` is ISO8601 in both shapes
/// (the server converts codex's epoch seconds so one parser serves both).
/// Decoded with `.convertFromSnakeCase` (five_hour → fiveHour, resets_at → resetsAt).
struct UsageInfo: Decodable, Equatable {
    struct Window: Decodable, Equatable {
        let utilization: Double?
        let resetsAt: String?
    }
    /// A model-scoped pool from the endpoint's `limits` array — e.g. Fable's
    /// own weekly cap, which moves independently of the overall windows
    /// (verified live: Fable at 91% critical while 7d showed a calm 51%).
    /// Old servers omit the field entirely.
    struct ScopedPool: Decodable, Equatable {
        let name: String
        let percent: Double?
        let resetsAt: String?
        let severity: String?
    }
    // Claude's pools.
    let fiveHour: Window?
    let sevenDay: Window?
    let scoped: [ScopedPool]?
    // Codex's single-window form: the plan's weekly cap (`rate_limits`, picked by
    // window_minutes == 10080) plus the plan's name. Nil on a claude answer.
    let weekly: Window?
    let plan: String?
    /// The server answered from an OLD cache (its live call failed and it fell
    /// back). True means "real numbers, old clock" — the line renders dimmed
    /// with a 旧 marker instead of presenting last week as now, which is
    /// exactly what shipped once (a 7-day-old「Fable 80%」against a live 38%).
    /// Absent on fresh answers and on old servers.
    let stale: Bool?

    init(fiveHour: Window? = nil, sevenDay: Window? = nil, scoped: [ScopedPool]? = nil,
         weekly: Window? = nil, plan: String? = nil, stale: Bool? = nil) {
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.scoped = scoped
        self.weekly = weekly; self.plan = plan; self.stale = stale
    }

    /// Keep only the pools that belong to `backend`; nil when none do.
    ///
    /// The App filters instead of trusting the answer, because a percentage in
    /// this line reads as a fact about the conversation you're looking at: 5h/7d
    /// on a codex chat says "your Claude week" while spending an OpenAI plan, and
    /// an older server — which answers `usage` with claude's pools no matter who
    /// asked — would do exactly that. Cross-pool contamination is a lie the user
    /// cannot detect, so it's cut here, at the last point before the pixels.
    func pools(for backend: AgentBackend) -> UsageInfo? {
        switch backend {
        case .claude:
            guard fiveHour != nil || sevenDay != nil || scoped != nil else { return nil }
            return UsageInfo(fiveHour: fiveHour, sevenDay: sevenDay, scoped: scoped,
                             stale: stale)
        case .codex:
            guard weekly != nil else { return nil }
            return UsageInfo(weekly: weekly, plan: plan, stale: stale)
        case .cursor:
            return nil                               // Cursor reports tokens per turn, no quota
        }
    }
}
