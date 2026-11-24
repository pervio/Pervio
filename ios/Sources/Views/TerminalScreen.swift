import SwiftUI
import UIKit
import CoreText
import SwiftTerm
@preconcurrency import Citadel
import NIOCore

/// A live SSH terminal. Opens a PTY, auto-attaches a reconnect-safe tmux shell
/// (`pervio-term`) in the chosen directory, and renders it with SwiftTerm in a
/// dark "Tokyo Night"-style theme. Because the shell lives in tmux on the server,
/// a dropped connection doesn't kill it — reopening re-attaches the live screen.
struct TerminalScreen: View {
    let profile: ServerProfile
    let secret: String
    let dir: String
    var pillEnabled: Bool = true

    @EnvironmentObject var store: AppStore

    var body: some View {
        ZStack {
            TermTheme.uiBackground.asColor.ignoresSafeArea()
            // A little breathing room so text doesn't hug the screen edges —
            // the bg fills the inset, so it reads as terminal padding (Warp/Ghostty style).
            // The viewport (a UIKit container) pins the terminal's bottom to the
            // keyboard layout guide, so the last lines sit ABOVE the key bar and
            // the custom keyboard instead of under them (a tester's small phone,
            // 2026-10-17); SwiftUI's own avoidance is switched off here so there
            // is exactly one owner of that edge.
            TerminalContainerView(profile: profile, secret: secret, dir: dir)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .pervioBar("Terminal · \((dir as NSString).lastPathComponent)", back: false)
        .onAppear { store.activateRuns(for: profile, secret: secret) }
        .runPill(enabled: pillEnabled)
    }
}

/// A clean dark terminal theme (Tokyo Night palette).
enum TermTheme {
    // Catppuccin Mocha — a soft, warm dark palette widely regarded as the most
    // "premium/cozy" of the popular schemes, vs the colder Tokyo-Night navy.
    static let uiBackground = UIColor(r: 0x1E, g: 0x1E, b: 0x2E)   // base
    static let uiForeground = UIColor(r: 0xCD, g: 0xD6, b: 0xF4)   // text
    static let uiCaret      = UIColor(r: 0xF5, g: 0xE0, b: 0xDC)   // rosewater

    /// 16 ANSI colors (0-7 normal, 8-15 bright) — Catppuccin Mocha.
    static let ansi: [SwiftTerm.Color] = [
        .init(0x45, 0x47, 0x5A), .init(0xF3, 0x8B, 0xA8), .init(0xA6, 0xE3, 0xA1), .init(0xF9, 0xE2, 0xAF),
        .init(0x89, 0xB4, 0xFA), .init(0xF5, 0xC2, 0xE7), .init(0x94, 0xE2, 0xD5), .init(0xBA, 0xC2, 0xDE),
        .init(0x58, 0x5B, 0x70), .init(0xF3, 0x8B, 0xA8), .init(0xA6, 0xE3, 0xA1), .init(0xF9, 0xE2, 0xAF),
        .init(0x89, 0xB4, 0xFA), .init(0xF5, 0xC2, 0xE7), .init(0x94, 0xE2, 0xD5), .init(0xA6, 0xAD, 0xC8),
    ]

    static func apply(to term: SwiftTerm.TerminalView) {
        term.nativeBackgroundColor = uiBackground
        term.nativeForegroundColor = uiForeground
        term.caretColor = uiCaret
        term.installColors(ansi)
    }
}

private extension UIColor {
    convenience init(r: Int, g: Int, b: Int) {
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
    var asColor: SwiftUI.Color { SwiftUI.Color(self) }
}

private extension SwiftTerm.Color {
    /// Build from 8-bit RGB (SwiftTerm stores 16-bit channels; 255*257 = 65535).
    convenience init(_ r: Int, _ g: Int, _ b: Int) {
        self.init(red: UInt16(r * 257), green: UInt16(g * 257), blue: UInt16(b * 257))
    }
}

/// Loads the bundled MesloLGS Nerd Font at runtime (renders powerline /
/// powerlevel10k prompt glyphs), falling back to SF Mono if unavailable.
enum TerminalFont {
    private static var registered = false
    static func mono(_ size: CGFloat) -> UIFont {
        register()
        return UIFont(name: "MesloLGS-NF-Regular", size: size)
            ?? UIFont(name: "MesloLGS NF", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
    private static func register() {
        guard !registered else { return }
        registered = true
        if let url = Bundle.main.url(forResource: "MesloLGS-NF-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

/// A dark, two-row input accessory above the keyboard, giving the terminal what a
/// phone keyboard lacks. Top: a persistent number row. Bottom: a horizontally-
/// scrollable strip (Esc, Tab, arrows (DECCKM-aware), Ctrl-combos, symbols,
/// Home/End/PgUp/PgDn) plus a ⌨ hide-keyboard key pinned on the right. Keys send raw
/// bytes via `onSend`. (⌃ Control lives in the TerminalKeyboard below.)
final class TerminalKeyBar: UIInputView {
    private weak var term: SwiftTerm.TerminalView?
    private let onSend: ([UInt8]) -> Void
    private let scroll = UIScrollView()
    private var digits: [UIButton] = []     // persistent number row (top)
    private var keys: [UIButton] = []        // scrollable shortcuts (bottom)
    private var hideKey: UIButton?
    private let pad: CGFloat = 6
    private let keyH: CGFloat = 38
    private let rowGap: CGFloat = 6
    private let pinW: CGFloat = 46

    init(term: SwiftTerm.TerminalView, onSend: @escaping ([UInt8]) -> Void) {
        self.term = term
        self.onSend = onSend
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 94), inputViewStyle: .keyboard)
        autoresizingMask = .flexibleWidth
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        addSubview(scroll)
        build()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: pad * 2 + keyH * 2 + rowGap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func build() {
        // Top: persistent number row (1–0).
        for ch in "1234567890" {
            let b = styled(String(ch))
            let byte = UInt8(ch.asciiValue ?? 0)
            b.addAction(UIAction { [weak self] _ in self?.onSend([byte]) }, for: .touchUpInside)
            digits.append(b); addSubview(b)
        }
        // Bottom: scrollable shortcuts.
        func add(_ title: String, _ bytes: [UInt8]) {
            let b = styled(title)
            b.addAction(UIAction { [weak self] _ in self?.onSend(bytes) }, for: .touchUpInside)
            keys.append(b); scroll.addSubview(b)
        }
        // Cursor keys must honor DECCKM: in application-cursor mode (vim & many
        // TUIs) arrows are ESC O <x>; in normal mode they're ESC [ <x>.
        func arrow(_ title: String, _ finalByte: UInt8) {
            let b = styled(title)
            b.addAction(UIAction { [weak self] _ in
                let appMode = self?.term?.getTerminal().applicationCursor ?? false
                self?.onSend([0x1b, appMode ? 0x4f : 0x5b, finalByte])   // 0x4f='O', 0x5b='['
            }, for: .touchUpInside)
            keys.append(b); scroll.addSubview(b)
        }
        add("esc", [0x1b]); add("tab", [0x09])
        arrow("←", 0x44); arrow("↓", 0x42); arrow("↑", 0x41); arrow("→", 0x43)
        add("^C", [0x03]); add("^D", [0x04]); add("^Z", [0x1a]); add("^R", [0x12]); add("^L", [0x0c])
        add("/", [0x2f]); add("-", [0x2d]); add("_", [0x5f]); add(".", [0x2e]); add(",", [0x2c])
        add("|", [0x7c]); add("~", [0x7e])
        add("Home", [0x1b, 0x5b, 0x48]); add("End", [0x1b, 0x5b, 0x46])
        add("PgUp", [0x1b, 0x5b, 0x35, 0x7e]); add("PgDn", [0x1b, 0x5b, 0x36, 0x7e])

        // Pinned on the right, OUTSIDE the scroll so it's always reachable. A clear,
        // large SF Symbol — the tiny ⌨︎ glyph was unreadable.
        let kb = UIButton(type: .system)
        kb.setImage(UIImage(systemName: "keyboard.chevron.compact.down",
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)), for: .normal)
        kb.tintColor = .white
        kb.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        kb.layer.cornerRadius = 7
        kb.addAction(UIAction { [weak self] _ in _ = self?.term?.resignFirstResponder() }, for: .touchUpInside)
        addSubview(kb); hideKey = kb
    }

    private func styled(_ title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        b.layer.cornerRadius = 7
        return b
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        // Top row: persistent numbers — 10 equal keys edge to edge.
        let dGap: CGFloat = 5
        let dW = (w - pad * 2 - dGap * 9) / 10
        var dx = pad
        for b in digits {
            b.frame = CGRect(x: dx, y: pad, width: dW, height: keyH)
            dx += dW + dGap
        }
        // Bottom row: ⌨ pinned on the right; shortcuts scroll on the left.
        let barY = pad + keyH + rowGap
        let px = w - pad - pinW
        hideKey?.frame = CGRect(x: px, y: barY, width: pinW, height: keyH)
        scroll.frame = CGRect(x: 0, y: barY, width: max(0, px - pad), height: keyH)
        var x = pad
        for b in keys {
            let bw = max(38, b.intrinsicContentSize.width + 18)
            b.frame = CGRect(x: x, y: 0, width: bw, height: keyH)
            x += bw + pad
        }
        scroll.contentSize = CGSize(width: x, height: keyH)
    }

}

/// A custom keyboard that reproduces iOS's native QWERTY 1:1. The geometry was
/// MEASURED from a real keyboard screenshot and is stored as RATIOS of the keyboard
/// width, so every key scales correctly on any iPhone (SE → Pro Max) — not pinned to
/// one device. Adds the one key a terminal needs that iOS lacks: ⌃ Control (one-shot
/// — the next key becomes its control code) in the slot iOS uses for emoji. A
/// magnified key-press bubble (drawn here) gives the native feel. Keys send raw bytes
/// via `onSend`.
final class TerminalKeyboard: UIInputView {
    private enum RowKind { case ten, nine, edge, bottom }
    private final class KeyButton: UIButton {
        var pop: String?      // magnified label shown on press (letters/symbols only)
        var wide = false      // ⇧ ⌫ 123/ABC/#+= ⏎ : ~1.34× a letter key
    }

    private let onSend: ([UInt8]) -> Void
    private var shift = false
    private var keyLayer = 0       // 0 letters · 1 "123" · 2 "#+="
    private var ctrlMod = false
    private var rows: [(RowKind, [KeyButton])] = []
    private let bubble = UILabel()

    // Ratios measured from a real iOS keyboard (reference image was 1320px wide),
    // expressed as fractions of the keyboard width so layout is device-independent.
    private static let rSide   = 20.0  / 1320      // edge margin
    private static let rGap    = 18.0  / 1320      // gap between keys
    private static let rKeyH   = 134.0 / 112       // key height ÷ letter-key width
    private static let rRowGap = 34.0  / 1320      // vertical gap between rows
    private static let rWide   = 150.0 / 112       // ⇧/⌫ width ÷ letter-key width
    private static let rLayer  = 144.0 / 112       // 123 / ⌃(emoji slot) width ÷ letter-key
    private static let rEnter  = 307.0 / 112       // ⏎ width ÷ letter-key (Apple's big return)
    private static let rTop    = 16.0  / 1320      // top/bottom padding
    private static let accent  = UIColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)

    init(onSend: @escaping ([UInt8]) -> Void) {
        self.onSend = onSend
        let w = UIScreen.main.bounds.width
        super.init(frame: CGRect(x: 0, y: 0, width: w, height: Self.height(for: w, bottomSafe: 0)),
                   inputViewStyle: .keyboard)
        // One sizing contract: UIKit asks (`allowsSelfSizing`), and the answer is
        // the same from every entry point — fitted to the width it is given, the
        // bottom safe area counted once. Before, the initial frame left the safe
        // area out while the intrinsic size put it in, and a width change never
        // re-reported; the keyboard the system measured was not the keyboard it
        // showed, and the terminal was told the wrong height (2026-10-17).
        allowsSelfSizing = true
        autoresizingMask = .flexibleWidth
        bubble.textAlignment = .center
        bubble.textColor = .white
        bubble.font = .systemFont(ofSize: 28, weight: .regular)
        bubble.backgroundColor = UIColor(white: 0.42, alpha: 1)
        bubble.layer.cornerRadius = 8
        bubble.layer.masksToBounds = true
        bubble.isHidden = true
        addSubview(bubble)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private var lastSizingWidth: CGFloat = 0

    private func fittedSize(_ target: CGSize) -> CGSize {
        let proposed = target.width
        let w: CGFloat = (proposed.isFinite && proposed > 0 && proposed < UIView.layoutFittingExpandedSize.width)
            ? proposed : max(bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width, 1)
        return CGSize(width: w, height: ceil(Self.height(for: w, bottomSafe: safeAreaInsets.bottom)))
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: fittedSize(bounds.size).height)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize { fittedSize(targetSize) }

    override func systemLayoutSizeFitting(_ targetSize: CGSize,
                                          withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
                                          verticalFittingPriority: UILayoutPriority) -> CGSize { fittedSize(targetSize) }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// top pad + 4 key rows + a full key-height of whitespace + the home-indicator
    /// safe area, so the bottom row clears the rounded corner like Apple's keyboard.
    private static func height(for W: CGFloat, bottomSafe: CGFloat) -> CGFloat {
        let side = rSide * W, gap = rGap * W
        let unit = (W - 2 * side - gap * 9) / 10
        let keyH = rKeyH * unit
        return rTop * W + keyH * 4 + rRowGap * W * 3 + keyH + bottomSafe
    }

    // MARK: layers

    private func rebuild() {
        rows.forEach { $0.1.forEach { $0.removeFromSuperview() } }
        rows = []
        switch keyLayer {
        case 1:  buildNumbers()
        case 2:  buildSymbols()
        default: buildLetters()
        }
        setNeedsLayout()
    }

    private func buildLetters() {
        addRow(.ten, ["q","w","e","r","t","y","u","i","o","p"].map { letter(shift ? $0.uppercased() : $0) })
        addRow(.nine, ["a","s","d","f","g","h","j","k","l"].map { letter(shift ? $0.uppercased() : $0) })
        addRow(.edge, [shiftKey()] + ["z","x","c","v","b","n","m"].map { letter(shift ? $0.uppercased() : $0) } + [backspaceKey()])
        addRow(.bottom, bottomRow(left: "123", to: 1))
    }

    private func buildNumbers() {
        addRow(.ten, ["1","2","3","4","5","6","7","8","9","0"].map { letter($0) })
        addRow(.ten, ["-","/",":",";","(",")","$","&","@","\""].map { letter($0) })
        addRow(.edge, [layerKey("#+=", to: 2)] + [".",",","?","!","'"].map { letter($0) } + [backspaceKey()])
        addRow(.bottom, bottomRow(left: "ABC", to: 0))
    }

    private func buildSymbols() {
        addRow(.ten, ["[","]","{","}","#","%","^","*","+","="].map { letter($0) })
        addRow(.ten, ["_","\\","|","~","<",">","€","£","¥","•"].map { letter($0) })
        addRow(.edge, [layerKey("123", to: 1)] + [".",",","?","!","'"].map { letter($0) } + [backspaceKey()])
        addRow(.bottom, bottomRow(left: "ABC", to: 0))
    }

    private func bottomRow(left: String, to: Int) -> [KeyButton] {
        [layerKey(left, to: to), ctrlKey(), spaceKey(),
         special("⏎", wide: true) { [weak self] in self?.onSend([0x0d]); self?.clearMods() }]
    }

    // MARK: keys

    private func addRow(_ kind: RowKind, _ keys: [KeyButton]) {
        keys.forEach { addSubview($0) }
        rows.append((kind, keys))
    }

    private func letter(_ s: String) -> KeyButton {
        let b = makeKey(s, special: false)
        b.pop = s
        b.addAction(UIAction { [weak self] _ in self?.sendChar(s) }, for: .touchUpInside)
        b.addTarget(self, action: #selector(popShow(_:)), for: .touchDown)
        b.addTarget(self, action: #selector(popHide), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        return b
    }

    private func sendChar(_ s: String) {
        var bytes = Array(s.utf8)
        if ctrlMod, bytes.count == 1 { bytes = [Self.ctrlByte(bytes[0])] }
        onSend(bytes)
        clearMods()
    }

    private static func ctrlByte(_ b: UInt8) -> UInt8 {
        switch b {
        case 0x20, 0x32, 0x40: return 0x00   // ⌃Space / ⌃2 / ⌃@ → NUL
        case 0x36:             return 0x1e   // ⌃6 → RS
        case 0x38, 0x3f:       return 0x7f   // ⌃8 / ⌃? → DEL
        default:               return b & 0x1f
        }
    }

    private func clearMods() {
        let dirty = ctrlMod || shift
        ctrlMod = false; shift = false
        if dirty { rebuild() }
    }

    private func shiftKey() -> KeyButton {
        let b = special("⇧", wide: true) { [weak self] in self?.shift.toggle(); self?.rebuild() }
        if shift { b.backgroundColor = Self.accent; b.setTitleColor(.black, for: .normal) }
        return b
    }
    private func backspaceKey() -> KeyButton {
        special("⌫", wide: true) { [weak self] in self?.onSend([0x7f]); self?.clearMods() }
    }
    private func layerKey(_ title: String, to: Int) -> KeyButton {
        special(title, wide: true) { [weak self] in self?.shift = false; self?.keyLayer = to; self?.rebuild() }
    }
    private func ctrlKey() -> KeyButton {
        let b = makeKey("⌃", special: true)
        if ctrlMod { b.backgroundColor = Self.accent; b.setTitleColor(.black, for: .normal) }
        b.addAction(UIAction { [weak self] _ in self?.ctrlMod.toggle(); self?.rebuild() }, for: .touchUpInside)
        return b
    }
    private func spaceKey() -> KeyButton {
        let b = makeKey("space", special: true)
        b.addAction(UIAction { [weak self] _ in self?.sendChar(" ") }, for: .touchUpInside)
        return b
    }
    private func special(_ title: String, wide: Bool, _ action: @escaping () -> Void) -> KeyButton {
        let b = makeKey(title, special: true)
        b.wide = wide
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func makeKey(_ title: String, special: Bool) -> KeyButton {
        let b = KeyButton(type: .custom)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: special ? 16 : 22, weight: .regular)
        b.backgroundColor = special ? UIColor(white: 0.28, alpha: 1) : UIColor(white: 0.42, alpha: 1)
        b.layer.cornerRadius = 5
        return b
    }

    // MARK: press bubble

    @objc private func popShow(_ sender: UIButton) {
        guard let k = sender as? KeyButton, let t = k.pop else { return }
        bubble.text = t
        let w = k.frame.width * 1.45, h = k.frame.height * 1.45
        let x = min(max(2, k.frame.midX - w / 2), bounds.width - w - 2)
        bubble.frame = CGRect(x: x, y: k.frame.minY - h - 5, width: w, height: h)
        bubble.isHidden = false
        bringSubviewToFront(bubble)
    }
    @objc private func popHide() { bubble.isHidden = true }

    // MARK: layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastSizingWidth {       // a width change changes the height too
            lastSizingWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        guard !rows.isEmpty else { return }
        let W = bounds.width
        let side = Self.rSide * W, gap = Self.rGap * W
        let unit = (W - 2 * side - gap * 9) / 10
        let keyH = Self.rKeyH * unit
        let rowGap = Self.rRowGap * W
        let wideW = Self.rWide * unit
        var y = Self.rTop * W
        for (kind, keys) in rows {
            place(kind, keys, y: y, h: keyH, W: W, side: side, gap: gap, unit: unit, wideW: wideW)
            y += keyH + rowGap
        }
    }

    private func place(_ kind: RowKind, _ keys: [KeyButton], y: CGFloat, h: CGFloat,
                       W: CGFloat, side: CGFloat, gap: CGFloat, unit: CGFloat, wideW: CGFloat) {
        switch kind {
        case .ten:
            var x = side
            for b in keys { b.frame = CGRect(x: x, y: y, width: unit, height: h); x += unit + gap }
        case .nine:
            let rowW = unit * CGFloat(keys.count) + gap * CGFloat(keys.count - 1)
            var x = side + (W - 2 * side - rowW) / 2
            for b in keys { b.frame = CGRect(x: x, y: y, width: unit, height: h); x += unit + gap }
        case .edge:
            keys.first!.frame = CGRect(x: side, y: y, width: wideW, height: h)
            keys.last!.frame  = CGRect(x: W - side - wideW, y: y, width: wideW, height: h)
            let mid = keys.dropFirst().dropLast()
            let r0 = side + wideW, r1 = W - side - wideW
            let midW = unit * CGFloat(mid.count) + gap * CGFloat(max(0, mid.count - 1))
            var x = r0 + ((r1 - r0) - midW) / 2
            for b in mid { b.frame = CGRect(x: x, y: y, width: unit, height: h); x += unit + gap }
        case .bottom:
            // 123 · ⌃(emoji slot) · space · ⏎ at Apple's measured widths (123=⌃=1.29×,
            // ⏎=2.74× a letter) — the big return balances the two left keys so space
            // lands centered.
            let l = keys[0], c = keys[1], s = keys[2], e = keys[3]
            let lw = Self.rLayer * unit, ew = Self.rEnter * unit
            l.frame = CGRect(x: side, y: y, width: lw, height: h)
            let cx = side + lw + gap
            c.frame = CGRect(x: cx, y: y, width: lw, height: h)
            e.frame = CGRect(x: W - side - ew, y: y, width: ew, height: h)
            let sx = cx + lw + gap, sEnd = W - side - ew - gap
            s.frame = CGRect(x: sx, y: y, width: max(unit, sEnd - sx), height: h)
        }
    }
}

/// SwiftTerm's view with the window-size queries answered with silence.
/// tmux 3.x asks the outer terminal for its size in characters and pixels
/// (CSI 18 t / CSI 14 t) when a client attaches; SwiftTerm answers (CSI 8;rows;
/// cols t …), and when that answer lands after tmux has stopped waiting — a
/// slow link, a resize mid-attach — tmux forwards it to the pane as keystrokes
/// and the shell prints ";25;52t … command not found" (seen on every attach in
/// the sandbox, 2026-10-17). tmux already knows the size from the PTY, so the
/// queries get no answer at all.
final class PervioTerminalView: SwiftTerm.TerminalView {
    override func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        switch command {
        case .reportTextAreaCharacters, .reportScreenSizeCharacters,
             .reportTextAreaPixelDimension, .reportTerminalWindowPixelDimension,
             .reportSizeOfScreenInPixels, .reportCellSizeInPixels:
            return []
        default:
            return super.windowCommand(source: source, command: command)
        }
    }
}

/// The terminal's viewport: a plain UIView that owns the terminal's frame —
/// 10pt side padding, 6pt on top, and its BOTTOM on the keyboard layout
/// guide, so when the keyboard (with our key bar and custom keys) rises the
/// terminal shrinks and SwiftTerm re-rows to what is actually visible.
final class TerminalViewport: UIView {
    let terminal: SwiftTerm.TerminalView

    init(terminal: SwiftTerm.TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        backgroundColor = TermTheme.uiBackground
        terminal.contentInsetAdjustmentBehavior = .never
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            terminal.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
}

private struct TerminalContainerView: UIViewRepresentable {
    let profile: ServerProfile
    let secret: String
    let dir: String
    @AppStorage(TextSize.defaultsKey) private var textSizeRaw = ""

    func makeCoordinator() -> Coordinator {
        Coordinator(profile: profile, secret: secret, dir: dir)
    }

    func makeUIView(context: Context) -> TerminalViewport {
        let font = TerminalFont.mono(TextSize.current.terminalPointSize)
        let term = PervioTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), font: font)
        TermTheme.apply(to: term)
        // Dark keyboard + accessory bar so the bottom key row matches the theme
        // instead of rendering as a light system bar over the navy terminal.
        term.keyboardAppearance = .dark
        // Use long-press/drag for text selection (tap "Copy") rather than forwarding
        // gestures to the remote app as mouse events — makes copy reliable on a phone.
        term.allowMouseReporting = false
        term.selectionHandleColor = TermTheme.uiCaret
        term.terminalDelegate = context.coordinator
        context.coordinator.attach(term)
        // Our own dark accessory above the system keyboard: a persistent number row
        // + a scrollable strip of keys a phone keyboard lacks (Esc/Tab/Ctrl-combos/
        // arrows/…), plus a pinned one-shot ⌃ and a hide-keyboard key.
        let coord = context.coordinator
        // Accessory above the keyboard: persistent number row + esc/tab/arrows/⌨.
        term.inputAccessoryView = TerminalKeyBar(term: term) { [weak coord] bytes in
            Haptics.tick(); coord?.sendBytes(bytes)
        }
        // Custom keyboard: a 1:1, size-adaptive reproduction of the native QWERTY
        // (geometry measured from a real screenshot, stored as width ratios) with ⌃
        // Control in the emoji slot. Keys send raw bytes straight to the PTY.
        term.inputView = TerminalKeyboard { [weak coord] bytes in
            Haptics.tick(); coord?.sendBytes(bytes)
        }
        return TerminalViewport(terminal: term)
    }

    func updateUIView(_ uiView: TerminalViewport, context: Context) {
        // The text-size setting changes the terminal's font live.
        let size = TextSize(rawValue: textSizeRaw).map(\.terminalPointSize) ?? TextSize.system.terminalPointSize
        if abs(uiView.terminal.font.pointSize - size) > 0.1 {
            uiView.terminal.font = TerminalFont.mono(size)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TerminalViewport, context: Context) -> CGSize? {
        guard let w = proposal.width, let h = proposal.height, w.isFinite, h.isFinite else { return nil }
        return CGSize(width: max(0, w), height: max(0, h))
    }

    static func dismantleUIView(_ uiView: TerminalViewport, coordinator: Coordinator) {
        // DETACH the custom keyboard before resigning — its non-standard input-view
        // frame otherwise lingers in the system and breaks the chat composer's
        // keyboard-avoidance (the input box ends up covered) when you return.
        let term = uiView.terminal
        term.inputView = nil
        term.inputAccessoryView = nil
        term.resignFirstResponder()
        coordinator.stop()
    }

    // @unchecked Sendable: every member is only touched on the main thread
    // (SwiftTerm delegate callbacks + UI), so capturing the coordinator in the
    // SSH Task's @Sendable closures is safe. Silences capture warnings without
    // changing isolation.
    final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
        private let profile: ServerProfile
        private let secret: String
        private let dir: String
        private let ssh = SSHService()
        private weak var term: SwiftTerm.TerminalView?
        private var writer: TTYStdinWriter?
        private var task: Task<Void, Never>?
        private var started = false
        // The terminal's current size. Kept in sync with the PTY so a TUI like
        // Claude/htop renders at the right width (otherwise output overlaps).
        private var lastCols = 80
        private var lastRows = 24

        init(profile: ServerProfile, secret: String, dir: String) {
            self.profile = profile
            self.secret = secret
            self.dir = dir
        }

        func attach(_ term: SwiftTerm.TerminalView) {
            self.term = term
            guard !started else { return }
            started = true

            lastCols = max(term.getTerminal().cols, 20)
            lastRows = max(term.getTerminal().rows, 8)
            let session = Self.sessionName(for: dir)
            let cmd = "exec \(profile.termLauncher) --session \(shq(session)) --dir \(shq(dir))"

            task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.ssh.connect(profile: self.profile, secret: self.secret)
                    try await self.ssh.runTerminal(
                        cols: self.lastCols, rows: self.lastRows, initialCommand: cmd,
                        onOutput: { [weak self] bytes in
                            DispatchQueue.main.async { self?.term?.feed(byteArray: bytes[...]) }
                        },
                        onReady: { [weak self] writer in
                            DispatchQueue.main.async {
                                guard let self else { return }
                                self.writer = writer
                                // Push the real current size now that we can write,
                                // so tmux/Claude redraw at the correct width.
                                self.sendResize(cols: self.lastCols, rows: self.lastRows)
                            }
                        }
                    )
                    DispatchQueue.main.async { self.term?.feed(text: "\r\n[session ended]\r\n") }
                } catch {
                    NSLog("[Pervio] terminal disconnected — %@", String(reflecting: error))
                    DispatchQueue.main.async {
                        self.term?.feed(text: "\r\n[disconnected]\r\n")
                    }
                }
            }
        }

        func stop() {
            task?.cancel()
            Task { await ssh.disconnect() }
        }

        private func sendResize(cols: Int, rows: Int) {
            guard let writer else { return }
            Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
        }

        private static func sessionName(for dir: String) -> String {
            let mapped = String(dir.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
            let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return trimmed.isEmpty ? "main" : trimmed
        }

        private func shq(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        // MARK: TerminalViewDelegate

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            guard let writer else { return }
            let bytes = Array(data)
            Task { try? await writer.write(ByteBuffer(bytes: bytes)) }
        }

        /// Inject raw bytes straight to the PTY (used by the custom key bar for
        /// Esc/Tab/arrows/Ctrl-combos — keys the iOS keyboard doesn't have).
        func sendBytes(_ bytes: [UInt8]) {
            guard let writer else { return }
            Task { try? await writer.write(ByteBuffer(bytes: bytes)) }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            lastCols = newCols
            lastRows = newRows
            sendResize(cols: newCols, rows: newRows)
        }

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }
        func clipboardRead(source: SwiftTerm.TerminalView) -> Data? {
            UIPasteboard.general.string?.data(using: .utf8)
        }

        // Unused delegate requirements (no default implementations in SwiftTerm).
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
