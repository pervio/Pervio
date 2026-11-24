import XCTest
import SwiftUI
@testable import Pervio

/// The vendor mark's glyph mapping: every shipped preset has its own glyph, a
/// custom endpoint shows its label's initial, and no two presets collide.
final class VendorMarkTests: XCTestCase {
    func testEveryPresetHasADistinctGlyph() {
        let presets = ["glm", "deepseek", "kimi", "minimax", "qwen", "openrouter", "anthropic", "openai", "gemini", "grok"]
        let glyphs = presets.map { VendorMark.glyph(preset: $0, label: $0).text }
        XCTAssertEqual(Set(glyphs).count, presets.count, "\(glyphs)")
        XCTAssertEqual(VendorMark.glyph(preset: "glm", label: "智谱 GLM").text, "智")
        XCTAssertEqual(VendorMark.glyph(preset: "deepseek", label: "DeepSeek").text, "DS")
    }
    func testACustomEndpointShowsItsInitial() {
        XCTAssertEqual(VendorMark.glyph(preset: nil, label: "my proxy").text, "M")
        XCTAssertEqual(VendorMark.glyph(preset: "", label: " 本地网关").text, "本")
        XCTAssertEqual(VendorMark.glyph(preset: nil, label: "").text, "?")
    }
}

/// The vendor marks are vector assets drawn as the vendors draw them: each one
/// rasterizes to a real mark (not a blank, not a white square — the favicons
/// used before carried one under 智谱's tile, 2026-10-16), the gradient marks
/// keep their gradient, and Kimi's K follows the appearance (black on light,
/// white on dark). Probed on real UIImage rendering, not on file presence.
final class VendorLogoAssetTests: XCTestCase {
    private struct Raster { let opaque: Int; let colours: Int; let corners: [UInt8]; let centre: [UInt8] }

    private func raster(_ name: String, dark: Bool) -> Raster? {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        guard let img = UIImage(named: name, in: Bundle(for: ChatStore.self), compatibleWith: traits) else { return nil }
        let w = 48, h = 48
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = img.cgImage else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var opaque = 0; var colours = Set<UInt32>()
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 200 {
            opaque += 1
            colours.insert(UInt32(px[i] >> 4) << 8 | UInt32(px[i + 1] >> 4) << 4 | UInt32(px[i + 2] >> 4))
        }
        func at(_ x: Int, _ y: Int) -> [UInt8] { Array(px[((y * w) + x) * 4 ..< ((y * w) + x) * 4 + 4]) }
        let corners = [at(0, 0), at(w - 1, 0), at(0, h - 1), at(w - 1, h - 1)].map { $0[3] }
        return Raster(opaque: opaque, colours: colours.count, corners: corners, centre: at(w / 2, h / 2))
    }

    /// The vendors behind Cursor's models: Anthropic and OpenAI reuse the engine
    /// icons the app already carries, Google and xAI have marks of their own.
    func testCursorModelVendorsResolveToAMark() {
        XCTAssertEqual(VendorMark.logoName(preset: "anthropic"), "claude-code")
        XCTAssertEqual(VendorMark.logoName(preset: "openai"), "codex")
        XCTAssertEqual(VendorMark.logoName(preset: "gemini"), "vendor-gemini")
        XCTAssertEqual(VendorMark.logoName(preset: "grok"), "vendor-grok")
        for (name, dark) in [("vendor-grok", false), ("vendor-grok", true), ("vendor-gemini", false)] {
            guard let r = raster(name, dark: dark) else { XCTFail(name); continue }
            XCTAssertGreaterThan(r.opaque, 48 * 48 / 14, "\(name) \(dark ? "dark" : "light"): too little drawn — \(r.opaque) opaque px")
            XCTAssertTrue(r.corners.allSatisfy { $0 < 16 }, "\(name): corners must be transparent — \(r.corners)")
        }
    }

    func testEveryVendorMarkRendersAsAMarkWithTransparentCorners() {
        for p in ["glm", "deepseek", "kimi", "minimax", "qwen", "openrouter", "gemini", "grok"] {
            guard let r = raster("vendor-" + p, dark: false) else { XCTFail("vendor-\(p) missing or unrenderable"); continue }
            XCTAssertGreaterThan(r.opaque, 48 * 48 / 12, "\(p): too little drawn — \(r.opaque) opaque px")
            XCTAssertLessThan(r.opaque, 48 * 48 * 9 / 10, "\(p): a filled square, not a mark — \(r.opaque) opaque px")
            XCTAssertTrue(r.corners.allSatisfy { $0 < 16 }, "\(p): corners must be transparent (no tile, no white square; a stroke grazing a corner is fine) — \(r.corners)")
            XCTAssertNotNil(VendorMark.logoName(preset: p))
        }
    }

    func testGradientMarksKeepTheirGradient() {
        for p in ["minimax", "qwen"] {
            guard let r = raster("vendor-" + p, dark: false) else { XCTFail(p); continue }
            XCTAssertGreaterThanOrEqual(r.colours, 6, "\(p): a flat fill — the gradient did not render (\(r.colours) colours)")
        }
    }

    func testKimiFollowsTheAppearance() {
        guard let light = raster("vendor-kimi", dark: false), let dark = raster("vendor-kimi", dark: true) else { return XCTFail("kimi") }
        // The K's stem: a pixel inside the glyph (x≈4/24, y≈12/24 of the box).
        let stemLight = light.centre, stemDark = dark.centre
        _ = (stemLight, stemDark)
        func stem(_ dark: Bool) -> [UInt8]? {
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            guard let img = UIImage(named: "vendor-kimi", in: Bundle(for: ChatStore.self), compatibleWith: traits), let cg = img.cgImage else { return nil }
            var px = [UInt8](repeating: 0, count: 48 * 48 * 4)
            let ctx = CGContext(data: &px, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 48 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 48, height: 48))
            let x = 9, y = 24
            return Array(px[((y * 48) + x) * 4 ..< ((y * 48) + x) * 4 + 4])
        }
        guard let l = stem(false), let d = stem(true) else { return XCTFail("kimi stem") }
        XCTAssertGreaterThan(l[3], 200, "light: the K must be drawn at the stem \(l)")
        XCTAssertLessThan(l[0], 40, "light: a black K \(l)")
        XCTAssertGreaterThan(d[0], 200, "dark: a white K \(d)")
    }
}
