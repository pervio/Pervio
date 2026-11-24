import SwiftUI
import UIKit

/// Read-only prose that is *properly* selectable: real iOS selection (loupe, drag
/// handles, partial select, Copy / Look Up / Share), backed by UITextView.
///
/// Why not `.textSelection(.enabled)` on `Text`? Inside a `LazyVStack` in a
/// `ScrollView` it's unreliable — long-press often fails to start a selection.
/// UITextView gives the native behavior every time; we resolve the markdown runs
/// to concrete fonts so **bold**, *italic*, `code` and links still render.
struct SelectableText: View {
    /// One custom item appended to the NATIVE selection/edit menu (Copy / Select
    /// All / …). This is how the user bubble grows a long-press menu entry
    /// (「从这里重新说」) without trading away real text selection — a whole-message
    /// .contextMenu would (see MessageRow's comment).
    struct EditMenuItem {
        let title: String
        var systemImage: String = "arrow.uturn.backward"
        let action: () -> Void
    }

    private let attributed: NSAttributedString
    private let menuItem: EditMenuItem?
    private var menuItems: [EditMenuItem] = []
    private var allMenuItems: [EditMenuItem] { (menuItem.map { [$0] } ?? []) + menuItems }

    /// Show a prebuilt attributed string (the whole-message renderer uses this).
    init(attributed: NSAttributedString) {
        self.attributed = attributed
        self.menuItem = nil
    }

    /// Convenience: render a single inline-markdown string.
    init(markdown: String, color: UIColor = .label) {
        self.attributed = Self.render(markdown, color: color)
        self.menuItem = nil
    }

    /// Convenience: render plain text verbatim (no markdown interpretation) — used
    /// for the user's own message bubbles, so e.g. a typed `*foo*` stays literal.
    /// `menuItem` (optional) rides the native edit menu shown on long-press.
    /// Several items (user bubble: rewind AND branch, 2026-10-16).
    init(plain: String, color: UIColor = .label, menuItems: [EditMenuItem]) {
        self.init(plain: plain, color: color, menuItem: nil)
        self.menuItems = menuItems
    }

    init(plain: String, color: UIColor = .label, menuItem: EditMenuItem? = nil) {
        self.attributed = NSAttributedString(
            string: plain,
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body),
                         .foregroundColor: color])
        self.menuItem = menuItem
    }

    @Environment(\.openServerFile) private var openServerFile
    @Environment(\.openLocalURL) private var openLocalURL
    @Environment(\.dynamicTypeSize) private var typeSize   // Settings → text size

    var body: some View {
        TextViewRepresentable(attributed: attributed, menuItems: allMenuItems,
                              openServerFile: openServerFile?.call, openLocalURL: openLocalURL?.call,
                              typeSize: typeSize)
    }

    /// Inline markdown → NSAttributedString with concrete fonts (UITextView won't
    /// render presentation-intent attributes on its own).
    static func render(_ s: String, color: UIColor) -> NSAttributedString {
        let base = UIFont.preferredFont(forTextStyle: .body)
        guard let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSAttributedString(string: s, attributes: [.font: base, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in attr.runs {
            let piece = String(attr[run.range].characters)
            var font = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
                } else {
                    var traits: UIFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                    if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                    if !traits.isEmpty, let d = base.fontDescriptor.withSymbolicTraits(traits) {
                        font = UIFont(descriptor: d, size: base.pointSize)
                    }
                }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let link = run.link { attrs[.link] = ServerFileLink.rewrite(link) ?? link }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}

private struct TextViewRepresentable: UIViewRepresentable {
    let attributed: NSAttributedString
    var menuItems: [SelectableText.EditMenuItem] = []
    /// Where a tap on a `pervio-file:` link goes (the view that can present
    /// the preview sheet installs it); nil leaves such links inert.
    var openServerFile: ((String) -> Void)? = nil
    /// Where a tap on a localhost link goes (the web preview, 2026-11-06).
    var openLocalURL: ((URL) -> Void)? = nil
    /// The environment's dynamic type step: UIKit text is scaled to it by hand
    /// (TypeScale), since UITextView only follows the phone's own setting.
    var typeSize: DynamicTypeSize = .large

    /// Delegate that appends the custom item to the system edit menu. The
    /// delegate is only INSTALLED while a menu item rides along (see below), so
    /// plain prose keeps UITextView's untouched default behaviors.
    final class Coordinator: NSObject, UITextViewDelegate {
        var menuItems: [SelectableText.EditMenuItem] = []
        var openServerFile: ((String) -> Void)?
        var openLocalURL: ((URL) -> Void)?
        /// What the text view currently shows, as handed in (unscaled) and the
        /// scale it was shown at — so an update that brings the same text at
        /// the same size sets nothing and TextKit lays nothing out again.
        var appliedSource: NSAttributedString?
        var appliedFactor: CGFloat = 1

        /// `pervio-file:` links are ours: hand the path to the preview sheet
        /// and swallow the tap (UIKit would otherwise try the scheme and fail
        /// silently). A localhost link (the agent: "it's on http://localhost:3000")
        /// opens the web preview through the Mac (2026-11-06) — Safari on the
        /// phone could never reach it. Every other link keeps the system behaviour.
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            if let path = ServerFileLink.path(of: URL) {
                if interaction == .invokeDefaultAction { openServerFile?(path) }
                return false
            }
            if WebPreview.isLocal(URL), let open = openLocalURL {
                if interaction == .invokeDefaultAction { open(URL) }
                return false
            }
            return true
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard !menuItems.isEmpty else { return nil }   // none → the default menu
            let extra = menuItems.map { item in
                UIAction(title: item.title, image: UIImage(systemName: item.systemImage)) { _ in item.action() }
            }
            return UIMenu(children: suggestedActions + extra)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        // Force TextKit 1 (eager layout). On iOS 16+ UITextView defaults to TextKit 2,
        // which lays text out lazily by viewport — so `usedRect` below, asked to size a
        // non-scrolling view, reports only the portion TextKit 2 has laid out and the
        // tail of a long message gets clipped (the "history looks truncated" bug).
        // TextKit 1 lays everything out up front, so the measured height is complete.
        let tv = UITextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false                 // wrap + size to content
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        // Off: sizes come from TypeScale on every update (the phone's setting
        // reaches us through the environment too), never from UIKit behind our back.
        tv.adjustsFontForContentSizeCategory = false
        tv.dataDetectorTypes = []                  // links come from the attributed string
        tv.tintColor = UIColor(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
        let factor = TypeScale.factor(for: typeSize)
        tv.attributedText = attributed.scaled(by: factor)   // present before first sizing pass
        context.coordinator.appliedSource = attributed
        context.coordinator.appliedFactor = factor
        context.coordinator.menuItems = menuItems
        context.coordinator.openServerFile = openServerFile
        context.coordinator.openLocalURL = openLocalURL
        // The delegate is always on now: it routes pervio-file taps, and only
        // adds the edit-menu item when one rides along (nil → default menu).
        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Set the text only when it IS new text (or a new size): SwiftUI may
        // run this update for reasons that changed nothing here — a parent
        // re-evaluated, an environment value re-applied — and each set costs a
        // full TextKit layout plus a re-measure of the row. The prose memo hands
        // the same object for the same markdown, so identity settles most
        // updates; a fresh object with the same characters (a user bubble built
        // in its row's body) is settled by content.
        let co = context.coordinator
        let factor = TypeScale.factor(for: typeSize)
        let sameText = co.appliedSource.map { $0 === attributed || $0.isEqual(to: attributed) } ?? false
        if !sameText || abs(factor - co.appliedFactor) > 0.001 {
            tv.attributedText = attributed.scaled(by: factor)
            co.appliedSource = attributed
            co.appliedFactor = factor
        }
        // The item can appear on a bubble AFTER first render (its server uuid is
        // back-filled once the turn lands), so keep the delegate in step both ways.
        context.coordinator.menuItems = menuItems
        context.coordinator.openServerFile = openServerFile
        context.coordinator.openLocalURL = openLocalURL
        tv.delegate = context.coordinator
    }

    /// SwiftUI proposes a max width; we wrap the text to it and report the size the
    /// content actually needs — width HUGS the longest line (capped at the proposal)
    /// so a right-aligned user bubble shrinks to its text instead of stretching the
    /// full row, while a long wrapped paragraph still fills the available width.
    /// `usedRect` is the canonical reliable measurement here.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let proposed = proposal.width ?? UIScreen.main.bounds.width
        let maxWidth = (proposed.isFinite && proposed > 0) ? proposed : UIScreen.main.bounds.width - 32
        uiView.textContainer.size = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        uiView.layoutManager.ensureLayout(for: uiView.textContainer)
        let used = uiView.layoutManager.usedRect(for: uiView.textContainer).size
        // Belt-and-suspenders: take the taller of usedRect and UITextView's own
        // sizeThatFits so we never report a height that clips the last line(s).
        let fit = uiView.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(used.width), maxWidth),
                      height: ceil(max(used.height, fit.height)))
    }
}
