import Foundation
import SwiftUI

// One-off transfers between two of the person's computers, through the phone
// (2026-11-22, the person's ask: "多个电脑之间做配合…通过手机做中转").
//
// The phone is the only thing that can reach both: it reads from the computer
// a pick came from and writes to the computer the conversation runs on; the
// two computers never talk to each other. A file is read with plain shell, so
// nothing has to be installed where it comes from. A conversation is read with
// that computer's own `pervio-sessions` — the scripts every saved computer
// gets; the Context page brings them up to this build if its listing fails.
// What is carried is a COPY made at that moment — a file, or a conversation's
// text — landing in the uploads folder like anything attached from the phone.

/// Another saved computer a pick came from.
struct RemoteSource: Equatable {
    let profile: ServerProfile
    let secret: String
    var name: String { profile.name }
}

/// What the strip above the composer is doing right now. One strip for every
/// way something gets attached; a pick from another computer walks through
/// connecting → reading → delivering, and the percentage belongs to the stage
/// shown (it starts over with each).
enum TransferStage: Equatable {
    /// This computer is getting it ready (reading a conversation, copying a
    /// file): nothing to count.
    case preparing
    /// Phone → this computer.
    case uploading
    /// Dialing the other computer (its name).
    case connecting(String)
    /// Asking the other computer (its name) for something that arrives in one
    /// piece — a conversation's latest turns: nothing to count yet.
    case asking(String)
    /// The other computer (its name) → phone, piece by piece.
    case reading(String)
    /// Phone → this computer (its name): the second leg of a pick that came
    /// from another one.
    case delivering(String)

    /// Whether the stage has a percentage to show.
    var counts: Bool {
        switch self {
        case .preparing, .connecting, .asking: return false
        case .uploading, .reading, .delivering: return true
        }
    }

    func label(percent: Int, _ lang: PromptLanguage = .current) -> String {
        switch self {
        case .preparing: return L.transferPreparing(lang)
        case .uploading: return L.transferUploading(percent, lang)
        case .connecting(let name): return L.transferConnecting(name, lang)
        case .asking(let name): return L.transferAsking(name, lang)
        case .reading(let name): return L.transferReading(name, percent, lang)
        case .delivering(let name): return L.transferDelivering(name, percent, lang)
        }
    }
}

/// The saved computers, for the pickers that can read from another one. An
/// environment VALUE and not the app store itself: the composer must not
/// re-render with every change the store publishes, and a view hosted without
/// it (a test, a preview) simply offers no other computer.
private struct SavedServersKey: EnvironmentKey {
    static let defaultValue: [ServerProfile] = []
}
extension EnvironmentValues {
    var savedServers: [ServerProfile] {
        get { self[SavedServersKey.self] }
        set { self[SavedServersKey.self] = newValue }
    }
}

/// Reading from the other computer: plain shell over one-shot commands, so it
/// works on a computer whose Pervio scripts are old or absent.
enum RemoteRead {
    /// The most one file may be. The same ceiling as an upload from the phone
    /// (`pervio-upload`'s MAX_BYTES) — whatever is read has to be written to
    /// the other side next.
    static let fileCap = 8 * 1024 * 1024
    /// Raw bytes per round trip: about 350 KB of base64 a reply, 32 round trips
    /// for the largest file. Small enough for the percentage to move and for a
    /// cancel to take effect, large enough not to crawl.
    static let chunkBytes = 256 * 1024

    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// What the other computer says a picked path IS.
    struct Found: Equatable {
        let size: Int
        /// The file itself: the picked path with every link in it followed.
        let real: String
        /// Its inode there. Every block is read from the file with this
        /// number at `real`, or the read stops.
        let inode: String
        /// The picked name is a link to a file OUTSIDE the folder it was
        /// picked in. A repository can carry `notes.txt` that is a link to a
        /// private key (security review 2026-11-22, #5): the person is told
        /// where it leads and asked, before a byte is read. A link that stays
        /// inside its folder is just the file; so is every file of a folder
        /// that is itself reached through a link (OneDrive makes ~/Documents
        /// one) — the folder the person is looking at is where they chose to be.
        let leavesItsFolder: Bool
    }

    /// Follows the picked path's links (40 at most), then says what is there:
    /// PERVIO-NOFILE (nothing), PERVIO-NOTFILE (a folder, a socket, a device,
    /// a loop of links — reading one could block or never end), PERVIO-NOREAD,
    /// or four lines: PERVIO-SIZE <bytes>, PERVIO-INO <inode>, PERVIO-HERE
    /// <the picked path's folder, links followed>, PERVIO-REAL <the file>.
    /// Plain POSIX shell: it has to work where Pervio's scripts are old or absent.
    static func identifyCommand(_ path: String) -> String {
        let p = SSHService.shellQuote(path)
        return "p=\(p); f=\"$p\"; n=0; "
            + "while [ -L \"$f\" ] && [ \"$n\" -lt 40 ]; do t=$(readlink \"$f\") || break; "
            + "case \"$t\" in /*) f=\"$t\" ;; *) f=\"$(dirname \"$f\")/$t\" ;; esac; n=$((n+1)); done; "
            + "if [ ! -e \"$f\" ]; then echo PERVIO-NOFILE; "
            + "elif [ -L \"$f\" ] || [ ! -f \"$f\" ]; then echo PERVIO-NOTFILE; "
            + "elif [ ! -r \"$f\" ]; then echo PERVIO-NOREAD; "
            + "else d=$(cd -P \"$(dirname \"$f\")\" 2>/dev/null && pwd -P); "
            + "h=$(cd -P \"$(dirname \"$p\")\" 2>/dev/null && pwd -P); "
            + "echo \"PERVIO-SIZE $(wc -c < \"$f\" | tr -d ' ')\"; "
            + "echo \"PERVIO-INO $(ls -id \"$f\" | awk '{print $1}')\"; "
            + "echo \"PERVIO-HERE $h\"; "
            + "echo \"PERVIO-REAL ${d%/}/$(basename \"$f\")\"; fi"
    }

    /// Block `index` of the file at `real` — only while it is still the file
    /// that was found there: not a link, the same inode. Anything else answers
    /// nothing, and the read ends as "changed underneath".
    static func chunkCommand(_ real: String, inode: String, index: Int) -> String {
        let f = SSHService.shellQuote(real)
        let ino = inode.filter(\.isNumber)                 // digits only ever reach the shell
        // `if`, not `&&`: a file that is no longer the one found answers
        // NOTHING and exits 0 — "changed", not a failed command.
        return "f=\(f); if [ ! -L \"$f\" ] && [ \"$(ls -id \"$f\" 2>/dev/null | awk '{print $1}')\" = \"\(ino)\" ]; "
            + "then dd if=\"$f\" bs=\(chunkBytes) skip=\(index) count=1 2>/dev/null | base64; fi"
    }

    /// Whether `real` lies in the folder `here` (or below it).
    static func leaves(real: String, here: String) -> Bool {
        let base = here.hasSuffix("/") ? here : here + "/"
        return !real.hasPrefix(base)
    }

    /// What is at the picked path, asked BEFORE anything is pulled: a file
    /// over the limit is refused here, by name and size, not after minutes of
    /// reading — and a link is known for one before its target is touched.
    @MainActor
    static func find(_ path: String, on link: any SSHCommanding) async throws -> Found {
        let name = (path as NSString).lastPathComponent
        let out = try await link.runCommand(identifyCommand(path))
        if out.contains("PERVIO-NOFILE") { throw Failure(message: L.remoteFileMissing(name)) }
        if out.contains("PERVIO-NOTFILE") { throw Failure(message: L.remoteNotAFile(name)) }
        if out.contains("PERVIO-NOREAD") { throw Failure(message: L.remoteFileUnreadable(name)) }
        func line(_ key: String) -> String? {
            // Exactly one line per key: a path with a line break in it could
            // otherwise write the next line itself.
            let hits = out.components(separatedBy: "\n").filter { $0.hasPrefix(key + " ") }
            return hits.count == 1 ? String(hits[0].dropFirst(key.count + 1)) : nil
        }
        guard let n = line("PERVIO-SIZE").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
              let ino = line("PERVIO-INO")?.trimmingCharacters(in: .whitespaces),
              !ino.isEmpty, ino.allSatisfy(\.isNumber),
              let here = line("PERVIO-HERE"), here.hasPrefix("/"),
              let real = line("PERVIO-REAL"), real.hasPrefix("/"),
              out.components(separatedBy: "\n").filter({ !$0.isEmpty }).count == 4
        else { throw Failure(message: L.remoteFileUnreadable(name)) }
        if n == 0 { throw Failure(message: L.remoteFileEmpty(name)) }
        if n > fileCap { throw Failure(message: L.remoteFileTooBig(name, bytes: n, cap: fileCap)) }
        return Found(size: n, real: real, inode: ino, leavesItsFolder: leaves(real: real, here: here))
    }

    /// The file's bytes (the first `limit` of them), block by block. What
    /// arrives must be exactly what was sized a moment ago, from the same
    /// file — one that grew, shrank or was swapped underneath is an error,
    /// not a copy of something that never existed.
    @MainActor
    static func read(_ found: Found, limit: Int? = nil, name: String, on link: any SSHCommanding,
                     onProgress: (Double) -> Void) async throws -> Data {
        let size = min(found.size, limit ?? found.size)
        var data = Data(capacity: size)
        var index = 0
        while data.count < size {
            try Task.checkCancellation()
            let out = try await link.runCommand(chunkCommand(found.real, inode: found.inode, index: index))
            // Every reply is a whole block, the last one what is left of the
            // FILE — nothing else. A computer that answered a byte at a time
            // kept the phone asking: 8 388 608 round trips for one file
            // instead of 32 (the 2026-11-22 review). Short or long, the file
            // is not the one sized.
            let want = min(chunkBytes, found.size - index * chunkBytes)
            guard let chunk = Data(base64Encoded: out, options: .ignoreUnknownCharacters),
                  chunk.count == want else { break }
            data.append(chunk.prefix(size - data.count))
            index += 1
            onProgress(min(1, Double(data.count) / Double(size)))
        }
        guard data.count == size else { throw Failure(message: L.remoteFileChanged(name)) }
        return data
    }

    // MARK: A conversation's text

    /// Turns asked for per round trip when reading a whole conversation.
    static let pageTurns = 200
    /// The most the full record may be: the upload ceiling, less room for its
    /// own few header lines.
    static let recordCap = fileCap - 16 * 1024

    static func turnsCommand(launcher: String, dir: String, session: String,
                             backend: AgentBackend, from: Int?, limit: Int) -> String {
        var cmd = "\(launcher) turns --dir \(SSHService.shellQuote(dir))"
            + " --session \(SSHService.shellQuote(session))"
        if let from { cmd += " --from \(from)" }
        cmd += " --limit \(limit)"
        if backend != .claude { cmd += " --backend \(backend.rawValue)" }
        return cmd
    }

    @MainActor
    static func window(_ command: String, on link: any SSHCommanding) async throws -> TurnsWindow {
        let out = try await link.runCommand(command, maxBytes: 16_000_000)
        let w = try JSONDecoder().decode(TurnsWindow.self, from: Data(firstJSON(out).utf8))
        // The numbers are the other computer's word, and arithmetic is done on
        // them (turn N is `from + i`): a start near Int.max ended the app on an
        // overflow (the 2026-11-22 review). A window is turns from…to of total,
        // one entry each, or it is not a window.
        let sane = w.turns.isEmpty
            ? (w.total >= 0 && w.total <= maxTurns)
            : (w.from >= 1 && w.to >= w.from && w.to <= w.total && w.total <= maxTurns && w.turns.count == w.to - w.from + 1)
        guard sane else { throw Failure(message: L.remoteContextChanged()) }
        return w
    }
    /// More turns than any conversation has; beyond it the count is not believed.
    static let maxTurns = 10_000_000

    /// A conversation's LATEST turns, up to `limit` of them. When that many do
    /// not fit in one reply, half as many are asked for, and so on: the
    /// document then holds fewer turns and the earlier ones come with the
    /// rest of the record — a heavy conversation is not a failed one.
    @MainActor
    static func latest(limit: Int, launcher: String, dir: String, session: String,
                       backend: AgentBackend, on link: any SSHCommanding) async throws -> TurnsWindow {
        var n = max(1, limit)
        while true {
            try Task.checkCancellation()
            do {
                return try await window(turnsCommand(launcher: launcher, dir: dir, session: session,
                                                     backend: backend, from: nil, limit: n), on: link)
            } catch {
                guard tooLarge(error), n > 1 else { throw error }
                n /= 2
            }
        }
    }

    /// What was read of a conversation's earlier turns.
    struct Earlier {
        /// One "#N [who] text" entry per turn, oldest first.
        var lines: [String]
        /// The number of the first turn in `lines`.
        var from: Int
        /// True when turns before `from` exist and were left behind because
        /// the record would have passed `budget`.
        var cut: Bool
    }

    /// The turns BEFORE `before` (numbers 1 ..< before), read newest page
    /// first so that when the whole conversation does not fit in `budget`
    /// bytes, what is kept is the later part and what is not read at all is
    /// the part that would have been dropped. A page too large for one reply
    /// is asked for again in halves.
    @MainActor
    static func earlier(before: Int, budget: Int, launcher: String, dir: String, session: String,
                        backend: AgentBackend, language: PromptLanguage, on link: any SSHCommanding,
                        onProgress: (Double) -> Void) async throws -> Earlier {
        var lines: [String] = []
        var bytes = 0
        var hi = before - 1                 // the last turn still to read
        var page = pageTurns
        while hi >= 1 {
            try Task.checkCancellation()
            let lo = max(1, hi - page + 1)
            let cmd = turnsCommand(launcher: launcher, dir: dir, session: session,
                                   backend: backend, from: lo, limit: hi - lo + 1)
            let w: TurnsWindow
            do {
                w = try await window(cmd, on: link)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One reply could not carry the page: ask for half as many. A
                // single turn that still does not fit is an error to report,
                // and so is anything that is not about size.
                guard tooLarge(error), hi - lo + 1 > 1 else { throw error }
                page = max(1, (hi - lo + 1) / 2)
                continue
            }
            // The page must be the one asked for. A conversation that lost
            // turns between two reads would otherwise leave a hole in the
            // record with nothing saying so.
            guard w.from == lo, w.to == hi, w.turns.count == hi - lo + 1 else {
                throw Failure(message: L.remoteContextChanged())
            }
            let got = ChatStore.contextLines(w, language: language)
            // Newest first within the page too: stop at the first turn that
            // would take the record past its budget.
            var kept: [String] = []
            var full = false
            for line in got.reversed() {
                let cost = line.utf8.count + 2
                if bytes + cost > budget { full = true; break }
                bytes += cost
                kept.append(line)
            }
            lines.insert(contentsOf: kept.reversed(), at: 0)
            let first = w.from + (got.count - kept.count)
            if full { return Earlier(lines: lines, from: first, cut: first > 1) }
            hi = w.from - 1
            onProgress(min(1, Double(before - 1 - hi) / Double(max(1, before - 1))))
        }
        return Earlier(lines: lines, from: hi + 1, cut: false)
    }

    /// The reply was larger than the connection lets one command return
    /// (Citadel's `commandOutputTooLarge`, passed through by `runCommand`).
    static func tooLarge(_ error: Error) -> Bool {
        String(reflecting: error).contains("commandOutputTooLarge")
    }

    /// `pervio-sessions` prints one JSON value; tolerate stray bytes around it.
    static func firstJSON(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = t.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let close = t.lastIndex(where: { $0 == "}" || $0 == "]" }), open <= close {
            return String(t[open...close])
        }
        return t
    }
}

extension ServerProfile {
    /// Two saved entries for ONE account on ONE machine, reached the same way
    /// (the "~" entry and the "~/a" entry of a Mac). Such a twin is not another
    /// computer: what it can see, this conversation's own computer can see, and
    /// carrying its files through the phone would only copy a disk onto itself.
    /// Addresses are compared as written — one Mac saved once by its LAN
    /// address and once by its VPN name still counts as two.
    func reachesSameMachine(as other: ServerProfile) -> Bool {
        func key(_ host: String, _ port: Int, _ user: String) -> String {
            host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + ":\(port):"
                + user.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func path(_ p: ServerProfile) -> [String] {
            p.routeHops.map { key($0.host, $0.port, $0.username) } + [key(p.host, p.port, p.username)]
        }
        return path(self) == path(other)
    }
}

