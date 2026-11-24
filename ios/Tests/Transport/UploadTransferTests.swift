import XCTest
import Crypto
@testable import Pervio

/// Lets the upload's own progress callback cancel the upload's own task — the
/// task reference has to exist before the closure that uses it. Main-actor
/// isolated like everything else in this file, so there is no race on `task`
/// itself: the assignment completes before the task body can start running.
@MainActor
private final class UploadTaskBox {
    var task: Task<String, Error>?
}

/// A5: the chunked upload, over a real connection.
///
/// `SSHService.uploadFile` is the one place the app pushes BYTES rather than
/// text: the phone has no stdin channel, so a file goes up as base64 appended to
/// a server-side temp in 100,000-character slices and is decoded by
/// `pervio-upload finish`. Two things can go wrong and both are silent:
///  * a slice boundary that drops or doubles bytes produces a file that still
///    decodes (base64 of the wrong length is still base64) and lands as a
///    plausible-looking document the model then reads as the user's;
///  * an upload that dies half way leaves a temp behind, and the phone shows
///    nothing at all.
/// So this asserts the bytes on disk, not "no error was thrown", and it asserts
/// the boundary case exactly — a file whose base64 is precisely one slice long,
/// and the same file plus one byte, which is where an off-by-one lives.
@MainActor
final class UploadTransferTests: XCTestCase {

    /// `SSHService.uploadFile`'s slice size, in base64 characters. Kept here as
    /// a literal on purpose: reading it off the implementation would make the
    /// boundary tests agree with whatever the implementation currently does.
    private static let sliceChars = 100_000
    /// Where these tests point `launcherDir`. See `provisionUploadLauncher`.
    private static let launcherDir = "~/.pervio/bin-test"
    /// Bytes whose base64 is EXACTLY one slice: 75,000 → 25,000 groups → 100,000
    /// characters, no padding.
    private static let exactlyOneSlice = 75_000

    // MARK: - Round trips

    func testSmallFileArrivesByteForByte() async throws {
        try await assertRoundTrip(byteCount: 4_096, label: "small")
    }

    /// The base64 of this file is exactly `sliceChars` long: the loop must send
    /// one slice and stop, not send an empty second one.
    func testFileWhoseBase64IsExactlyOneSliceArrivesByteForByte() async throws {
        let data = Self.bytes(Self.exactlyOneSlice, seed: 1)
        XCTAssertEqual(data.base64EncodedString().count, Self.sliceChars,
                       "the fixture is meant to sit exactly on the slice boundary")
        try await assertRoundTrip(data: data, label: "exact-boundary")
    }

    /// One byte more than the boundary — the second slice carries 4 characters.
    /// This is where a `<` that should be `<=` (or a chunk length computed from
    /// the wrong index) shows up.
    func testFileOneByteOverTheSliceBoundaryArrivesByteForByte() async throws {
        let data = Self.bytes(Self.exactlyOneSlice + 1, seed: 2)
        XCTAssertEqual(data.base64EncodedString().count, Self.sliceChars + 4)
        try await assertRoundTrip(data: data, label: "boundary-plus-one")
    }

    /// Several full slices, so an ordering bug (slices appended out of order or
    /// one repeated) has room to show.
    func testMultiSliceFileArrivesByteForByte() async throws {
        try await assertRoundTrip(byteCount: 200_000, label: "multi-slice")
    }

    /// Bytes that are hostile to a shell round trip if anything ever stops
    /// base64-ing them: quotes, backslashes, NULs, newlines, and a full 0-255
    /// sweep.
    func testHostileBytesArriveByteForByte() async throws {
        var raw = [UInt8]()
        for b in 0...255 { raw.append(UInt8(b)) }
        raw += Array("'; rm -rf ~ #\n\r\t\\\"$(echo pwned)`id`".utf8)
        raw += [0x00, 0x00, 0xff, 0xfe]
        try await assertRoundTrip(data: Data(raw), label: "hostile")
    }

    // MARK: - A half-finished upload leaves nothing behind

    /// Cancel mid-transfer and require BOTH halves of the promise: the call
    /// reports the cancellation, and the server is left exactly as it was — no
    /// `.b64` temp, no `.part`, and no decoded file with this name.
    ///
    /// If the upload manages to finish before the cancel lands the test FAILS
    /// rather than passing quietly; a race that silently turns into "nothing was
    /// asserted" is the failure mode this whole batch is about.
    func testCancelledUploadLeavesNoHalfFileOnTheServer() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let service = SSHService()
        try await service.connect(profile: endpoint.profile, secret: endpoint.privateKey)
        defer { Task { await service.disconnect() } }
        var profile = endpoint.profile
        try await provisionUploadLauncher(service, &profile)

        let uploadsBefore = try await Self.uploadsListing(service, profile)
        // A stem unique to THIS run: a leftover from an earlier run must not be
        // able to fail (or pass) this one.
        let stem = "interrupted-\(UUID().uuidString.prefix(8))"
        let name = "\(stem).bin"
        let data = Self.bytes(900_000, seed: 7)   // 1,200,000 base64 chars ⇒ 12 slices

        // The cancel is fired from INSIDE the first progress callback, not from a
        // timer in the test. Sleeping until "probably mid-transfer" is exactly the
        // kind of load-sensitive judgement that turns into a flake and then into a
        // quietly-disabled test: on a busy machine the whole upload finished first
        // and there was nothing left to interrupt. Progress is reported after each
        // slice, so cancelling in that callback interrupts deterministically at
        // slice 1 of 12 — every time, on any machine.
        var progressSeen = 0
        let uploaded = profile
        let box = UploadTaskBox()
        box.task = Task { () -> String in
            try await service.uploadFile(profile: uploaded, data: data, filename: name,
                                         onProgress: { _ in
                                             progressSeen += 1
                                             box.task?.cancel()
                                         })
        }

        var thrown: Error?
        do { _ = try await box.task?.value } catch { thrown = error }
        XCTAssertTrue(thrown is CancellationError,
                      "a cancelled upload must report the cancellation, not a success and not a "
                      + "different error: \(String(describing: thrown))")
        XCTAssertEqual(progressSeen, 1,
                       "the cancel must take effect at the first slice; \(progressSeen) slices "
                       + "went out, so this test did not interrupt what it thinks it did")

        let uploadsAfter = try await Self.uploadsListing(service, profile)
        let leakedTemps = uploadsAfter.filter { $0.hasSuffix(".b64") || $0.hasSuffix(".part") }
            .filter { !uploadsBefore.contains($0) }
        XCTAssertEqual(leakedTemps, [], "an interrupted upload left its temp file behind")
        XCTAssertEqual(uploadsAfter.filter { $0.contains(stem) }, [],
                       "an interrupted upload left a decoded file behind")
    }

    // MARK: - Machinery

    private func assertRoundTrip(byteCount: Int, label: String,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        try await assertRoundTrip(data: Self.bytes(byteCount, seed: UInt64(byteCount)),
                                  label: label, file: file, line: line)
    }

    /// Upload `data`, then make the SERVER read back what landed and report its
    /// size and SHA-256. The digest is computed by python3 on the far side, so
    /// agreement means the bytes crossed intact — not that our own encoder and
    /// decoder agree with each other.
    private func assertRoundTrip(data: Data, label: String,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let endpoint = try SandboxEndpoint.discover()
        let service = SSHService()
        try await service.connect(profile: endpoint.profile, secret: endpoint.privateKey)
        defer { Task { await service.disconnect() } }
        var profile = endpoint.profile
        try await provisionUploadLauncher(service, &profile)

        let name = "\(label)-\(UUID().uuidString.prefix(8)).bin"
        var lastProgress = 0.0
        let path = try await service.uploadFile(profile: profile, data: data,
                                                filename: name,
                                                onProgress: { lastProgress = $0 })

        XCTAssertTrue(path.contains("/.pervio/uploads/"),
                      "uploads must land in the launcher's uploads dir, got \(path)",
                      file: file, line: line)
        let home = try await service.runCommand("printf %s \"$HOME\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(path.hasPrefix(home + "/"),
                      "the upload escaped the session's HOME (\(home)): \(path)",
                      file: file, line: line)
        XCTAssertEqual(lastProgress, 1.0, accuracy: 0.0001,
                       "progress must end at 100% for a completed upload",
                       file: file, line: line)

        let probe = "import hashlib,sys;d=open(sys.argv[1],'rb').read();"
            + "print(len(d), hashlib.sha256(d).hexdigest())"
        let answer = try await service.runCommand(
            "python3 -c \(SSHService.shellQuote(probe)) \(SSHService.shellQuote(path))")
        let fields = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init)
        guard fields.count == 2 else {
            return XCTFail("could not read back \(path): \(answer)", file: file, line: line)
        }
        XCTAssertEqual(Int(fields[0]), data.count,
                       "\(label): wrong number of bytes landed", file: file, line: line)
        XCTAssertEqual(fields[1], Self.sha256Hex(data),
                       "\(label): the bytes on the server are not the bytes we sent",
                       file: file, line: line)

        _ = try? await service.runCommand("rm -f \(SSHService.shellQuote(path))")
    }

    /// Install `pervio-upload` into the session's own launcher dir, mode 0755 —
    /// which is exactly what `server/install.sh` does on a real server ("0755
    /// bin/pervio-upload").
    ///
    /// Needed because the e2e sandbox does NOT install: it symlinks
    /// `~/.pervio/bin` straight at the repo's `server/bin`, so the launchers there
    /// carry whatever mode the checkout happens to have — and several of them,
    /// `pervio-upload` among them, are recorded in git as 100644. Running one then
    /// dies with exit 126 ("Permission denied") before a single byte moves, which
    /// looks like a transfer failure and is not one. Copying the REAL script and
    /// giving it the REAL production mode keeps this suite about the transfer.
    private func provisionUploadLauncher(_ service: SSHService,
                                         _ profile: inout ServerProfile) async throws {
        let dir = Self.launcherDir
        let source = profile.uploadLauncher      // the sandbox's ~/.pervio/bin copy
        _ = try await service.runCommand(
            "mkdir -p \(dir) && cp -f \(source) \(dir)/pervio-upload "
            + "&& chmod 0755 \(dir)/pervio-upload && echo PROVISIONED")
        profile.launcherDir = dir
        XCTAssertEqual(profile.uploadLauncher, "\(dir)/pervio-upload",
                       "the profile must actually point at the launcher we installed")
    }

    /// Names currently in the server-side uploads dir (empty list if it has none).
    private static func uploadsListing(_ service: SSHService,
                                       _ profile: ServerProfile) async throws -> [String] {
        let script = "import json,os;d=os.path.expanduser('~/.pervio/uploads');"
            + "print(json.dumps(sorted(os.listdir(d)) if os.path.isdir(d) else []))"
        let out = try await service.runCommand("python3 -c \(SSHService.shellQuote(script))")
        let json = SSHService.jsonSlice(out)
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Deterministic pseudo-random bytes (a plain LCG) — a failing run is
    /// reproducible, and the content is not compressible into "all zeroes",
    /// which would hide a slice that got dropped.
    private static func bytes(_ count: Int, seed: UInt64) -> Data {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        var out = [UInt8]()
        out.reserveCapacity(count)
        for _ in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            out.append(UInt8((state >> 33) & 0xFF))
        }
        return Data(out)
    }
}
