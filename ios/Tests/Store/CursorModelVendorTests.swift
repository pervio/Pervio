import XCTest
@testable import Pervio

/// Cursor's model ids, as its own `agent models` lists them on 2026-10-18, each
/// mapped to the vendor whose mark the badge shows beside the model name.
final class CursorModelVendorTests: XCTestCase {
    func testRealCursorIdsMapToTheirVendors() {
        let cases: [(String, String?)] = [
            ("claude-opus-5-thinking-high", "anthropic"),
            ("claude-fable-5-thinking-high", "anthropic"),
            ("claude-sonnet-5-thinking-high", "anthropic"),
            ("gpt-5.3-codex", "openai"),
            ("gpt-5.2", "openai"),
            ("gpt-5.6-sol-high", "openai"),
            ("o3-pro", "openai"),
            ("gemini-3.7-flash-high", "gemini"),
            ("grok-4.7-high", "grok"),
            ("cursor-grok-4.5-high", "grok"),            // Cursor's hosted copy of a vendor's model
            ("deepseek-v4", "deepseek"),
            ("kimi-k2.5", "kimi"),
            ("auto", nil),                                // Cursor's router
            ("composer-2.5", nil),                        // Cursor's own model
            ("", nil),
            ("something-else", nil),
        ]
        for (id, preset) in cases {
            XCTAssertEqual(CursorModelVendor.of(id)?.preset, preset, id)
        }
    }

    func testCaseAndWhitespaceDoNotMatter() {
        XCTAssertEqual(CursorModelVendor.of("  GPT-5.2 ")?.preset, "openai")
        XCTAssertEqual(CursorModelVendor.of("Claude-Opus-5")?.label, "Anthropic")
    }

    func testAnOpusIdIsNotMistakenForOpenAIsOSeries() {
        XCTAssertEqual(CursorModelVendor.of("opus-5")?.preset, "anthropic")
        XCTAssertEqual(CursorModelVendor.of("o4-mini")?.preset, "openai")
    }
}
