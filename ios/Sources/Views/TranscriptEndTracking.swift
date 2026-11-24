import SwiftUI

/// Reports how far the reader is from the END of a ScrollView's content —
/// `contentSize.height − visibleRect.maxY` in content points (0 at the very
/// end; `visibleRect` already accounts for the keyboard and safe-area insets,
/// so the true end reads 0, not ~60) — together with the content height, on
/// every scroll and on every content-size change. iOS 18's scroll geometry is
/// the only signal that fires for a plain finger scroll; a GeometryReader +
/// preference in the content is re-read on layout only, which is why the
/// transcript's "at the end" flag went stale while nothing streamed
/// (2026-10-15). On iOS 17 this is a no-op and the preference path stays in
/// charge.
/// The follow decision after a scroll-geometry report, pure so it can be
/// pinned: is the reader (still) at the end?
enum TranscriptEndFollow {
    /// `near`: within reach of the end. `grew`: the content got taller since
    /// the last report (a chunk landed, pushing the end away). `viewportShrank`:
    /// the visible area got shorter with no scroll (the keyboard coming up —
    /// it used to read as the reader leaving, so the follow scroll was skipped
    /// and the latest reply sat under the keyboard, 2026-10-18). Only a finger
    /// — far from the end with neither of those — un-follows.
    static func atEnd(near: Bool, wasAtEnd: Bool, grew: Bool, viewportShrank: Bool) -> Bool {
        if near { return true }
        return wasAtEnd && (grew || viewportShrank)
    }
}

struct TranscriptEndTracking: ViewModifier {
    /// (distance from the end, content height, visible height — the viewport
    /// after the keyboard and safe-area insets; a drop in it with no scroll is
    /// the keyboard coming up, not the reader leaving the end)
    let onDistance: (CGFloat, CGFloat, CGFloat) -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: [CGFloat].self) { g in
                [g.contentSize.height - g.visibleRect.maxY, g.contentSize.height, g.visibleRect.height]
            } action: { _, v in
                if v.count == 3 { onDistance(v[0], v[1], v[2]) }
            }
        } else {
            content
        }
    }
}
