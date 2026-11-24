import XCTest
import SwiftUI

/// Renders the three HomeDashboard design directions to PNGs via ImageRenderer.
/// This is a throwaway render harness (not a product test): it runs
/// on the already-booted simulator with `xcodebuild test`, needs no window, and
/// writes real SwiftUI output — not hand-drawn mockups — to the worktree's
/// design/ directory.
///
/// The output directory is passed in via the DESIGN_OUT env var (an absolute
/// path in the worktree). Rendering at scale 3 gives crisp @3x PNGs.
@MainActor
final class DesignRenderTests: XCTestCase {

    func testRenderThreeDirections() throws {
        // Prefer an explicit DESIGN_OUT; otherwise derive the worktree's design/
        // directory from THIS source file's path (…/design/render/<this file>),
        // so the harness needs no env injection into the simulator test process.
        let dir: URL
        if let env = ProcessInfo.processInfo.environment["DESIGN_OUT"] {
            dir = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            dir = URL(fileURLWithPath: #filePath)      // …/design/render/DesignRenderTests.swift
                .deletingLastPathComponent()            // …/design/render
                .deletingLastPathComponent()            // …/design
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try render(AnyView(DesignA_Newsstand()),  to: dir, name: "direction-A-newsstand-zh.png")
        try render(AnyView(DesignB_CommandBar()),  to: dir, name: "direction-B-commandbar-zh.png")
        try render(AnyView(DesignC_Ledger()),      to: dir, name: "direction-C-ledger-zh.png")
        try render(AnyView(DesignRecommended()),   to: dir, name: "recommended-newsstand-quiet-zh.png")
        try render(AnyView(DesignFinal_BQuietComposer()), to: dir, name: "final-B-quiet-composer-zh.png")
    }

    /// The three Dynamic Island / Live Activity mascot directions (compact +
    /// expanded + terminal states each), plus the shipped implementation preview.
    /// Same throwaway harness; writes design/island-*.png.
    func testRenderIslandDirections() throws {
        let dir = designDir()
        try render(AnyView(IslandDirectionA()), to: dir, name: "island-A-breathing-zh.png")
        try render(AnyView(IslandDirectionB()), to: dir, name: "island-B-trail-zh.png")
        try render(AnyView(IslandDirectionC()), to: dir, name: "island-C-instrument-zh.png")
        try render(AnyView(IslandShipped()),    to: dir, name: "island-final-trail-zh.png")
    }

    /// "时钟之外的活法" — five variants of the shipped trail island, each trading
    /// the mm:ss clock for a different kind of motion (a self-filling current
    /// cell, a changing tool line, rolling digits, nothing at all, and the
    /// combination). Writes design/island-sample-*.png.
    func testRenderIslandMotionSamples() throws {
        let dir = designDir()
        try render(AnyView(IslandSampleStride()), to: dir, name: "island-sample-stride-zh.png")
        try render(AnyView(IslandSampleTool()),   to: dir, name: "island-sample-tool-zh.png")
        try render(AnyView(IslandSampleRoll()),   to: dir, name: "island-sample-roll-zh.png")
        try render(AnyView(IslandSampleQuiet()),  to: dir, name: "island-sample-quiet-zh.png")
        try render(AnyView(IslandSampleCombo()),  to: dir, name: "island-sample-combo-zh.png")
    }

    /// The SHIPPED island, after 样例 5 (组合) landed in production. Renders the
    /// widget's own view structs — not a mockup of them — so this PNG cannot drift
    /// away from what the phone draws. Writes design/island-production-combo-zh.png.
    func testRenderShippedIsland() throws {
        try render(AnyView(IslandProductionCombo()), to: designDir(),
                   name: "island-production-combo-zh.png")
    }

    /// Prefer an explicit DESIGN_OUT; else derive the worktree's design/ directory
    /// from this source file's path.
    private func designDir() -> URL {
        let dir: URL
        if let env = ProcessInfo.processInfo.environment["DESIGN_OUT"] {
            dir = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func render(_ view: AnyView, to dir: URL, name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.isOpaque = true
        guard let img = renderer.uiImage, let data = img.pngData() else {
            XCTFail("ImageRenderer produced no PNG for \(name)"); return
        }
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        // Surface the path + size in the test log so the run is self-verifying.
        NSLog("[design] wrote %@ (%d bytes, %.0fx%.0f)",
              url.path, data.count, img.size.width, img.size.height)
        XCTAssertGreaterThan(data.count, 3000, "\(name) looks empty")
    }
}
