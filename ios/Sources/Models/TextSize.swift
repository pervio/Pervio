import SwiftUI
import UIKit

/// The person's text size for the app (2026-10-17): a step applied to every
/// text style at once — titles stay bigger than captions, everything moves
/// together, like the system's own Text Size setting — plus the terminal's
/// monospace size. "system" leaves the phone's setting in charge.
enum TextSize: String, CaseIterable, Identifiable {
    case system, small, medium, large
    var id: String { rawValue }
    static let defaultsKey = "pervio.textSize"

    static var current: TextSize {
        TextSize(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

    /// The dynamic type step the app pins itself to; nil = follow the system.
    var dynamic: DynamicTypeSize? {
        switch self {
        case .system: return nil
        case .small:  return .small
        case .medium: return .large      // iOS's default body size
        case .large:  return .xLarge
        }
    }

    var terminalPointSize: CGFloat {
        switch self {
        case .system, .medium: return 12
        case .small:  return 11
        case .large:  return 14
        }
    }

    func displayName(_ lang: PromptLanguage = .current) -> String {
        switch self {
        case .system: return lang == .chinese ? "跟随系统" : "System"
        case .small:  return lang == .chinese ? "小" : "Small"
        case .medium: return lang == .chinese ? "中" : "Medium"
        case .large:  return lang == .chinese ? "大" : "Large"
        }
    }
}

/// Applies the setting: a fixed dynamic type step, or (system) nothing. One
/// branch, through the environment, so flipping system ↔ a step changes the
/// size without rebuilding the tree underneath (an open sheet stays open).
struct TextSizeModifier: ViewModifier {
    @AppStorage(TextSize.defaultsKey) private var raw = ""
    func body(content: Content) -> some View {
        let step = TextSize(rawValue: raw)?.dynamic
        content.transformEnvironment(\.dynamicTypeSize) { size in
            if let step { size = step }
        }
    }
}

/// The app's root wrapper: a View (not a modifier) owning the setting, so the
/// scene re-renders its content when the person changes it.
struct TextSized<Content: View>: View {
    @AppStorage(TextSize.defaultsKey) private var raw = ""
    @ViewBuilder let content: () -> Content
    var body: some View {
        let step = TextSize(rawValue: raw)?.dynamic
        content().transformEnvironment(\.dynamicTypeSize) { size in
            if let step { size = step }
        }
    }
}

// MARK: - UIKit-rendered text follows the setting too

extension DynamicTypeSize {
    /// The UIKit content size category this step corresponds to.
    var uiCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

/// SwiftUI text follows `dynamicTypeSize` by itself; text drawn by UIKit (the
/// chat bubbles' UITextView, the markdown renderer's fonts) resolves against the
/// phone's own setting and never sees ours (Settings → 大 moved nothing in the
/// chat, 2026-10-17). This is the bridge: how much bigger body text is at the
/// environment's step than at the phone's setting — 1 when they agree.
enum TypeScale {
    static func factor(for size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: size.uiCategory)
        let target = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize
        let base = UIFont.preferredFont(forTextStyle: .body).pointSize
        return base > 0 ? target / base : 1
    }
}

extension NSAttributedString {
    /// Every font and paragraph metric multiplied by `factor` (1 → self), so
    /// headings, code and prose keep their proportions while all of it moves.
    func scaled(by factor: CGFloat) -> NSAttributedString {
        guard abs(factor - 1) > 0.001, length > 0 else { return self }
        let m = NSMutableAttributedString(attributedString: self)
        let all = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.font, in: all) { value, range, _ in
            guard let font = value as? UIFont else { return }
            m.addAttribute(.font, value: font.withSize(font.pointSize * factor), range: range)
        }
        m.enumerateAttribute(.paragraphStyle, in: all) { value, range, _ in
            guard let style = value as? NSParagraphStyle,
                  let c = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            c.minimumLineHeight *= factor
            c.maximumLineHeight *= factor
            c.lineSpacing *= factor
            c.paragraphSpacing *= factor
            c.paragraphSpacingBefore *= factor
            c.headIndent *= factor
            c.firstLineHeadIndent *= factor
            m.addAttribute(.paragraphStyle, value: c, range: range)
        }
        return m
    }
}
