import Foundation
import CryptoKit

/// Where the phone keeps what it remembers about ONE conversation — the folders
/// handed to it, the ones parked, whether the workflow tools are on, the
/// follow-ups waiting to be sent, its model / effort / permission.
///
/// All of it used to be filed under the conversation's id alone. An id is a
/// word the COMPUTER says — and a phone with two computers saved had no way to
/// tell two conversations of the same id apart: a computer that answered with
/// another one's id was handed that conversation's folders as writable, its
/// permission mode, and (worst) the follow-up the person had typed for the
/// other machine, sent on the spot (security review 2026-11-22, #3).
///
/// Now everything is filed under the computer AND the id. "The computer" is
/// the machine that proved who it is — its pinned host key — plus the account
/// logged into:
///   * two saved entries for one Mac (another folder, another name) are the
///     same conversations, and share their state as before;
///   * an address that changed (a new Wi-Fi, Tailscale instead of the LAN)
///     changes nothing;
///   * another machine cannot arrive at the same scope: it would have to hold
///     the first one's private host key to be connected to at all.
enum ConversationState {

    /// The machine and account `profile` talks to, as a short stable word.
    static func scope(of profile: ServerProfile) -> String {
        // "ssh-ed25519 AAAA… comment" → the type and the key; the comment is not identity.
        let key = profile.pinnedHostKey.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
        guard !key.isEmpty else {
            // Not pinned: it cannot be connected to (SSHService refuses), so it
            // has no conversations — but it still gets a scope of its own.
            return "p" + profile.id.uuidString.lowercased().prefix(16)
        }
        let digest = SHA256.hash(data: Data((key + "\n" + profile.username).utf8))
        return "m" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The kinds of state kept in UserDefaults; the raw value is the prefix an
    /// older build filed each under, followed by the id alone.
    enum Slot: String, CaseIterable {
        case granted = "pervio.xdirs.on"      // folders handed over (writable)
        case parked = "pervio.xdirs.off"      // folders the person told it to stop using
        case workflows = "pervio.ctx"         // the workflow tools' switch

        fileprivate var word: String {
            switch self { case .granted: return "on"; case .parked: return "off"; case .workflows: return "wf" }
        }
    }

    /// `pervio.conv.<scope>.<kind>.<id>`. A prefix no old key has, and the id
    /// LAST: an id is whatever the computer says, and no id — dots and all —
    /// can make one conversation's key spell another's, or an old one's.
    static func key(_ slot: Slot, scope: String, sid: String) -> String { "pervio.conv.\(scope).\(slot.word).\(sid)" }
    /// Where an older build kept it: the id alone.
    static func legacyKey(_ slot: Slot, sid: String) -> String { "\(slot.rawValue).\(sid)" }

    /// A setting's key in the saved-settings table (a table of its own, apart from the old one).
    static func paramsKey(scope: String, sid: String) -> String { "\(scope)|\(sid)" }

    /// The follow-up queue's file name (Application Support, protected). The id
    /// goes in as a hash: it is the computer's word, and must not be able to
    /// name a path (`../`) or another conversation's file.
    static func queueFileName(scope: String, sid: String) -> String {
        let h = SHA256.hash(data: Data(sid.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "pervio-q2-\(scope)-\(h).json"
    }
    /// The old file's name — only for an id that is a plain word, as every id
    /// an engine really issues is.
    static func legacyQueueFileName(sid: String) -> String? {
        let plain = !sid.isEmpty && sid.count <= 128
            && sid.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        return plain ? "pervio-queue-\(sid).json" : nil
    }
    static func legacyQueueDefaultsKey(sid: String) -> String { "pervio.pendingQueue.\(sid)" }

    // MARK: - What an older build left under the id alone

    /// Is `scope` the only computer this phone has saved? Then whatever was
    /// filed under an id alone can only be its own. `profilesData` is the saved
    /// server list as AppStore writes it.
    static func isOnlyScope(_ scope: String,
                            profilesData: Data? = UserDefaults.standard.data(forKey: "pervio.profiles.v1")) -> Bool {
        guard let profilesData,
              let saved = try? JSONDecoder().decode([ServerProfile].self, from: profilesData) else { return true }
        return saved.allSatisfy { self.scope(of: $0) == scope }
    }

    /// Bring a conversation's old id-only entries (folders, parked folders, the
    /// workflow switch) to where they belong, once, on the way into it.
    ///
    /// `sole`: this is the only computer saved, so they are its own — moved
    /// under its scope. Otherwise nobody can say whose they were, and they are
    /// dropped: a folder is handed over again with ＋, a switch is flipped
    /// again; neither is given to a computer on a guess. Either way the old
    /// entry is gone afterwards — never left for a later guess.
    static func adoptLegacy(scope: String, sid: String, sole: Bool, defaults: UserDefaults = .standard) {
        for slot in Slot.allCases {
            let old = legacyKey(slot, sid: sid)
            guard let value = defaults.object(forKey: old) else { continue }
            let new = key(slot, scope: scope, sid: sid)
            if sole, defaults.object(forKey: new) == nil { defaults.set(value, forKey: new) }
            defaults.removeObject(forKey: old)
        }
    }
}
