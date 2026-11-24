import SwiftUI

/// How the chat transcript's ScrollView keeps the reader's place while the
/// content grows under them (a streaming reply, a Duet round landing).
///
/// Root cause of "scrolled up to read, and every new chunk shoved me back
/// down, and the page stuttered" (2026-10-15): the transcript carried a bare
/// `.defaultScrollAnchor(.bottom)`. That modifier is not only the INITIAL
/// position — on every content-size change the OS re-anchors the scroll
/// position to the bottom edge, so each streamed chunk moved a reader who had
/// scrolled away, and the per-chunk animated `scrollTo` the view also fired
/// fought with it. Measured, not inferred (TranscriptAnchoringTests hosts the
/// real scroll view and reads the offsets back), and the same probe ruled out
/// the alternatives on iOS 26: the two-role form (`.bottom` for
/// `.initialOffset` + `.top` for `.sizeChanges`) still re-pins the end on
/// growth, and so does the `.initialOffset` role ALONE (drift 2833pt for a
/// reader at the top). No `defaultScrollAnchor` of any kind survives here.
///
/// What the transcript does instead:
///  * scrolled up → nothing anchors; growth below never moves the reader
///    (UIKit's plain behaviour, measured 0pt drift);
///  * at the end → ChatView follows with an explicit unanimated `scrollTo`
///    per landed chunk, ~16 a second (the chunk coalescer's pace);
///  * opening → the load-time scrollToEnd, as before the anchor existed.
///
/// Kept as a modifier so the contract has one name, one test and one place
/// to change if a future OS separates the roles for real.
struct TranscriptAnchoring: ViewModifier {
    let atBottom: Bool
    func body(content: Content) -> some View { content }
}
