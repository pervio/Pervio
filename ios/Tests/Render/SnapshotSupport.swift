import XCTest
import SwiftUI
import UIKit
@testable import Pervio

/// Layer between the logic suites (301 of them) and the two UI smoke tests: a
/// PIXEL record of what actually reaches the screen, so a regression that a
/// logic test can't see — a Label whose title crowds its icon, a row that wraps,
/// a chip that vanishes under a language switch — turns a snapshot red.
///
/// WHY THIS EXISTS. On 2026-08 an agent read the reader's toolbar code, decided
/// the button TEXT would crowd, and filed a bug — but the toolbar `Label` renders
/// icon-only, so there was nothing to crowd. Reading code to guess pixels is the
/// mistake; these tests render the real view and compare the real pixels.
///
/// NO THIRD-PARTY LIBRARY. iOS 16+'s `ImageRenderer` rasterizes a SwiftUI view
/// to a `UIImage` inside a plain unit test (no host-app UI, no simulator
/// window), and we diff that against a baseline PNG committed next to the other
/// fixtures. First run records the baseline (PERVIO_RECORD_SNAPSHOTS=1); every
/// run after compares.
///
/// DETERMINISM. Rendering is pinned so the same view always produces the same
/// bytes on any machine that runs these:
///   * a fixed logical size per case (no device, no safe-area, no dynamic type
///     from the host),
///   * `scale = 2` baked in (not the host screen's scale),
///   * `.colorScheme(.dark)` forced (the app is dark-only; the host default
///     must not leak in),
///   * a fixed `Palette.bg` behind every view (SwiftUI's default is clear, which
///     rasterizes to premultiplied-black garbage at the edges).
///
/// TOLERANCE. Font rasterization is not bit-identical across OS point releases,
/// so an exact compare would be a tripwire that fires on an Xcode update, not on
/// a real regression. We allow up to 1% of pixels to differ by more than a small
/// per-channel threshold (`channelTolerance`). 1% is enough to absorb
/// antialiasing on glyph edges (a few hundred pixels on these frames) while
/// still catching any change with visible AREA — a moved control, a dropped
/// chip, a Chinese string that didn't switch to English. Cases with heavy text
/// (the morning-report body) are rendered at a size that keeps the text share
/// low; where a screen is almost all text, the assertion is scoped to the part
/// that carries the regression (the top bar), not the whole scroll.
@MainActor
enum Snapshot {

    /// The fraction of pixels allowed to differ beyond `channelTolerance`.
    /// Documented above; 0.01 = 1%.
    static let allowedFraction = 0.01

    /// Per-channel absolute difference (0…255) below which two pixels are "the
    /// same". 12/255 ≈ 4.7% — swallows glyph antialiasing without swallowing a
    /// real color/þlayout change, which moves whole regions by far more.
    static let channelTolerance: UInt8 = 12

    /// True on a recording run. A recording run ALWAYS fails (records then
    /// reports red) so it can never masquerade as a passing comparison — the
    /// same discipline the e2e smoke uses for its skip.
    ///
    /// Two ways to arm it, because an env var set on the `xcodebuild` shell does
    /// NOT reliably reach the test process running on the simulator:
    ///   * PERVIO_RECORD_SNAPSHOTS=1 in the test runner's environment (works via
    ///     a test plan / scheme env, or a plain `xcodebuild … PERVIO_…=1` when
    ///     that setup DOES forward it), or
    ///   * a marker file `.record` next to the baselines in the SOURCE tree —
    ///     `touch ios/Tests/Fixtures/snapshots/.record`. The simulator runs as
    ///     the host user with host-filesystem access, so it can both read this
    ///     marker and write the PNGs back. Delete the marker to return to
    ///     comparing.
    static var isRecording: Bool {
        if ProcessInfo.processInfo.environment["PERVIO_RECORD_SNAPSHOTS"] == "1" { return true }
        return FileManager.default.fileExists(atPath: sourceSnapshotsDir
            .appendingPathComponent(".record").path)
    }

    /// …/ios/Tests/Fixtures/snapshots, located from THIS file's compile-time
    /// path (baked in at build time, valid on the simulator because it shares
    /// the host filesystem). The single source of truth for both the record
    /// marker and where recorded baselines are written.
    static var sourceSnapshotsDir: URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()                // Render
            .deletingLastPathComponent()                // Tests
            .appendingPathComponent("Fixtures/snapshots", isDirectory: true)
    }

    /// Render `view` at `size`, then either record the baseline or compare to it.
    ///
    /// `name` is the baseline's file name (without extension) AND must be unique
    /// across the whole test bundle: xcodegen flattens resource folders, so
    /// `snapshots/foo.png` is looked up as `foo.png`. Every caller uses a
    /// `snap-…-zh` / `snap-…-en` name.
    static func verify<V: View>(_ view: V,
                                size: CGSize,
                                named name: String,
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        guard let png = render(view, size: size) else {
            XCTFail("ImageRenderer produced no image for \(name)", file: file, line: line)
            return
        }
        guard let rendered = decode(png) else {
            XCTFail("could not decode the freshly rendered image for \(name)", file: file, line: line)
            return
        }

        if isRecording {
            record(png, named: name, file: file, line: line)
            return
        }

        let bundle = Bundle(for: Token.self)
        guard let url = bundle.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let baseline = decode(data) else {
            XCTFail("""
                baseline \(name).png is missing from the test bundle. Record it once:
                  PERVIO_RECORD_SNAPSHOTS=1 xcodebuild test -only-testing:PervioTests …
                then commit ios/Tests/Fixtures/snapshots/\(name).png
                """, file: file, line: line)
            return
        }

        guard baseline.width == rendered.width, baseline.height == rendered.height else {
            XCTFail("""
                \(name): size changed — baseline is \(baseline.width)×\(baseline.height), \
                rendered \(rendered.width)×\(rendered.height). A layout change this large \
                is a real diff; re-record only if it is intended.
                """, file: file, line: line)
            return
        }

        let (differing, total) = diff(baseline, rendered)
        let fraction = total == 0 ? 0 : Double(differing) / Double(total)
        if fraction > allowedFraction {
            // Attach both images so a CI failure is diagnosable without a re-run.
            attach(png, name: "\(name).rendered")
            if let b = try? Data(contentsOf: url) { attach(b, name: "\(name).baseline") }
            XCTFail(String(format: """
                %@: %d of %d pixels differ (%.2f%%) beyond the per-channel \
                tolerance — over the %.0f%% budget. Something visible moved. If \
                the change is intended, re-record with PERVIO_RECORD_SNAPSHOTS=1.
                """, name, differing, total, fraction * 100, allowedFraction * 100),
                    file: file, line: line)
        }
    }

    // MARK: - Rendering

    /// The full render pipeline for a case: force dark, sit on the app
    /// background, clip to the logical size, rasterize at scale 2.
    static func render<V: View>(_ view: V, size: CGSize) -> Data? {
        let wrapped = view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Palette.bg)
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(size)
        // isOpaque keeps the alpha channel out of the comparison — the app is
        // never rendered over anything, and a stray alpha edge is exactly the
        // kind of non-visible noise that would eat the 1% budget.
        renderer.isOpaque = true
        guard let image = renderer.uiImage else { return nil }
        return image.pngData()
    }

    // MARK: - Recording

    /// Write the baseline to the SOURCE tree (not the bundle) so it can be
    /// committed. `#filePath` locates this file, and the snapshots dir is a fixed
    /// sibling of the other fixtures.
    ///
    /// PERVIO_SNAPSHOT_OUT (absolute dir) redirects the write. Needed when the
    /// repo lives under ~/Documents: that folder is privacy-protected, and the
    /// simulator's test host writing into it makes macOS pop a "would like to
    /// access your Documents folder" dialog that a headless/SSH run can never
    /// answer — the run wedges at 0% CPU with zero PNGs (2026-10-11, mac mini).
    /// Record into /private/tmp, then copy the PNGs into Fixtures/snapshots.
    private static func record(_ png: Data, named name: String,
                               file: StaticString, line: UInt) {
        let env = ProcessInfo.processInfo.environment["PERVIO_SNAPSHOT_OUT"] ?? ""
        // The marker file may name the output directory itself (an absolute
        // path as its only line) — the env var route does not reach a hosted
        // unit test through `xcodebuild … TEST_RUNNER_…` (2026-10-17).
        let marker = (try? String(contentsOf: sourceSnapshotsDir.appendingPathComponent(".record"),
                                  encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let out = !env.isEmpty ? env : (marker.hasPrefix("/") ? marker : "")
        let dir = out.isEmpty ? sourceSnapshotsDir : URL(fileURLWithPath: out, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let out = dir.appendingPathComponent("\(name).png")
            try png.write(to: out)
            // Recording is never a pass: fail loudly so a left-in env var can't
            // turn the whole suite green by rewriting every baseline.
            XCTFail("recorded baseline \(name).png (\(png.count) bytes) — recording "
                    + "runs always fail; unset PERVIO_RECORD_SNAPSHOTS and re-run to compare.",
                    file: file, line: line)
        } catch {
            XCTFail("failed to write baseline \(name).png: \(error)", file: file, line: line)
        }
    }

    // MARK: - Pixel diff

    private struct Bitmap { let width: Int; let height: Int; let pixels: [UInt8] }

    /// Decode PNG → tightly-packed RGBA8 in sRGB, so two decodes of the same
    /// bytes compare equal regardless of the source's row padding or color space.
    private static func decode(_ data: Data) -> Bitmap? {
        guard let src = UIImage(data: data)?.cgImage else { return nil }
        let w = src.width, h = src.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Bitmap(width: w, height: h, pixels: pixels)
    }

    /// (pixels differing beyond channelTolerance, total pixels).
    private static func diff(_ a: Bitmap, _ b: Bitmap) -> (Int, Int) {
        let total = a.width * a.height
        var differing = 0
        let tol = Int(channelTolerance)
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                var i = 0
                while i < pa.count {
                    let dr = abs(Int(pa[i])     - Int(pb[i]))
                    let dg = abs(Int(pa[i + 1]) - Int(pb[i + 1]))
                    let db = abs(Int(pa[i + 2]) - Int(pb[i + 2]))
                    if dr > tol || dg > tol || db > tol { differing += 1 }
                    i += 4
                }
            }
        }
        return (differing, total)
    }

    // MARK: - Helpers

    private final class Token {}

    private static func attach(_ data: Data, name: String) {
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        XCTContext.runActivity(named: name) { $0.add(a) }
    }
}

// MARK: - Language pinning for snapshots

/// Every snapshot case renders once per language. The app language is the
/// SAME UserDefaults switch the whole UI reads (`pervio.promptLanguage`), so a
/// case sets it, builds the view, renders, and restores it — exactly the seam
/// UIStringsTests drives, but observed in pixels instead of asserted on strings.
@MainActor
enum SnapshotLang {
    private static let key = "pervio.promptLanguage"

    /// Run `body` with the app forced to `lang`, restoring the previous value
    /// afterwards (so cases don't leak the setting into each other or the host).
    static func withLanguage<T>(_ lang: PromptLanguage, _ body: () -> T) -> T {
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        // Always EXPLICIT (2026-09-01): "absent = Chinese" silently became
        // "absent = English" when the shipped default flipped, and every -zh
        // baseline quietly re-recorded with English chrome. A language render
        // must never lean on whatever the default happens to be this month.
        UserDefaults.standard.set(lang.rawValue, forKey: key)
        return body()
    }
}
