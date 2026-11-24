import Foundation
import CryptoKit

/// Keeps the Mac's `~/.pervio/bin` in lockstep with THIS build of the app.
///
/// WHY. The App Store updates the app by itself; nothing updates the server
/// scripts — today that's a human remembering `install.sh`, which works
/// exactly until the user is a stranger. The compatibility discipline in the
/// wire code (optional flags, decodeIfPresent) buys one version of drift, not
/// forever. So the app carries its own matching copy of every server script
/// (bundled at build time — app version N ships scripts N, definitionally
/// paired) and, on connect, repaves the server when the two disagree.
///
/// THE HANDSHAKE. Versions are CONTENT HASHES, never hand-bumped numbers:
/// for each file in sorted-by-name order, feed "name NUL content NUL" into
/// SHA-256, keep 16 hex chars. `install.sh` computes the same and stamps it
/// into `~/.pervio/bin/.pervio-rev` (see its "Revision stamp" section, and
/// test_install.py which pins the two implementations against each other).
/// Scripts changed ⇒ rev changed ⇒ next connect repaves. Nobody maintains a
/// version file, so the one failure mode of manual versioning — forgetting —
/// is structurally gone.
///
/// THE PAVE. Chunked base64 over the SSH exec channel (the transport
/// pervio-upload proved out — but with PLAIN shell only, because on a fresh
/// Mac there are no server scripts to help). Staged like install.sh: write
/// everything into `~/.pervio/bin/.stage`, back the current set up to
/// `~/.pervio/bin.prev`, publish with per-file rename(2), write `.pervio-rev`
/// LAST, then smoke-test (`pervio-run list`). A failed smoke restores
/// `bin.prev` wholesale — the server is never left mid-upgrade.
///
/// THE TEMPLATES. `server/templates/*.json` rides in the bundle too, but as
/// SEEDS, not synced code: after any successful pass (paved or already
/// current) the missing ones are copied into `~/.pervio/templates` and files
/// already there are NEVER touched — the same write-if-absent discipline as
/// install.sh's seeding, because the user edits these (口味、时间、模型).
/// They stay out of the rev hash for the same reason: a rev that tracked
/// seeds would repave forever against a user's edited copy. Best-effort by
/// design — a failed seed logs and never fails the pave.
@MainActor
final class ServerProvisioner {
    enum Outcome: Equatable {
        case upToDate            // server already runs this build's scripts
        case paved(String)       // repaved to this rev
        case restored(String)    // pave failed smoke; previous set put back
        case failed(String)      // couldn't provision; server left as found
        case skipped             // no bundled scripts (dev builds without the folder)
    }

    private let ssh: any SSHCommanding
    /// Where the bundled scripts live. The app passes nil (Bundle lookup);
    /// tests inject a fixture directory.
    private let binDir: URL?
    /// Where the bundled seed templates live (nil-able the same way).
    private let templatesDir: URL?
    /// One pave attempt per (profile, rev) per process: connect loops must not
    /// hammer a broken server with re-paves.
    private static var attempted: Set<String> = []

    init(ssh: any SSHCommanding = SSHService(), binDir: URL? = nil,
         templatesDir: URL? = nil) {
        self.ssh = ssh
        self.binDir = binDir ?? Bundle.main.resourceURL?.appendingPathComponent("bin")
        self.templatesDir = templatesDir
            ?? Bundle.main.resourceURL?.appendingPathComponent("templates")
    }

    // MARK: - The canonical revision

    /// The bundle's script files, sorted by name — the exact set install.sh
    /// ships (its payload is all of server/bin). `.md`/`.py` files are data
    /// (0644 in install.sh); everything else is a launcher (0755).
    nonisolated static func files(in dir: URL) throws -> [(name: String, data: Data, executable: Bool)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { !$0.hasPrefix(".") && $0 != "__pycache__" }
            .sorted()
        return try names.map { name in
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            let exec = !(name.hasSuffix(".md") || name.hasSuffix(".py"))
            return (name, data, exec)
        }
    }

    /// SHA-256 over "name NUL content NUL" per sorted file, first 16 hex chars —
    /// byte-for-byte the computation in install.sh's revision stamp.
    nonisolated static func rev(of files: [(name: String, data: Data, executable: Bool)]) -> String {
        var h = SHA256()
        for f in files {
            h.update(data: Data(f.name.utf8))
            h.update(data: Data([0]))
            h.update(data: f.data)
            h.update(data: Data([0]))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }

    // MARK: - Wire commands (pinned by tests; every interpolation quoted)

    nonisolated static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let probeCommand = "cat ~/.pervio/bin/.pervio-rev 2>/dev/null || echo PERVIO-NO-REV"

    nonisolated static func stageInitCommand() -> String {
        "mkdir -p ~/.pervio/bin && rm -rf ~/.pervio/bin/.stage && mkdir ~/.pervio/bin/.stage"
    }

    /// 48KB of raw bytes per chunk → 64KB of base64 per exec — far under any
    /// ARG_MAX, small enough to stream progress, big enough that the whole
    /// 1.4MB set is ~30 round trips.
    nonisolated static let chunkBytes = 48 * 1024

    nonisolated static func chunkCommands(name: String, data: Data) -> [String] {
        var cmds: [String] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkBytes, data.count)
            let chunk = data.subdata(in: offset..<end).base64EncodedString()
            cmds.append("printf '%s' \(shq(chunk)) >> ~/.pervio/bin/.stage/\(shq(name)).b64")
            offset = end
        }
        // `--decode` is the one spelling BSD and GNU base64 share.
        var finish = "base64 --decode < ~/.pervio/bin/.stage/\(shq(name)).b64 "
                   + "> ~/.pervio/bin/.stage/\(shq(name)) && rm ~/.pervio/bin/.stage/\(shq(name)).b64"
        if !(name.hasSuffix(".md") || name.hasSuffix(".py")) {
            finish += " && chmod 755 ~/.pervio/bin/.stage/\(shq(name))"
        }
        cmds.append(finish)
        return cmds
    }

    /// Backup BEFORE publish — `bin.prev` is the rollback the smoke failure
    /// path restores. `-maxdepth 1 -type f` keeps stage/ and dirs out.
    static let backupCommand =
        "rm -rf ~/.pervio/bin.prev && mkdir -p ~/.pervio/bin.prev && "
        + "find ~/.pervio/bin -maxdepth 1 -type f -exec cp -p {} ~/.pervio/bin.prev/ \\; && echo PERVIO-BACKUP-OK"

    /// One command, ordered: every rename first, the rev stamp LAST (a publish
    /// that dies midway leaves no current-looking rev), stage swept after.
    nonisolated static func publishCommand(names: [String], rev: String) -> String {
        let moves = names.map { "mv -f ~/.pervio/bin/.stage/\(shq($0)) ~/.pervio/bin/\(shq($0))" }
            .joined(separator: " && ")
        return moves + " && printf '%s' \(shq(rev)) > ~/.pervio/bin/.pervio-rev "
             + "&& rm -rf ~/.pervio/bin/.stage && echo PERVIO-PAVE-OK"
    }

    static let smokeCommand =
        "~/.pervio/bin/pervio-run list >/dev/null 2>&1 && echo PERVIO-SMOKE-OK || echo PERVIO-SMOKE-BAD"

    static let restoreCommand =
        "cp -p ~/.pervio/bin.prev/* ~/.pervio/bin/ && echo PERVIO-RESTORED"

    // MARK: - Template seeding (write-if-absent, best-effort)

    /// One round trip that answers "which seeds are missing?": prints one
    /// name per line for every bundled template NOT already on the server.
    /// The mkdir doubles as first-run init of ~/.pervio/templates.
    nonisolated static func seedProbeCommand(names: [String]) -> String {
        let checks = names.map {
            "[ -e ~/.pervio/templates/\(shq($0)) ] || printf '%s\\n' \(shq($0))"
        }.joined(separator: "; ")
        return "mkdir -p ~/.pervio/templates && " + checks
    }

    /// Chunked upload of ONE missing template — same transport as the pave,
    /// but into a `.seed` scratch dir, and the landing is GUARDED: the decode
    /// and `mv -n` run only while the destination still doesn't exist, so a
    /// user's copy racing in mid-upload survives untouched. The trailing rm
    /// sweeps this file's scratch on both paths.
    nonisolated static func seedChunkCommands(name: String, data: Data) -> [String] {
        var cmds: [String] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkBytes, data.count)
            let chunk = data.subdata(in: offset..<end).base64EncodedString()
            cmds.append("mkdir -p ~/.pervio/templates/.seed && printf '%s' \(shq(chunk))"
                        + " >> ~/.pervio/templates/.seed/\(shq(name)).b64")
            offset = end
        }
        cmds.append(
            "if [ ! -e ~/.pervio/templates/\(shq(name)) ]; then "
            + "base64 --decode < ~/.pervio/templates/.seed/\(shq(name)).b64 "
            + "> ~/.pervio/templates/.seed/\(shq(name)) "
            + "&& mv -n ~/.pervio/templates/.seed/\(shq(name)) "
            + "~/.pervio/templates/\(shq(name)); fi; "
            + "rm -f ~/.pervio/templates/.seed/\(shq(name)).b64 "
            + "~/.pervio/templates/.seed/\(shq(name))")
        return cmds
    }

    static let seedCleanupCommand = "rm -rf ~/.pervio/templates/.seed"

    /// Copy every bundled template the server doesn't have. Runs on the OPEN
    /// connection after a successful pass; any failure logs and returns — the
    /// provisioning outcome must never depend on seeds.
    private func seedTemplates() async {
        guard let templatesDir,
              let all = try? Self.files(in: templatesDir) else { return }
        let seeds = all.filter { $0.name.hasSuffix(".json") }
        guard !seeds.isEmpty else { return }
        do {
            let out = try await ssh.runCommand(
                Self.seedProbeCommand(names: seeds.map(\.name)))
            let missing = Set(out.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) })
            let wanted = seeds.filter { missing.contains($0.name) }
            guard !wanted.isEmpty else { return }
            for f in wanted {
                for cmd in Self.seedChunkCommands(name: f.name, data: f.data) {
                    _ = try await ssh.runCommand(cmd)
                }
            }
            _ = try await ssh.runCommand(Self.seedCleanupCommand)
            NSLog("[Pervio] seeded %d template(s): %@", wanted.count,
                  wanted.map(\.name).joined(separator: ", "))
        } catch {
            NSLog("[Pervio] template seeding skipped: %@", String(describing: error))
        }
    }

    // MARK: - The provisioning pass

    /// Compare the server's rev with the bundle's; repave when they differ.
    /// Best-effort by design: any SSH failure leaves the server exactly as
    /// found and reports `.failed` — a bad network must never half-upgrade.
    func ensureCurrent(profile: ServerProfile, secret: String?) async -> Outcome {
        guard let secret, !secret.isEmpty else { return .failed("no secret") }
        guard let binDir, let files = try? Self.files(in: binDir), !files.isEmpty else {
            return .skipped
        }
        let want = Self.rev(of: files)
        let key = "\(profile.id)|\(want)"
        guard !Self.attempted.contains(key) else { return .upToDate }

        do {
            try await ssh.connect(profile: profile, secret: secret)
            let have = (try await ssh.runCommand(Self.probeCommand))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if have == want {
                await seedTemplates()   // an old app may have paved without seeds
                await ssh.disconnect()
                Self.attempted.insert(key)
                return .upToDate
            }
            Self.attempted.insert(key)   // one attempt per launch, success or not

            _ = try await ssh.runCommand(Self.stageInitCommand())
            for f in files {
                for cmd in Self.chunkCommands(name: f.name, data: f.data) {
                    _ = try await ssh.runCommand(cmd)
                }
            }
            let backup = try await ssh.runCommand(Self.backupCommand)
            guard backup.contains("PERVIO-BACKUP-OK") else {
                await ssh.disconnect()
                return .failed("backup refused — server untouched")
            }
            let publish = try await ssh.runCommand(
                Self.publishCommand(names: files.map(\.name), rev: want))
            guard publish.contains("PERVIO-PAVE-OK") else {
                await ssh.disconnect()
                return .failed("publish incomplete — rev not stamped, next connect retries")
            }
            let smoke = try await ssh.runCommand(Self.smokeCommand)
            if smoke.contains("PERVIO-SMOKE-OK") {
                await seedTemplates()
                await ssh.disconnect()
                NSLog("[Pervio] server scripts paved to %@", want)
                return .paved(want)
            }
            let restore = try await ssh.runCommand(Self.restoreCommand)
            await ssh.disconnect()
            NSLog("[Pervio] pave failed smoke; previous scripts restored (%@)", restore)
            return .restored(want)
        } catch {
            await ssh.disconnect()
            NSLog("[Pervio] provisioning pass failed, server left as found: %@",
                  String(reflecting: error))
            return .failed(String(describing: error))
        }
    }

    /// Test seam: clear the per-process attempt memo.
    static func resetAttempts() { attempted.removeAll() }
}
