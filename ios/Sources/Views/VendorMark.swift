import SwiftUI

/// A vendor's mark: the vendor's own vector logo when the app carries one
/// (vendor-<preset> in Assets, VENDOR-LOGOS.md), else a small tinted disc with
/// a one- or two-character glyph — 智 for 智谱 GLM, DS for DeepSeek, K for Kimi,
/// M for MiniMax, 千 for 通义千问, OR for OpenRouter, the label's first character
/// for a custom endpoint. Shown wherever a third-party provider is in play —
/// the chat header's engine badge, the provider rows in settings — so "Claude
/// Code running GLM" reads at a glance instead of only from the caption
/// (2026-10-16).
struct VendorMark: View {
    let preset: String?
    let label: String
    var size: CGFloat = 16

    /// (glyph, tint) per vendor — a pure mapping, pinned by VendorMarkTests.
    static func glyph(preset: String?, label: String) -> (text: String, tint: Color) {
        switch preset ?? "" {
        case "glm":        return ("智", Color(red: 0.30, green: 0.45, blue: 0.95))
        case "deepseek":   return ("DS", Color(red: 0.25, green: 0.55, blue: 0.95))
        case "kimi":       return ("K", Color(red: 0.15, green: 0.65, blue: 0.60))
        case "minimax":    return ("M", Color(red: 0.95, green: 0.45, blue: 0.20))
        case "qwen":       return ("千", Color(red: 0.55, green: 0.35, blue: 0.90))
        case "openrouter": return ("OR", Color(red: 0.45, green: 0.45, blue: 0.50))
        // The vendors behind Cursor's models (2026-10-18); their logos ship,
        // these monograms are the fallback should a logo ever be removed.
        case "anthropic":  return ("A", Color(red: 0.85, green: 0.47, blue: 0.34))
        case "openai":     return ("O", Color(red: 0.25, green: 0.25, blue: 0.30))
        case "gemini":     return ("G", Color(red: 0.20, green: 0.50, blue: 0.95))
        case "grok":       return ("X", Color(red: 0.35, green: 0.35, blue: 0.40))
        default:
            let first = label.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
            return (first, Color(red: 0.50, green: 0.50, blue: 0.55))
        }
    }

    /// The vendor's own logo when the app carries one (`vendor-<preset>` in
    /// Assets, see VENDOR-LOGOS.md — the person chose real marks over drawn
    /// ones: open-source, non-commercial, 2026-10-16); the monogram otherwise.
    static func logoName(preset: String?) -> String? {
        guard let p = preset, !p.isEmpty else { return nil }
        // Vendors whose mark the app already carries as an engine icon.
        let alias = ["anthropic": "claude-code", "openai": "codex"]
        let name = alias[p] ?? ("vendor-" + p)
        return UIImage(named: name) != nil ? name : nil
    }

    var body: some View {
        if let name = Self.logoName(preset: preset) {
            // The mark as the vendor draws it: vector, no tile, no clipping (a
            // rounded clip over the old favicons cut their tiles and left 智谱's
            // white square showing, 2026-10-16).
            Image(name)
                .resizable().scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel(label)
        } else {
            let g = Self.glyph(preset: preset, label: label)
            Text(g.text)
                .font(.system(size: g.text.count > 1 ? size * 0.42 : size * 0.58, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(g.tint, in: Circle())
                .accessibilityLabel(label)
        }
    }
}
