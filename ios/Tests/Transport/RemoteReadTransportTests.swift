import XCTest
import Crypto
@testable import Pervio

/// Lets the reader's own progress callback cancel the reader's own task.
@MainActor
private final class ReadTaskBox {
    var task: Task<Data, Error>?
}

/// The other half of a cross-computer pick, over a real connection: reading a
/// file OFF a computer in chunks (`RemoteRead`), the mirror of the chunked
/// upload `UploadTransferTests` covers.
///
/// The store tests script the far side, so they prove the loop; they cannot
/// prove that `dd … | base64` on a real machine returns what the loop expects
/// (the block arithmetic, a short last block, nothing past the end, a name with
/// a quote in it). So this writes real files on the sandbox — random bytes, the
/// digest computed THERE by python — reads them back through the app's reader,
/// and compares digests, at the sizes where an off-by-one lives.
@MainActor
final class RemoteReadTransportTests: XCTestCase {

    /// `RemoteRead.chunkBytes`, as a literal on purpose (see UploadTransferTests).
    private static let chunk = 262_144

    func testOneByteArrives() async throws { try await assertReadsBack(1) }
    func testOneByteShortOfAChunkArrives() async throws { try await assertReadsBack(Self.chunk - 1) }
    /// Exactly one chunk: one round trip, and no empty second one mistaken for
    /// "the file shrank".
    func testExactlyOneChunkArrives() async throws { try await assertReadsBack(Self.chunk, expectTrips: 1) }
    func testOneByteOverAChunkArrives() async throws { try await assertReadsBack(Self.chunk + 1, expectTrips: 2) }
    /// Several chunks and a ragged tail, so a repeated or skipped block shows.
    func testSeveralChunksArriveInOrder() async throws { try await assertReadsBack(Self.chunk * 3 + 12_345, expectTrips: 4) }

    /// The name is the only thing in the command the person influences.
    func testANameHostileToAShellIsReadLiterally() async throws {
        try await assertReadsBack(5_000, name: "it's 报告 $(touch pwned) `id` \"q\".bin")
    }

    func testMissingUnreadableAndEmptyFilesAreToldApart() async throws {
        let (service, dir) = try await openSandbox()
        defer { Task { await service.disconnect() } }
        let q = SSHService.shellQuote
        _ = try await service.runCommand("mkdir -p \(q(dir)) && : > \(q(dir + "/empty.txt")) && "
            + "printf secret > \(q(dir + "/locked.txt")) && chmod 000 \(q(dir + "/locked.txt"))")
        for (name, want) in [("nope.txt", L.remoteFileMissing("nope.txt")),
                             ("locked.txt", L.remoteFileUnreadable("locked.txt")),
                             ("empty.txt", L.remoteFileEmpty("empty.txt"))] {
            do {
                _ = try await RemoteRead.find(dir + "/" + name, on: service)
                XCTFail("\(name) was accepted")
            } catch let f as RemoteRead.Failure {
                XCTAssertEqual(f.message, want, name)
            }
        }
        // A folder, and a pipe (which a read would block on forever), are there
        // but are not files to bring.
        _ = try await service.runCommand("mkfifo \(q(dir + "/pipe"))")
        for path in [dir, dir + "/pipe"] {
            do { _ = try await RemoteRead.find(path, on: service); XCTFail("\(path) was accepted") }
            catch let f as RemoteRead.Failure { XCTAssertEqual(f.message, L.remoteNotAFile((path as NSString).lastPathComponent)) }
        }
        _ = try? await service.runCommand("chmod 600 \(q(dir + "/locked.txt")); rm -rf \(q(dir))")
    }

    // MARK: - Links (security review 2026-11-22, #5), against a real sshd and a real file system

    /// A repository can carry `notes.txt` that is a link to a private key. The
    /// reader says so before it reads: where the name really leads, and that it
    /// leaves the folder it was picked in. A link that stays inside its folder
    /// is just the file; so is a file in a folder that is itself reached
    /// through a link (OneDrive turns ~/Documents into one).
    func testALinkIsKnownForOneBeforeItsTargetIsRead() async throws {
        let (service, dir) = try await openSandbox()
        defer { Task { await service.disconnect() } }
        let q = SSHService.shellQuote
        _ = try await service.runCommand(
            "mkdir -p \(q(dir + "/repo/docs")) \(q(dir + "/private")) && "
            + "printf 'PRIVATE KEY' > \(q(dir + "/private/id_key")) && "
            + "printf 'plain notes' > \(q(dir + "/repo/docs/real.txt")) && "
            + "ln -s ../../private/id_key \(q(dir + "/repo/docs/notes.txt")) && "       // out of the folder
            + "ln -s real.txt \(q(dir + "/repo/docs/alias.txt")) && "                    // inside it
            + "ln -s notes.txt \(q(dir + "/repo/docs/twice.txt")) && "                   // a link to a link, out
            + "ln -s \(q(dir + "/repo/docs")) \(q(dir + "/cloud")) && "                  // a folder that is a link
            + "ln -s loop-b \(q(dir + "/repo/docs/loop-a")) && ln -s loop-a \(q(dir + "/repo/docs/loop-b")) && "
            + "ln -s gone.txt \(q(dir + "/repo/docs/dangling.txt"))")
        // The sandbox's home may itself sit behind links (/tmp → /private/tmp): compare real paths.
        let realDir = try await service.runCommand("cd -P \(q(dir)) && pwd -P").trimmingCharacters(in: .whitespacesAndNewlines)

        let out = try await RemoteRead.find(dir + "/repo/docs/notes.txt", on: service)
        XCTAssertTrue(out.leavesItsFolder, "a link to a file outside its folder must be flagged")
        XCTAssertEqual(out.real, realDir + "/private/id_key", "…and say where it leads")
        XCTAssertEqual(out.size, 11)

        let twice = try await RemoteRead.find(dir + "/repo/docs/twice.txt", on: service)
        XCTAssertTrue(twice.leavesItsFolder, "through two links as through one")
        XCTAssertEqual(twice.real, realDir + "/private/id_key")

        let alias = try await RemoteRead.find(dir + "/repo/docs/alias.txt", on: service)
        XCTAssertFalse(alias.leavesItsFolder, "a link that stays in its folder is just the file")
        XCTAssertEqual(alias.real, realDir + "/repo/docs/real.txt")
        let viaAlias = try await RemoteRead.read(alias, name: "alias.txt", on: service) { _ in }
        XCTAssertEqual(String(decoding: viaAlias, as: UTF8.self), "plain notes")

        let cloud = try await RemoteRead.find(dir + "/cloud/real.txt", on: service)
        XCTAssertFalse(cloud.leavesItsFolder, "a file in a folder reached through a link is in the folder being looked at")
        XCTAssertEqual(cloud.real, realDir + "/repo/docs/real.txt")

        for name in ["loop-a", "dangling.txt"] {
            do { _ = try await RemoteRead.find(dir + "/repo/docs/" + name, on: service); XCTFail("\(name) was accepted") }
            catch let f as RemoteRead.Failure {
                XCTAssertTrue([L.remoteNotAFile(name), L.remoteFileMissing(name)].contains(f.message), "\(name): \(f.message)")
            }
        }
        _ = try? await service.runCommand("rm -rf \(q(dir))")
    }

    /// The browser's own listing (the script the app carries, run by a real
    /// python on a real file system) marks a link and says where it leads —
    /// so it is seen before it is tapped; a plain entry carries no such mark.
    func testTheListingSaysWhichEntriesAreLinksAndWhereTheyLead() async throws {
        let (service, dir) = try await openSandbox()
        defer { Task { await service.disconnect() } }
        let q = SSHService.shellQuote
        _ = try await service.runCommand(
            "mkdir -p \(q(dir + "/repo/sub")) \(q(dir + "/private")) && printf key > \(q(dir + "/private/id_key")) && "
            + "printf notes > \(q(dir + "/repo/plain.txt")) && ln -s ../private/id_key \(q(dir + "/repo/notes.txt")) && "
            + "ln -s ../private \(q(dir + "/repo/vault"))")
        let realDir = try await service.runCommand("cd -P \(q(dir)) && pwd -P").trimmingCharacters(in: .whitespacesAndNewlines)
        let json = try await service.runCommand(SSHService.serverFsCommand("ls", path: dir + "/repo"))
        let listing = try JSONDecoder().decode(ServerDirListing.self, from: Data(json.utf8))
        let by = Dictionary(uniqueKeysWithValues: (listing.entries ?? []).map { ($0.name, $0) })
        XCTAssertEqual(by["notes.txt"]?.link, realDir + "/private/id_key", "a file that is a link says where it leads")
        XCTAssertEqual(by["notes.txt"]?.isDir, false)
        XCTAssertEqual(by["vault"]?.link, realDir + "/private", "so does a folder that is one")
        XCTAssertEqual(by["vault"]?.isDir, true)
        XCTAssertNil(by["plain.txt"]?.link)
        XCTAssertNil(by["sub"]?.link)
        _ = try? await service.runCommand("rm -rf \(q(dir))")
    }

    /// The bytes come from the file that was found, or not at all: swapped for
    /// another file, or for a link to one, between the look and the read, the
    /// read ends as "changed" and nothing of the other file comes over.
    func testAFileSwappedAfterItWasFoundIsNotRead() async throws {
        let (service, dir) = try await openSandbox()
        defer { Task { await service.disconnect() } }
        let q = SSHService.shellQuote
        _ = try await service.runCommand("mkdir -p \(q(dir)) && printf 'the secret!' > \(q(dir + "/secret")) && "
            + "printf 'what I chose' > \(q(dir + "/chosen.txt")) && printf 'another one!' > \(q(dir + "/other.txt"))")
        for (what, swap) in [("a link to another file", "rm \(q(dir + "/chosen.txt")) && ln -s secret \(q(dir + "/chosen.txt"))"),
                             ("another file of the same name", "mv \(q(dir + "/other.txt")) \(q(dir + "/chosen.txt"))")] {
            _ = try await service.runCommand("rm -f \(q(dir + "/chosen.txt")); printf 'what I chose' > \(q(dir + "/chosen.txt"))")
            let found = try await RemoteRead.find(dir + "/chosen.txt", on: service)
            _ = try await service.runCommand(swap)
            do {
                let data = try await RemoteRead.read(found, name: "chosen.txt", on: service) { _ in }
                XCTFail("\(what): read \(String(decoding: data, as: UTF8.self))")
            } catch let f as RemoteRead.Failure {
                XCTAssertEqual(f.message, L.remoteFileChanged("chosen.txt"), what)
            }
        }
        _ = try? await service.runCommand("rm -rf \(q(dir))")
    }

    /// Cancelled from inside the first progress callback: the read reports the
    /// cancellation and asks for nothing more.
    func testACancelledReadStopsAtTheNextChunk() async throws {
        let (service, dir) = try await openSandbox()
        defer { Task { await service.disconnect() } }
        let path = dir + "/long.bin"
        let size = Self.chunk * 4
        _ = try await makeFile(service, path: path, bytes: size)
        var seen = 0
        let box = ReadTaskBox()
        let found = try await RemoteRead.find(path, on: service)
        XCTAssertEqual(found.size, size)
        box.task = Task { () -> Data in
            try await RemoteRead.read(found, name: "long.bin", on: service) { _ in
                seen += 1
                box.task?.cancel()
            }
        }
        var thrown: Error?
        do { _ = try await box.task?.value } catch { thrown = error }
        XCTAssertTrue(thrown is CancellationError, "a cancelled read must say so: \(String(describing: thrown))")
        XCTAssertEqual(seen, 1, "\(seen) chunks came over after the cancel")
        _ = try? await service.runCommand("rm -rf \(SSHService.shellQuote(dir))")
    }

    // MARK: - Machinery

    private func openSandbox() async throws -> (SSHService, String) {
        let endpoint = try SandboxEndpoint.discover()
        let service = SSHService()
        try await service.connect(profile: endpoint.profile, secret: endpoint.privateKey)
        let home = try await service.runCommand("printf %s \"$HOME\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A folder unique to this run: a leftover cannot pass or fail it.
        return (service, home + "/remote-read-\(UUID().uuidString.prefix(8))")
    }

    /// Write `bytes` random bytes at `path` ON the far side and return the
    /// SHA-256 the far side computes over them.
    private func makeFile(_ service: SSHService, path: String, bytes: Int) async throws -> String {
        let script = "import hashlib,os,sys;p=sys.argv[1];os.makedirs(os.path.dirname(p),exist_ok=True);"
            + "d=os.urandom(int(sys.argv[2]));open(p,'wb').write(d);print(hashlib.sha256(d).hexdigest())"
        return try await service.runCommand(
            "python3 -c \(SSHService.shellQuote(script)) \(SSHService.shellQuote(path)) \(bytes)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assertReadsBack(_ bytes: Int, name: String = "blob.bin", expectTrips: Int? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let (service, dir) = try await openSandbox()
        defer { Task { await service.disconnect() } }
        let path = dir + "/" + name
        let digest = try await makeFile(service, path: path, bytes: bytes)
        XCTAssertEqual(digest.count, 64, "the far side did not make the file: \(digest)", file: file, line: line)

        let found = try await RemoteRead.find(path, on: service)
        XCTAssertEqual(found.size, bytes, "wrong size reported", file: file, line: line)
        XCTAssertFalse(found.leavesItsFolder, "a plain file is where it was picked", file: file, line: line)
        var progress: [Double] = []
        let data = try await RemoteRead.read(found, name: name, on: service) { progress.append($0) }

        XCTAssertEqual(data.count, bytes, "wrong number of bytes came over", file: file, line: line)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), digest,
                       "the bytes read are not the bytes on the far side", file: file, line: line)
        if let expectTrips {
            XCTAssertEqual(progress.count, expectTrips, "round trips", file: file, line: line)
        }
        XCTAssertEqual(progress.last ?? 0, 1, accuracy: 0.0001, "progress must end at 100%", file: file, line: line)
        XCTAssertEqual(progress, progress.sorted(), "progress went backwards", file: file, line: line)
        // The hostile name ran nothing: no file called "pwned" appeared where
        // a command would have left it.
        let stray = try await service.runCommand("ls -a \"$HOME\" | grep -c '^pwned$'; true")
        XCTAssertEqual(stray.trimmingCharacters(in: .whitespacesAndNewlines), "0",
                       "the file's NAME was executed", file: file, line: line)
        _ = try? await service.runCommand("rm -rf \(SSHService.shellQuote(dir))")
    }
}
