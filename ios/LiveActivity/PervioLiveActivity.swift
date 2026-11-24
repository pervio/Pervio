import WidgetKit
import SwiftUI
import ActivityKit

/// The widget extension's entry point. It only hosts the Run Live Activity (no
/// home-screen widgets), so the bundle has a single member.
@main
struct PervioWidgetBundle: WidgetBundle {
    var body: some Widget {
        RunLiveActivity()
    }
}

/// The Dynamic Island / Lock Screen card for a detached Run or a workflow.
///
/// Everything it draws lives in `IslandViews.swift` (which knows nothing about
/// ActivityKit); this file is only the wiring — unpack `ContentState` into plain
/// values and hand them to the right region.
///
/// WHAT MOVES, AND WHY THERE IS NO CLOCK. The card used to lead with a
/// `Text(timerInterval:)` stopwatch, which made a run look like a countdown and
/// said nothing about whether anything was happening. It now spends its motion
/// budget on three things that each answer a different question:
///   * the current trail cell fills itself (`ProgressView(timerInterval:)`) —
///     "something is in progress", true even during a ten-minute Bash call;
///   * the corner refreshes "3 分钟前开始" (`Text(_, style: .relative)`) —
///     "how long has this been going", at minute grain instead of per second;
///   * the tool row, the trail and the otter all change together on each update
///     — "what did it just do, and how far along is it".
struct RunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(IslandPalette.accent)
        } dynamicIsland: { context in
            let st = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandExpandedLeading(title: context.attributes.project,
                                          subtitle: st.status,
                                          step: st.step,
                                          finished: st.finished, failed: st.failed)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandExpandedTrailing(startedAt: context.attributes.startedAt,
                                           finished: st.finished, failed: st.failed,
                                           stale: context.isStale, strings: Self.strings)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // THE TRAIL — the otter's journey. Behind it fills solid; the cell
                    // it is inside fills itself; ahead is a faint dotted path. Under it,
                    // the one line that says what is happening. This is the design.
                    IslandExpandedBottom(done: st.stepsDone, total: st.stepsTotal,
                                         finished: st.finished, failed: st.failed,
                                         current: context.isStale ? nil : st.currentStepWindow,
                                         toolGlyph: Self.glyph(st), toolLine: Self.line(st))
                }
            } compactLeading: {
                IslandOtter(step: st.step, width: 26,
                            finished: st.finished, failed: st.failed)
            } compactTrailing: {
                // `Date()` here only picks WHICH lap of the fixed dial we're on
                // (this closure re-runs when a content update or a SpringBoard
                // re-render lands); the window handed to the ring is absolute,
                // so the sweep inside the lap stays exact regardless. Anchored
                // at the run's start — see ringLap for why not the step's.
                let lap = RunActivityAttributes.ContentState.ringLap(
                    started: context.attributes.startedAt,
                    finished: st.finished, at: Date())
                IslandRing(window: lap?.window, lap: lap?.index ?? 0,
                           finished: st.finished,
                           failed: st.failed, stale: context.isStale)
            } minimal: {
                IslandOtter(step: st.step, width: 24,
                            finished: st.finished, failed: st.failed)
            }
            .widgetURL(URL(string: "pervio://run"))
            .keylineTint(IslandPalette.accent)
        }
    }

    /// The device locale, which is also what `Text(_, style: .relative)` formats
    /// against — see IslandStrings for why the app's language switch can't be read
    /// from this process.
    static var strings: IslandStrings { .forLocale(.current) }

    /// The tool row's text. `toolLine` is the island-shaped one ("Bash · npm
    /// test"); a payload from an older Mac has none, so it falls back to `detail`,
    /// which is exactly the string the previous design showed there.
    static func line(_ s: RunActivityAttributes.ContentState) -> String {
        s.toolLine.isEmpty ? s.detail : s.toolLine
    }

    /// …and its glyph, derived from the line when the supplier didn't name one.
    static func glyph(_ s: RunActivityAttributes.ContentState) -> String {
        s.toolIcon.isEmpty ? IslandGlyph.forLine(line(s)) : s.toolIcon
    }
}

// MARK: - Lock screen / banner (the richest layout)

private struct LockScreenView: View {
    let context: ActivityViewContext<RunActivityAttributes>
    var body: some View {
        let st = context.state
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                IslandOtterTile(step: st.step, size: 48,
                                finished: st.finished, failed: st.failed)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(context.attributes.project).font(.subheadline.bold()).lineLimit(1)
                        Spacer()
                        IslandRelativeTime(start: context.attributes.startedAt,
                                           finished: st.finished, failed: st.failed,
                                           stale: context.isStale, strings: RunLiveActivity.strings)
                    }
                    // The banner has room for the prompt, so it keeps showing that when
                    // there is no live action; the island's bottom row is the tool line.
                    let line = RunLiveActivity.line(st)
                    if !line.isEmpty && !st.finished {
                        Text(line).font(.caption2.monospaced())
                            .foregroundStyle(.secondary).lineLimit(1)
                    } else if !context.attributes.preview.isEmpty {
                        Text(context.attributes.preview).font(.caption)
                            .foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(st.status).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            // The trail rides along the bottom of the banner, same as the island.
            IslandTrail(done: st.stepsDone, total: st.stepsTotal,
                        finished: st.finished, failed: st.failed,
                        current: context.isStale ? nil : st.currentStepWindow)
                .frame(height: 15)
        }
        .padding(14)
    }
}
