import Foundation

/// Read-only browsing of the server's Claude Code sessions, by running the
/// `pervio-sessions` helper over SSH and decoding its JSON.
@MainActor
final class SessionService: ObservableObject {
    private let profile: ServerProfile
    private let secret: String
    private let ssh = SSHService()
    private var connected = false

    init(profile: ServerProfile, secret: String) {
        self.profile = profile
        self.secret = secret
    }

    func disconnect() async {
        await ssh.disconnect()
        connected = false
    }

    /// The page that owned this service is gone: disconnect, and stay
    /// disconnected. `disconnect()` alone misses a connect still in flight —
    /// it closes nothing (there is no client yet), the connect then completes,
    /// and that authenticated session is never closed by anyone. A page that
    /// can be swapped for another computer's mid-connect (the "From" row,
    /// 2026-11-22) makes that an ordinary gesture.
    func close() async {
        closed = true
        await disconnect()
    }
    private var closed = false

    private func ensureConnected() async throws {
        guard !connected else { return }
        if closed { throw CancellationError() }
        try await ssh.connect(profile: profile, secret: secret)
        if closed {                 // the page went away while this was dialing
            await ssh.disconnect()
            throw CancellationError()
        }
        connected = true
    }

    /// A server file's bytes for the preview sheet (see SSHService.readServerFile).
    func readServerFile(path: String) async throws -> Data {
        try await ensureConnected()
        return try await ssh.readServerFile(profile: profile, path: path)
    }

    // Groups (pervio-group) — the create sheet lists conversations AND creates
    // the group over this one connection; GroupStore drives rounds itself.
    func groupCreate(dir: String, payload: Data) async throws -> ChatGroup {
        try await ensureConnected()
        return try await ssh.groupCreate(profile: profile, dir: dir, payload: payload)
    }
    func groupList(dir: String) async throws -> [ChatGroup] {
        try await ensureConnected()
        return try await ssh.groupList(profile: profile, dir: dir)
    }

    /// `scoped`: fenced to the server entry's working directory (the lists) or
    /// not (the Context panel: what you hand a conversation as INPUT is not
    /// fenced, like attaching a file — the same rule, 2026-10-17).
    func projects(scoped: Bool = true) async throws -> [ProjectInfo] {
        let fence = scoped ? " --under \(shq(profile.scopeDir))" : ""
        return try await run("\(profile.sessionsLauncher) projects\(fence)", as: [ProjectInfo].self)
    }

    /// The home page in one round trip: the folders worked in most recently
    /// under the entry's scope (each with its newest `per` conversations) and
    /// the scope folder's own newest `limit` conversations, pins riding along.
    func home(top: Int = 3, per: Int = 3, limit: Int = 10) async throws -> HomeFeed {
        try await run("\(profile.sessionsLauncher) home --dir \(shq(profile.scopeDir)) --top \(top) --per \(per) --limit \(limit)",
                      as: HomeFeed.self)
    }

    /// The notes, rules and memory files a folder's agents read on their own.
    func projectDocs(dir: String) async throws -> [ProjectDoc] {
        try await run("\(profile.sessionsLauncher) project-docs --dir \(shq(dir))", as: [ProjectDoc].self)
    }

    func sessions(dir: String) async throws -> [SessionSummary] {
        try await run("\(profile.sessionsLauncher) list --dir \(shq(dir))", as: [SessionSummary].self)
    }

    /// Cross-project full-text search (`pervio-sessions search`): case-insensitive
    /// literal substring over real conversation text, all projects, both backends.
    /// The query travels as ONE single-quoted shell word (shq) — regex
    /// metacharacters and quotes are literal text, never shell or pattern syntax.
    func search(query: String, limit: Int = 30, scoped: Bool = true) async throws -> [SessionSearchHit] {
        let fence = scoped ? " --under \(shq(profile.scopeDir))" : ""
        return try await run("\(profile.sessionsLauncher) search --query \(shq(query)) --limit \(limit)\(fence)",
                             as: [SessionSearchHit].self)
    }

    /// The services listening on the Mac right now (`pervio-ports list`),
    /// newest first — the web preview's menu. Rows with no usable port are dropped.
    func listeningPorts() async throws -> [ListeningPort] {
        try await run("\(profile.portsLauncher) list", as: [ListeningPort].self).filter { $0.port > 0 }
    }

    func transcript(dir: String, session: String) async throws -> [TranscriptTurn] {
        try await run("\(profile.sessionsLauncher) transcript --dir \(shq(dir)) --session \(shq(session))",
                      as: [TranscriptTurn].self)
    }

    /// One layer of the server file browser: run the embedded fs script's `ls`
    /// over THIS sheet-lifetime connection (same one-shot lifecycle as
    /// projects/sessions — one SSH call per layer, reconnect-once on a dropped
    /// link via `run`). Expected path failures (missing / permission) come back
    /// as the listing's in-band `error` code rather than a throw.
    /// `under` fences the listing to a folder: outside it the Mac answers
    /// {"error":"outside"}; at it, `atRoot`.
    func listDir(_ path: String, under: String? = nil) async throws -> ServerDirListing {
        try await run(SSHService.serverFsCommand("ls", path: path, under: under), as: ServerDirListing.self)
    }

    struct DeleteResult: Decodable { let deleted: Bool }
    struct PinsLedger: Decodable { let pins: [String: Double] }
    struct PinFlag: Decodable { let pinned: Bool }

    /// Replay the phone's pin outbox for `dir` ahead of a list (`pins-merge`
    /// for pins, `unpin` per unpin) — extra execs only when there is something
    /// to say; the steady state sends nothing.
    func replayPins(dir: String, plan: PinStore.FlushPlan) async throws {
        if !plan.merge.isEmpty {
            let body = try JSONSerialization.data(withJSONObject: plan.merge.mapValues { Int($0) })
            _ = try await run("\(profile.sessionsLauncher) pins-merge --dir \(shq(dir)) --b64 \(body.base64EncodedString())",
                              as: PinsLedger.self)
        }
        for id in plan.unpins {
            _ = try await run("\(profile.sessionsLauncher) unpin --session \(shq(id))", as: PinFlag.self)
        }
    }

    @discardableResult
    /// Name a conversation (empty = drop the name). `pervio-sessions meta`.
    func rename(session: String, title: String) async throws {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let arg = t.isEmpty ? "--clear-title" : "--title-b64 \(Data(t.utf8).base64EncodedString())"
        _ = try await run("\(profile.sessionsLauncher) meta --session \(shq(session)) \(arg)", as: MetaResult.self)
    }
    struct MetaResult: Decodable { let id: String; let title: String; let dirs: [String] }

    /// `backend`: the conversation's own agent — a Codex thread lives under
    /// ~/.codex, and without the flag the Mac looked for it among Claude's
    /// files, found nothing, and the row came back on the next load (2026-10-21).
    func delete(dir: String, session: String, backend: AgentBackend = .claude) async throws -> Bool {
        try await run(Self.deleteCommand(launcher: profile.sessionsLauncher, dir: dir, session: session, backend: backend),
                      as: DeleteResult.self).deleted
    }

    static func deleteCommand(launcher: String, dir: String, session: String, backend: AgentBackend) -> String {
        var cmd = "\(launcher) delete --dir \(SSHService.shellQuote(dir)) --session \(SSHService.shellQuote(session))"
        if backend != .claude { cmd += " --backend \(backend.rawValue)" }
        return cmd
    }

    private func run<T: Decodable>(_ command: String, as type: T.Type) async throws -> T {
        do {
            return try await attempt(command, as: type)
        } catch {
            // A cancelled task (sheet dismissed / newer search superseding this
            // one) must NOT retry: the exec layer ignores cancellation mid-await,
            // so a retry here would mint a fresh connection nobody will ever
            // disconnect and re-run the whole scan for a result nobody reads.
            if Task.isCancelled || error is CancellationError { throw error }
            // The SSH link may have silently dropped (sleep / network blip) while
            // our `connected` flag still said "yes". Reset and try once more with a
            // fresh login, so the user doesn't have to back out to reconnect.
            await disconnect()
            return try await attempt(command, as: type)
        }
    }

    private func attempt<T: Decodable>(_ command: String, as type: T.Type) async throws -> T {
        try await ensureConnected()
        let output = try await ssh.runCommand(command)
        let data = Data(extractJSON(output).utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// `pervio-sessions` prints exactly one JSON value to stdout, but be tolerant
    /// of any stray leading/trailing bytes by slicing from the first bracket.
    private func extractJSON(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.firstIndex(where: { $0 == "[" || $0 == "{" }),
           let close = trimmed.lastIndex(where: { $0 == "]" || $0 == "}" }),
           open <= close {
            return String(trimmed[open...close])
        }
        return trimmed
    }

    private func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
