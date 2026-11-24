import Foundation

/// The vendor behind a Cursor model id, for the mark beside the model name in
/// the engine badge (2026-10-18): Cursor runs many vendors' models under one
/// roof, and the person asked that the mark follow the pick. Cursor's own
/// models (composer-*) and the auto router carry no mark; a "cursor-" prefix
/// is Cursor's hosted copy of a vendor's model (cursor-grok-4.5-high).
enum CursorModelVendor {
    struct Mark: Equatable {
        let preset: String   // the VendorMark preset (its logo or monogram)
        let label: String    // the vendor's name, for accessibility
    }

    private static let table: [(prefixes: [String], preset: String, label: String)] = [
        (["claude", "sonnet", "opus", "haiku", "fable", "mythos"], "anthropic", "Anthropic"),
        (["gpt", "o1", "o3", "o4", "codex", "chatgpt"],             "openai",    "OpenAI"),
        (["gemini"],                                               "gemini",    "Google"),
        (["grok"],                                                 "grok",      "xAI"),
        (["deepseek"],                                             "deepseek",  "DeepSeek"),
        (["kimi", "moonshot"],                                     "kimi",      "Kimi"),
        (["qwen"],                                                 "qwen",      "通义千问"),
        (["glm"],                                                  "glm",       "智谱"),
        (["minimax"],                                              "minimax",   "MiniMax"),
    ]

    static func of(_ modelId: String) -> Mark? {
        var id = modelId.trimmingCharacters(in: .whitespaces).lowercased()
        if id.hasPrefix("cursor-") { id.removeFirst("cursor-".count) }
        guard !id.isEmpty, id != "auto", !id.hasPrefix("composer") else { return nil }
        for row in table where row.prefixes.contains(where: { id.hasPrefix($0) }) {
            return Mark(preset: row.preset, label: row.label)
        }
        return nil
    }
}
