import Foundation
import Combine

/// The phone's view of "pin this conversation" — since 2026-09-08 a CACHE of the
/// Mac's pin ledger plus an OUTBOX of taps, not the truth itself.
///
/// WHY IT MOVED. Pins used to live only here, in this phone's UserDefaults: a
/// decoration no deleter on the Mac could see, so a pinned conversation vanished
/// as silently as any other — and a reinstall wiped the pins themselves. The Mac
/// now keeps `~/.pervio/chat/pins.json`; `pervio-sessions list` stamps every row
/// with `pinned`/`pinnedAt`, and `delete` refuses a pinned id.
///
/// HOW THE TWO STAY IN STEP, with no extra round trip in the steady state:
///  * a swipe flips the cache immediately (optimistic) AND records an op here;
///  * every session-list load first replays this scope's outbox (`pins-merge`
///    for pins, `unpin` per unpin), then lists, then `absorb`s the rows: the
///    server's flag overwrites the cache for every listed row, EXCEPT rows with
///    an op still in flight — local intent wins until it has landed;
///  * MIGRATION: pins made before the ledger existed have no outbox entry. Until
///    a (profile, dir) scope has completed its first replay, every cached pin in
///    it counts as a pending pin (so the first list uploads them) and server rows
///    may NOT overwrite the cache — otherwise the first post-upgrade list, seeing
///    `pinned:false` from a Mac that never heard of them, would erase the user's
///    pins client-side before they ever reached the ledger.
///
/// THE KEY is unchanged — profile id + directory + session id joined by U+0001,
/// a control character absent from UUIDs, POSIX paths and session ids — and it
/// is SPLITTABLE, so the outbox recovers dir and session id from it and the
/// views keep calling plain `togglePin(key)`.
///
/// `defaults` is injected (default `.standard`) so tests run against an isolated
/// suite and never touch the real app's domain.
@MainActor
final class PinStore: ObservableObject {
    struct PendingOp: Codable, Equatable {
        let sessionId: String
        let dir: String
        let pin: Bool
        let at: Double
    }
    /// What one list load must tell the Mac before listing one (profile, dir).
    struct FlushPlan: Equatable {
        var merge: [String: Double] = [:]   // session id → pinnedAt (unix seconds)
        var unpins: [String] = []
        var isEmpty: Bool { merge.isEmpty && unpins.isEmpty }
    }

    /// key → the instant it was pinned (unix seconds). `@Published` so a swipe
    /// re-sorts and re-marks the rows that observe this store.
    @Published private(set) var pins: [String: Double] = [:]
    /// key → the latest unflushed tap on that conversation.
    @Published private(set) var pending: [String: PendingOp] = [:]
    /// Scopes ("profileId U+0001 dir") whose first replay has completed.
    private(set) var migrated: Set<String> = []

    private let defaults: UserDefaults
    private let storageKey = "pervio.pinnedSessions.v1"
    private let pendingKey = "pervio.pinOps.v1"
    private let migratedKey = "pervio.pinMigrated.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// The one true key for a conversation, shared by both session lists.
    nonisolated static func key(profileId: UUID, dir: String, sessionId: String) -> String {
        "\(profileId.uuidString)\u{1}\(dir)\u{1}\(sessionId)"
    }
    nonisolated static func scope(profileId: UUID, dir: String) -> String {
        "\(profileId.uuidString)\u{1}\(dir)"
    }
    /// The inverse of `key`; nil for a malformed key.
    nonisolated static func parts(of key: String) -> (scope: String, dir: String, sessionId: String)? {
        let p = key.split(separator: "\u{1}", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 3 else { return nil }
        return (p[0] + "\u{1}" + p[1], p[1], p[2])
    }

    func isPinned(_ key: String) -> Bool { pins[key] != nil }

    /// The pin instant for ordering pinned rows (most-recent first), or nil.
    func pinnedAt(_ key: String) -> Double? { pins[key] }

    /// Flip a conversation's pin: the cache changes now, the Mac hears about it
    /// on the next list load of that scope. Persists immediately.
    func togglePin(_ key: String, now: Date = Date()) {
        let willPin = pins[key] == nil
        let at = now.timeIntervalSince1970
        if willPin { pins[key] = at } else { pins.removeValue(forKey: key) }
        if let p = Self.parts(of: key) {
            pending[key] = PendingOp(sessionId: p.sessionId, dir: p.dir, pin: willPin, at: at)
        }
        persist()
    }

    /// Everything the Mac has not heard yet for this scope — plus, before the
    /// scope's first replay, every pre-ledger pin cached for it (the migration).
    func flushPlan(profileId: UUID, dir: String) -> FlushPlan {
        let scope = Self.scope(profileId: profileId, dir: dir)
        var plan = FlushPlan()
        for (key, op) in pending where Self.parts(of: key)?.scope == scope {
            if op.pin { plan.merge[op.sessionId] = op.at } else { plan.unpins.append(op.sessionId) }
        }
        if !migrated.contains(scope) {
            for (key, at) in pins {
                guard let p = Self.parts(of: key), p.scope == scope, pending[key] == nil else { continue }
                plan.merge[p.sessionId] = at
            }
        }
        plan.unpins.sort()
        return plan
    }

    /// The replay landed: drop this scope's outbox and count it migrated.
    func markFlushed(profileId: UUID, dir: String) {
        let scope = Self.scope(profileId: profileId, dir: dir)
        pending = pending.filter { Self.parts(of: $0.key)?.scope != scope }
        migrated.insert(scope)
        persist()
    }

    /// Take the Mac's word for every listed row of a migrated scope — except
    /// rows whose tap is still in flight, and rows an older server left unstamped.
    func absorb(_ rows: [SessionSummary], profileId: UUID, dir: String) {
        let scope = Self.scope(profileId: profileId, dir: dir)
        guard migrated.contains(scope) else { return }
        var changed = false
        for row in rows {
            guard let flag = row.pinned else { continue }
            let key = Self.key(profileId: profileId, dir: dir, sessionId: row.id)
            if pending[key] != nil { continue }
            if flag {
                let at = Double(row.pinnedAt ?? Int(Date().timeIntervalSince1970))
                if pins[key] != at { pins[key] = at; changed = true }
            } else if pins[key] != nil {
                pins.removeValue(forKey: key); changed = true
            }
        }
        if changed { persist() }
    }

    /// Reorder `items` "pinned first": pinned rows lead, most-recently pinned at
    /// the very top; the unpinned keep the caller's order (a stable partition).
    func sortedPinnedFirst<Item>(_ items: [Item],
                                 keyFor: (Item) -> String) -> [Item] {
        items.enumerated().sorted { lhs, rhs in
            let lp = pins[keyFor(lhs.element)]
            let rp = pins[keyFor(rhs.element)]
            switch (lp, rp) {
            case let (l?, r?):  return l != r ? l > r : lhs.offset < rhs.offset
            case (.some, nil):  return true
            case (nil, .some):  return false
            case (nil, nil):    return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            pins = decoded
        }
        if let data = defaults.data(forKey: pendingKey),
           let decoded = try? JSONDecoder().decode([String: PendingOp].self, from: data) {
            pending = decoded
        }
        if let data = defaults.data(forKey: migratedKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            migrated = Set(decoded)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pins) { defaults.set(data, forKey: storageKey) }
        if let data = try? JSONEncoder().encode(pending) { defaults.set(data, forKey: pendingKey) }
        if let data = try? JSONEncoder().encode(Array(migrated)) { defaults.set(data, forKey: migratedKey) }
    }
}
