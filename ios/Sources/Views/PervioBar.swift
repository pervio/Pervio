import SwiftUI
import UIKit

// MARK: - Pervio's own top-bar items (2026-10-17)
//
// iOS 26 draws every system-bar button as a large glass circle whose size the
// system fixes; on a narrow phone three of them plus a bold title crowd the row
// (the person: 太丑、太挤). Every screen now puts its buttons and its title
// through this file: a 30pt glyph or a plain word with NO capsule (the glass is
// switched off per item on the 26 SDK), and a subheadline title that shrinks
// before it truncates. The bar itself stays the system's — swipe-back, the
// scroll-edge fade and sheet presentation keep working — and because every call
// site comes through here, a fully custom bar later is a change in one file.

/// A glyph button for the bar: 30pt, tinted, no background.
struct BarGlyph: View {
    let systemImage: String
    var tint: Color = .primary
    var label: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? systemImage)
    }
}

/// A word button for the bar ("Done", "Cancel", "Save"): plain text, no capsule.
struct BarWord: View {
    let text: String
    var weight: Font.Weight = .regular
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(text).font(.subheadline.weight(weight)).padding(.horizontal, 2)
                // iOS 26 offers a sheet's cancel item less room than the word
                // needs ("Can…", seen on a 16 Pro Max, 2026-10-17): keep the word whole.
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accent)
    }
}

/// One toolbar item of ours: the content as given, the system's glass hidden.
struct BarItem<Content: View>: ToolbarContent {
    let placement: ToolbarItemPlacement
    @ViewBuilder let content: () -> Content

    init(_ placement: ToolbarItemPlacement, @ViewBuilder content: @escaping () -> Content) {
        self.placement = placement
        self.content = content
    }

    var body: some ToolbarContent {
        // `sharedBackgroundVisibility` exists from the iOS 26 SDK on. `#available`
        // is a run-time question; an older Xcode (16, which the README still
        // promises and CI builds with) does not know the name at all, so the
        // compiler is asked first.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: placement) { content() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement) { content() }
        }
        #else
        ToolbarItem(placement: placement) { content() }
        #endif
    }
}

/// The title as we set it: inline, subheadline, one line that shrinks first.
struct BarTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: 220)
    }
}

extension View {
    /// Pervio's bar for a screen: inline, our title, and — on a pushed screen —
    /// our own back glyph in place of the system's glass one. `back: false` on
    /// a stack's root and inside sheets (they carry Cancel / Done instead).
    func pervioBar(_ title: String, back: Bool = true) -> some View {
        modifier(PervioBarModifier(title: title, back: back))
    }
}

struct PervioBarModifier: ViewModifier {
    let title: String
    let back: Bool
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(back)
            .toolbar {
                BarItem(.principal) { BarTitle(text: title) }
                if back {
                    BarItem(.navigationBarLeading) {
                        BarGlyph(systemImage: "chevron.left", label: "Back") { dismiss() }
                            .accessibilityIdentifier("bar-back")
                    }
                }
            }
    }
}

/// Hiding the system back button switches off the interactive pop gesture;
/// this hands it back, for every stack in the app, once.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
