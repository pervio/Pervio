import XCTest
@testable import Pervio

/// The app↔server version handshake and the SSH pave. The revision is a
/// CONTENT HASH computed independently in three languages — Swift here,
/// python in test_install.py, shell in install.sh — so these tests pin the
/// Swift spelling to a constant cross-checked against the other two
/// (`67d4b8ec06b8888b` for the {a:"A", b.md:"B"} fixture; recompute:
/// sha256("a\0A\0b.md\0B\0")[:16]). Drift in any one implementation makes a
/// server look permanently outdated (endless repaves) or permanently current
/// (never repaved) — both silent, hence the constant.
@MainActor
final class ServerProvisionerTests: XCTestCase {

    private func fixtureDir(_ files: [(String, String)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            try Data(body.utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    override func setUp() {
        super.setUp()
        ServerProvisioner.resetAttempts()
    }

    // MARK: - The canonical revision

    func testRev_matchesThePythonAndShellImplementations() throws {
        let dir = try fixtureDir([("a", "A"), ("b.md", "B")])
        let files = try ServerProvisioner.files(in: dir)
        XCTAssertEqual(ServerProvisioner.rev(of: files), "67d4b8ec06b8888b",
                       "the Swift hash must equal install.sh's shasum stream and "
                       + "test_install.py's hashlib stream, byte for byte")
    }

    func testRev_isOrderInsensitiveButNameAndContentSensitive() throws {
        // Listing order can't matter (files() sorts); a rename or an edit must.
        let base = try ServerProvisioner.files(in: fixtureDir([("a", "A"), ("b.md", "B")]))
        let renamed = try ServerProvisioner.files(in: fixtureDir([("c", "A"), ("b.md", "B")]))
        let edited = try ServerProvisioner.files(in: fixtureDir([("a", "X"), ("b.md", "B")]))
        XCTAssertNotEqual(ServerProvisioner.rev(of: base), ServerProvisioner.rev(of: renamed))
        XCTAssertNotEqual(ServerProvisioner.rev(of: base), ServerProvisioner.rev(of: edited))
    }

    func testFiles_skipsDotfilesAndMarksExecutability() throws {
        let dir = try fixtureDir([("pervio-run", "#!x"), ("_lib.py", "L"),
                                  ("brief.md", "M"), (".pervio-rev", "deadbeef")])
        let files = try ServerProvisioner.files(in: dir)
        XCTAssertEqual(files.map(\.name), ["_lib.py", "brief.md", "pervio-run"],
                       "sorted, and the rev stamp itself must never be part of the rev")
        XCTAssertEqual(files.map(\.executable), [false, false, true],
                       ".md/.py are data (install.sh's 0644); launchers are 0755")
    }

    // MARK: - Chunking

    func testChunking_reassemblesExactlyAndQuotes() {
        // Three-and-a-bit chunks; the decode step must come last and chmod only
        // executables.
        let big = Data(repeating: 0x41, count: ServerProvisioner.chunkBytes * 3 + 7)
        let cmds = ServerProvisioner.chunkCommands(name: "pervio-run", data: big)
        XCTAssertEqual(cmds.count, 5, "4 chunk appends + 1 decode/finish")
        XCTAssertTrue(cmds.dropLast().allSatisfy { $0.contains(">> ~/.pervio/bin/.stage/'pervio-run'.b64") })
        XCTAssertTrue(cmds.last!.contains("base64 --decode"), cmds.last!)
        XCTAssertTrue(cmds.last!.contains("chmod 755"), "a launcher must come out executable")
        // The chunks reassemble to the exact original bytes.
        let joined = cmds.dropLast().compactMap { cmd -> String? in
            guard let a = cmd.range(of: "printf '%s' '"),
                  let b = cmd.range(of: "' >>") else { return nil }
            return String(cmd[a.upperBound..<b.lowerBound])
        }.joined()
        XCTAssertEqual(Data(base64Encoded: joined), big, "chunk math must not lose a byte")

        let md = ServerProvisioner.chunkCommands(name: "brief.md", data: Data("m".utf8))
        XCTAssertFalse(md.last!.contains("chmod"), "data files stay 0644-ish (no chmod)")
    }

    // MARK: - The pave, end to end against the scripted wire

    private func scriptedPave(_ fake: FakeSSH, probe: String, smoke: String) {
        fake.script("cat ~/.pervio/bin/.pervio-rev", probe)
        fake.script("rm -rf ~/.pervio/bin/.stage && mkdir", "")
        fake.script(">> ~/.pervio/bin/.stage/", "")
        fake.script("base64 --decode", "")
        fake.script("find ~/.pervio/bin -maxdepth", "PERVIO-BACKUP-OK\n")
        fake.script("echo PERVIO-PAVE-OK", "PERVIO-PAVE-OK\n")
        fake.script("pervio-run list", smoke)
        fake.script("bin.prev/*", "PERVIO-RESTORED\n")
    }

    func testMatchingRev_paveNeverStarts() async throws {
        let dir = try fixtureDir([("a", "A"), ("b.md", "B")])
        let fake = FakeSSH()
        scriptedPave(fake, probe: "67d4b8ec06b8888b\n", smoke: "PERVIO-SMOKE-OK\n")

        let out = await ServerProvisioner(ssh: fake, binDir: dir)
            .ensureCurrent(profile: TestFactory.profile(), secret: "pw")

        XCTAssertEqual(out, .upToDate)
        XCTAssertTrue(fake.commandCalls(containing: ".stage").isEmpty,
                      "a current server must not be touched: \(fake.calls)")
        XCTAssertTrue(fake.calls.contains("disconnect"))
    }

    func testFreshServer_getsTheFullOrderedPave() async throws {
        let dir = try fixtureDir([("a", "A"), ("b.md", "B")])
        let fake = FakeSSH()
        scriptedPave(fake, probe: "PERVIO-NO-REV\n", smoke: "PERVIO-SMOKE-OK\n")

        let out = await ServerProvisioner(ssh: fake, binDir: dir)
            .ensureCurrent(profile: TestFactory.profile(), secret: "pw")

        XCTAssertEqual(out, .paved("67d4b8ec06b8888b"))
        // Order is the safety story: stage → chunks → backup → publish → smoke.
        let seq = fake.calls.filter { $0.hasPrefix("run: ") }
        func idx(_ needle: String) -> Int? { seq.firstIndex { $0.contains(needle) } }
        let stage = try XCTUnwrap(idx(".stage && mkdir"))
        let chunk = try XCTUnwrap(idx(">> ~/.pervio/bin/.stage/"))
        let backup = try XCTUnwrap(idx("find ~/.pervio/bin -maxdepth"))
        let publish = try XCTUnwrap(idx("echo PERVIO-PAVE-OK"))
        let smoke = try XCTUnwrap(idx("pervio-run list"))
        XCTAssertLessThan(stage, chunk)
        XCTAssertLessThan(chunk, backup, "backup happens only once the cargo fully landed")
        XCTAssertLessThan(backup, publish, "never publish without a rollback copy")
        XCTAssertLessThan(publish, smoke)
        // The publish writes the rev LAST inside its one command, and the rev it
        // writes is the bundle's.
        let pub = fake.commandCalls(containing: "echo PERVIO-PAVE-OK")[0]
        XCTAssertTrue(pub.contains("printf '%s' '67d4b8ec06b8888b' > ~/.pervio/bin/.pervio-rev"), pub)
        XCTAssertTrue(pub.range(of: "mv -f")!.lowerBound < pub.range(of: ".pervio-rev")!.lowerBound)
        // No restore on the happy path.
        XCTAssertTrue(fake.commandCalls(containing: "bin.prev/*").isEmpty)
    }

    func testFailedSmoke_restoresThePreviousScripts() async throws {
        let dir = try fixtureDir([("a", "A"), ("b.md", "B")])
        let fake = FakeSSH()
        scriptedPave(fake, probe: "0000000000000000\n", smoke: "PERVIO-SMOKE-BAD\n")

        let out = await ServerProvisioner(ssh: fake, binDir: dir)
            .ensureCurrent(profile: TestFactory.profile(), secret: "pw")

        XCTAssertEqual(out, .restored("67d4b8ec06b8888b"))
        XCTAssertEqual(fake.commandCalls(containing: "bin.prev/*").count, 1,
                       "a pave that fails its smoke must put the old set back")
    }

    func testOneAttemptPerLaunch_evenAfterFailure() async throws {
        let dir = try fixtureDir([("a", "A"), ("b.md", "B")])
        let fake = FakeSSH()
        scriptedPave(fake, probe: "PERVIO-NO-REV\n", smoke: "PERVIO-SMOKE-BAD\n")
        let prov = ServerProvisioner(ssh: fake, binDir: dir)
        // ONE profile for both calls — the memo is keyed on (profile, rev), and
        // TestFactory.profile() mints a fresh identity every time.
        let profile = TestFactory.profile()
        _ = await prov.ensureCurrent(profile: profile, secret: "pw")

        let before = fake.calls.count
        let again = await prov.ensureCurrent(profile: profile, secret: "pw")
        XCTAssertEqual(again, .upToDate, "memoed — a broken pave must not loop")
        XCTAssertEqual(fake.calls.count, before, "no further wire traffic: \(fake.calls)")
    }

    // MARK: - Template seeding (write-if-absent, best-effort)

    /// Wire the seed traffic: probe answers `missing` (one name per line),
    /// uploads and the cleanup answer silence. Registration order matters —
    /// FakeSSH matches newest-first, so the specific cleanup needle must come
    /// AFTER the generic ".seed" one to win its own command.
    private func seedScripts(_ fake: FakeSSH, missing: String) {
        fake.script(".seed", "")
        fake.script("rm -rf ~/.pervio/templates/.seed", "")
        fake.script("mkdir -p ~/.pervio/templates && ", missing)
    }

    func testSeedCommands_guardTheLandingAndSweepScratch() {
        let probe = ServerProvisioner.seedProbeCommand(names: ["a.json", "b's.json"])
        XCTAssertTrue(probe.hasPrefix("mkdir -p ~/.pervio/templates && "),
                      "the probe doubles as first-run init: \(probe)")
        XCTAssertTrue(probe.contains(
            "[ -e ~/.pervio/templates/'a.json' ] || printf '%s\\n' 'a.json'"), probe)
        XCTAssertTrue(probe.contains("'b'\\''s.json'"), "quoting must survive an apostrophe")

        let big = Data(repeating: 0x42, count: ServerProvisioner.chunkBytes + 9)
        let cmds = ServerProvisioner.seedChunkCommands(name: "x.json", data: big)
        XCTAssertEqual(cmds.count, 3, "2 chunk appends + 1 guarded landing")
        XCTAssertTrue(cmds.dropLast().allSatisfy {
            $0.contains(">> ~/.pervio/templates/.seed/'x.json'.b64") }, "\(cmds)")
        let joined = cmds.dropLast().compactMap { cmd -> String? in
            guard let a = cmd.range(of: "printf '%s' '"),
                  let b = cmd.range(of: "' >>") else { return nil }
            return String(cmd[a.upperBound..<b.lowerBound])
        }.joined()
        XCTAssertEqual(Data(base64Encoded: joined), big, "chunk math must not lose a byte")
        let land = cmds.last!
        XCTAssertTrue(land.hasPrefix("if [ ! -e ~/.pervio/templates/'x.json' ]; then "),
                      "the landing must be guarded — an existing file is the user's: \(land)")
        XCTAssertTrue(land.contains("mv -n "), "second belt: even the mv refuses to clobber")
        XCTAssertTrue(land.contains("rm -f ~/.pervio/templates/.seed/'x.json'.b64"),
                      "scratch must be swept on both paths")
        XCTAssertFalse(land.contains("chmod"), "templates are data, never executable")
    }

    func testUpToDateServer_seedsOnlyTheMissingTemplates() async throws {
        let bin = try fixtureDir([("a", "A"), ("b.md", "B")])
        let tpl = try fixtureDir([("have.json", "{}"), ("need.json", "{\"n\":1}")])
        let fake = FakeSSH()
        scriptedPave(fake, probe: "67d4b8ec06b8888b\n", smoke: "PERVIO-SMOKE-OK\n")
        seedScripts(fake, missing: "need.json\n")

        let out = await ServerProvisioner(ssh: fake, binDir: bin, templatesDir: tpl)
            .ensureCurrent(profile: TestFactory.profile(), secret: "pw")

        XCTAssertEqual(out, .upToDate, "seeding must not change the verdict")
        XCTAssertFalse(fake.commandCalls(containing: ".seed/'need.json'").isEmpty,
                       "the missing template gets uploaded: \(fake.calls)")
        XCTAssertTrue(fake.commandCalls(containing: ".seed/'have.json'").isEmpty,
                      "a template the server already has is never re-sent")
        XCTAssertEqual(fake.commandCalls(containing: "rm -rf ~/.pervio/templates/.seed").count, 1)
        XCTAssertEqual(fake.calls.last, "disconnect", "seeding rides the open connection")
    }

    func testPavedServer_seedsAfterSmokeOK() async throws {
        let bin = try fixtureDir([("a", "A"), ("b.md", "B")])
        let tpl = try fixtureDir([("x.json", "{}")])
        let fake = FakeSSH()
        scriptedPave(fake, probe: "PERVIO-NO-REV\n", smoke: "PERVIO-SMOKE-OK\n")
        seedScripts(fake, missing: "x.json\n")

        let out = await ServerProvisioner(ssh: fake, binDir: bin, templatesDir: tpl)
            .ensureCurrent(profile: TestFactory.profile(), secret: "pw")

        XCTAssertEqual(out, .paved("67d4b8ec06b8888b"))
        let seq = fake.calls.filter { $0.hasPrefix("run: ") }
        func idx(_ needle: String) -> Int? { seq.firstIndex { $0.contains(needle) } }
        let smoke = try XCTUnwrap(idx("pervio-run list"))
        let seedProbe = try XCTUnwrap(idx("mkdir -p ~/.pervio/templates && "))
        XCTAssertLessThan(smoke, seedProbe,
                          "seeds land only on a server that just proved itself")
    }

    func testFailedSmoke_neverSeeds() async throws {
        let bin = try fixtureDir([("a", "A"), ("b.md", "B")])
        let tpl = try fixtureDir([("x.json", "{}")])
        let fake = FakeSSH()
        scriptedPave(fake, probe: "PERVIO-NO-REV\n", smoke: "PERVIO-SMOKE-BAD\n")
        seedScripts(fake, missing: "x.json\n")

        let out = await ServerProvisioner(ssh: fake, binDir: bin, templatesDir: tpl)
            .ensureCurrent(profile: TestFactory.profile(), secret: "pw")

        XCTAssertEqual(out, .restored("67d4b8ec06b8888b"))
        XCTAssertTrue(fake.commandCalls(containing: "mkdir -p ~/.pervio/templates && ").isEmpty,
                      "a failed pave must not go on planting seeds: \(fake.calls)")
    }

    func testSeedFailure_doesNotChangeTheOutcome() async throws {
        let bin = try fixtureDir([("a", "A"), ("b.md", "B")])
        let tpl = try fixtureDir([("x.json", "{}")])
        let fake = FakeSSH()
        scriptedPave(fake, probe: "PERVIO-NO-REV\n", smoke: "PERVIO-SMOKE-OK\n")
        fake.fail("mkdir -p ~/.pervio/templates && ")

        let out = await ServerProvisioner(ssh: fake, binDir: bin, templatesDir: tpl)
            .ensureCurrent(profile: TestFactory.profile(), secret: "pw")

        XCTAssertEqual(out, .paved("67d4b8ec06b8888b"),
                       "seeds are best-effort — their failure is not the pave's")
        XCTAssertTrue(fake.calls.contains("disconnect"))
    }

    func testAllSeedsPresent_uploadsNothing() async throws {
        let bin = try fixtureDir([("a", "A"), ("b.md", "B")])
        let tpl = try fixtureDir([("x.json", "{}")])
        let fake = FakeSSH()
        scriptedPave(fake, probe: "67d4b8ec06b8888b\n", smoke: "PERVIO-SMOKE-OK\n")
        seedScripts(fake, missing: "")

        let out = await ServerProvisioner(ssh: fake, binDir: bin, templatesDir: tpl)
            .ensureCurrent(profile: TestFactory.profile(), secret: "pw")

        XCTAssertEqual(out, .upToDate)
        XCTAssertTrue(fake.commandCalls(containing: ".seed").isEmpty,
                      "nothing missing, nothing sent: \(fake.calls)")
    }
}
