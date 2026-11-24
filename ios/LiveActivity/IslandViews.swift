import SwiftUI

// =====================================================================
// THE ISLAND'S PARTS
// =====================================================================
// Every drawable piece of the Dynamic Island / Lock Screen card, with NO
// dependency on ActivityKit, on `RunActivityAttributes`, or on the app. That is
// deliberate: this one file is compiled into THREE targets (see project.yml) —
// the widget extension that ships it, the unit-test bundle that snapshots it,
// and the design render harness that draws the PNGs — and a dependency on any
// of the others would make that impossible. `PervioLiveActivity.swift` is the
// only place that knows about ContentState; it unpacks it into these plain
// parameters.
//
// THE MOTION BUDGET (why this looks the way it does). A Live Activity is a
// STATIC SNAPSHOT: SpringBoard re-renders it only when new ContentState lands.
// It cannot run a frame loop — no breathing, no blinking, no looping walk
// cycle, ever. Exactly three things move with no update from us:
//   1. Text(timerInterval:)          — the system ticks mm:ss
//   2. ProgressView(timerInterval:)  — the system FILLS a bar / sweeps a ring
//   3. Text(date, style: .relative)  — the system refreshes "3 分钟"
// and one thing moves AT the moment of an update: the whole card redraws.
// The card spends #2 on the CURRENT trail cell (proof of life between tool
// calls) and on the compact ring, #3 on the "跑了多久" corner, and the redraw
// on the otter's frame + the trail growing + the tool row's text. It
// deliberately spends NOTHING on #1: a stopwatch was the old design, and a
// ticking mm:ss is the one thing that made the card feel like a timer instead
// of like work happening.

// MARK: - Brand (restated: this file links nothing from the app)

enum IslandPalette {
    static let accent     = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255) // terracotta
    static let accentDeep = Color(red: 0xC1 / 255, green: 0x5F / 255, blue: 0x3C / 255) // Crail
    static let cream      = Color(red: 0xF9 / 255, green: 0xF4 / 255, blue: 0xF0 / 255) // card
    static let good       = Color(red: 0x5B / 255, green: 0x8C / 255, blue: 0x5A / 255) // muted forest (done)
    static let bad        = Color(red: 0xC4 / 255, green: 0x5A / 255, blue: 0x3A / 255) // rust (failed)

    /// The compact ring's lap shades, lightest first: each finished lap of the
    /// dial hands the next sweep a deeper terracotta, so the ring's COLOR says
    /// how long the run has been going (pale clay = its first minute, fired
    /// umber = a long haul). Indexed by `ringLap().index` and clamped past the
    /// end — late laps keep the deepest shade.
    static let lapShades: [Color] = [
        Color(red: 0xE8 / 255, green: 0xA9 / 255, blue: 0x90 / 255),   // pale clay
        accent,                                                        // terracotta
        accentDeep,                                                    // Crail
        Color(red: 0x9E / 255, green: 0x4A / 255, blue: 0x2B / 255),   // fired umber
    ]
    static func lapShade(_ i: Int) -> Color {
        lapShades[min(max(i, 0), lapShades.count - 1)]
    }
}

// MARK: - Words

/// The four words the island says. Keyed off the DEVICE locale rather than the
/// app's `pervio.promptLanguage` switch, because the widget runs in its own
/// process and cannot read the app's UserDefaults without an App Group — and
/// because the one auto-refreshing string beside them (`Text(_, style:
/// .relative)`) is formatted by the system from that same locale, so following
/// anything else would print "3 min 前开始".
struct IslandStrings {
    /// Reads with the number in front: "3 分钟" + "前开始" / "3 min" + "ago".
    let relativeSuffix: String
    let done: String
    let stopped: String
    let noUpdate: String

    static let english = IslandStrings(relativeSuffix: "ago", done: "done",
                                       stopped: "stopped", noUpdate: "no update")
    static let chinese = IslandStrings(relativeSuffix: "前开始", done: "完成",
                                       stopped: "已停止", noUpdate: "无更新")

    static func forLocale(_ locale: Locale) -> IslandStrings {
        locale.language.languageCode?.identifier == "zh" ? .chinese : .english
    }
}

// MARK: - The mascot

/// The otter, riding `step`: it advances ONE walk-cycle frame on every action
/// (the island can't loop an animation — it only re-renders on data updates —
/// so we move the otter forward a frame each time Claude does something). A
/// clean finish rests the otter at frame 0; a failure slumps a DESATURATED
/// otter (it sat down where it stopped).
///
/// `bundle` is where the frames live: nil means `Bundle.main`, which is right in
/// the widget (its own bundle) and in the unit tests (the host app ships the
/// same frames). The design render harness runs inside a host-less xctest and
/// has to name its own bundle.
struct IslandOtter: View {
    var step: Int = 0
    var width: CGFloat = 26
    var finished: Bool = false
    var failed: Bool = false
    var bundle: Bundle? = nil

    var body: some View {
        Image("otter\(finished ? 0 : (((step % 8) + 8) % 8))", bundle: bundle)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: width, height: width * 156.0 / 300.0)   // the frames' native aspect
            .saturation(failed ? 0.25 : 1)
            .opacity(failed ? 0.85 : 1)
            .animation(.easeInOut(duration: 0.18), value: step)
    }
}

/// The otter on its cream card — the richer avatar for the lock screen and the
/// expanded leading region, matching the app's HomeGreetingHeader idiom.
struct IslandOtterTile: View {
    var step: Int = 0
    var size: CGFloat = 46
    var finished: Bool = false
    var failed: Bool = false
    var bundle: Bundle? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(IslandPalette.cream)
            .frame(width: size, height: size * 0.82)
            .overlay(IslandOtter(step: step, width: size * 0.82,
                                 finished: finished, failed: failed, bundle: bundle))
    }
}

// MARK: - The trail (the journey)

/// A horizontal path the otter walks. `total > 0` (a workflow) draws a literal
/// N-segment trail: the part BEHIND the otter is solid terracotta with a
/// paw-print at each traveled milestone, the part AHEAD is a faint dotted
/// hairline, and a green flag caps a clean finish. `total == 0` (an open-ended
/// run, unknown length) becomes an endless receding path — a short solid
/// lead-in, a few prints, then a faint dotted tail — honest that we don't know
/// how far but it's moving. A FAILURE paints the traveled part rust and drops a
/// cairn where the otter stopped.
///
/// `current` is the one cell the otter is INSIDE right now, drawn as a real
/// `ProgressView(timerInterval:)` that the system fills between updates. It is
/// the only thing on the card that moves while nothing is being pushed, so it
/// is what separates "working on something long" from "hung". It fills against
/// an ESTIMATE, not against progress: a step can finish while the bar is half
/// full (the trail simply jumps forward), and a step that overruns leaves the
/// bar sitting at the end. Full ≠ done — that is the price of motion.
struct IslandTrail: View {
    /// Snapshot seam, default off. ImageRenderer cannot drive
    /// `ProgressView(timerInterval:)` — it draws the system placeholder (the
    /// same yellow box the composer's TextField produced) instead of the tinted
    /// bar a real Live Activity shows. When set, the current cell is drawn as a
    /// plain bar filled to this fraction in the trail's own color. The app never
    /// sets it; only the snapshot suite does. Same pattern as
    /// HomeComposerRow.staticFieldForRender.
    var staticFillForRender: Double? = nil

    var done: Int
    var total: Int
    var finished: Bool = false
    var failed: Bool = false
    /// Absolute window for the filling cell; nil draws no cell at all.
    var current: ClosedRange<Date>? = nil

    private var solid: Color { failed ? IslandPalette.bad : IslandPalette.accent }
    private var showsCell: Bool { current != nil && !finished }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, y = h / 2
            if total > 0 {
                let n = max(total, 1)
                let seg = w / CGFloat(n)
                let travelled = CGFloat(min(max(done, 0), n))
                ZStack(alignment: .leading) {
                    // ahead: dotted hairline across the whole width
                    line(0, w, y).stroke(style: StrokeStyle(lineWidth: 2, dash: [2, 4]))
                        .foregroundStyle(.secondary.opacity(0.5))
                    // behind: solid, up to the otter
                    line(0, seg * travelled, y).stroke(solid, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    // milestone paw prints — the one under the filling cell steps aside
                    ForEach(0..<n, id: \.self) { i in
                        Image(systemName: "pawprint.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(CGFloat(i) < travelled ? solid : Color.secondary.opacity(0.6))
                            .opacity(showsCell && i == min(done, n - 1) && travelled < CGFloat(n) ? 0 : 1)
                            .position(x: seg * (CGFloat(i) + 0.5), y: y)
                    }
                    // the cell being walked right now, filling itself
                    if let window = current, !finished, travelled < CGFloat(n) {
                        fillingCell(window: window, width: max(seg - 3, 6))
                            .offset(x: seg * travelled + 1.5)
                    }
                    // end marker: a flag on a clean finish, a cairn on a failure
                    if finished && !failed {
                        Image(systemName: "flag.fill").font(.system(size: 11))
                            .foregroundStyle(IslandPalette.good).position(x: w - 4, y: y - 1)
                    } else if failed {
                        Image(systemName: "circle.grid.2x1.fill").font(.system(size: 9))
                            .foregroundStyle(IslandPalette.bad)
                            .position(x: min(seg * travelled + 8, w - 4), y: y)
                    }
                }
            } else {
                // open-ended: short solid lead-in + (the current stretch) + receding tail
                let cellStart = w * 0.36, cellWidth = w * 0.17
                let tailStart = showsCell ? cellStart + cellWidth + w * 0.03 : w * 0.40
                ZStack(alignment: .leading) {
                    line(0, w * 0.34, y).stroke(solid, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    ForEach(0..<3, id: \.self) { i in
                        Image(systemName: "pawprint.fill").font(.system(size: 8))
                            .foregroundStyle(solid)
                            .position(x: w * (0.08 + 0.11 * CGFloat(i)), y: y)
                    }
                    if let window = current, !finished {
                        fillingCell(window: window, width: cellWidth).offset(x: cellStart)
                    }
                    line(tailStart, w, y).stroke(style: StrokeStyle(lineWidth: 2, dash: [2, 5]))
                        .foregroundStyle(.secondary.opacity(0.45))
                    if finished && !failed {
                        Image(systemName: "flag.fill").font(.system(size: 11))
                            .foregroundStyle(IslandPalette.good).position(x: w - 4, y: y - 1)
                    } else if failed {
                        Image(systemName: "circle.grid.2x1.fill").font(.system(size: 9))
                            .foregroundStyle(IslandPalette.bad).position(x: w * 0.40, y: y)
                    }
                }
            }
        }
    }

    /// The system-filled bar for the current cell. `countsDown: false` fills
    /// left→right; both labels are emptied because the default one would print a
    /// countdown clock beside the bar — the very stopwatch this design removed.
    @ViewBuilder
    private func fillingCell(window: ClosedRange<Date>, width: CGFloat) -> some View {
        if let f = staticFillForRender {
            ZStack(alignment: .leading) {
                Capsule().fill(solid.opacity(0.25))
                Capsule().fill(solid).frame(width: width * f)
            }
            .frame(width: width, height: 4)
        } else {
            ProgressView(timerInterval: window, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(LinearProgressViewStyle(tint: solid))
            .labelsHidden()
            .frame(width: width)
        }
    }

    private func line(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) -> Path {
        Path { p in p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y)) }
    }
}

// MARK: - Small parts

/// The "what is it doing" line: glyph + one tool call ("Bash · npm test") or,
/// for a workflow, the step being walked.
struct IslandToolRow: View {
    var glyph: String
    var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: glyph)
                .font(.caption2).foregroundStyle(IslandPalette.accent).frame(width: 14)
            Text(text)
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// "3 分钟 前开始". TWO Texts on purpose: `Text(_, style: .relative)` is a live
/// element the system refreshes by itself, and concatenating it with the suffix
/// (`Text(…) + Text("前开始")`, or one interpolated string) collapses it into a
/// dead string that freezes at whatever it said when the card was last pushed.
///
/// When the run is over — or the card has gone stale because the Mac's ending
/// push never landed — there is nothing left to count, so it says so instead.
struct IslandRelativeTime: View {
    var start: Date
    var finished: Bool = false
    var failed: Bool = false
    var stale: Bool = false
    var strings: IslandStrings = .english

    var body: some View {
        if finished {
            Text(failed ? strings.stopped : strings.done)
                .font(.caption.weight(.medium))
                .foregroundStyle(failed ? IslandPalette.bad : .secondary)
        } else if stale {
            Text(strings.noUpdate).font(.caption2).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 3) {
                Text(start, style: .relative)          // the system refreshes this
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(strings.relativeSuffix)           // …and this stays put beside it
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// The compact trailing slot: a CLOCK, not a guess. The system sweeps the ring
/// over the current lap of a fixed dial (1 min, then 5, then 15, then 15 …—
/// `ContentState.ringLapSpans`), so within a lap the arc's position is exact
/// elapsed time on a known scale. Each lap hands the sweep a deeper terracotta
/// (`IslandPalette.lapShade`), so the COLOR says how long the run has been
/// running before the eye reads any geometry. Anchored at the RUN's start, so
/// the long later laps sweep live for minutes with no update from us (see
/// ContentState.ringLap). Under the sweep sits a static dial ring drawn as a
/// gradient from this lap's shade toward the next — the "it deepens from here"
/// hint; the lap itself can only advance when a content update (or a
/// SpringBoard re-render) lands, so a lap boundary crossed in silence parks
/// the ring full until the next update. Terminal states swap the ring for the
/// same marks the trail uses (flag / cairn), because a ring with nothing left
/// to sweep would just look broken.
///
/// `frozenFill` exists for STILL renders only (snapshot baselines, the design
/// PNGs): `.circular` is a live system element, and an ImageRenderer pass has no
/// clock to sweep it with. The widget never passes it.
struct IslandRing: View {
    var window: ClosedRange<Date>?
    /// Which lap of the dial the sweep is on (0-based) — picks the shade.
    var lap: Int = 0
    var finished: Bool = false
    var failed: Bool = false
    var stale: Bool = false
    var size: CGFloat = 20
    var frozenFill: CGFloat? = nil

    /// The static dial under the live sweep: this lap's shade fading in toward
    /// the NEXT lap's, clockwise from 12 o'clock — where the sweep is heading.
    private var dial: some View {
        Circle().stroke(
            AngularGradient(gradient: Gradient(colors: [
                IslandPalette.lapShade(lap).opacity(0.20),
                IslandPalette.lapShade(lap + 1).opacity(0.45),
            ]), center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
            lineWidth: 2.5)
    }

    var body: some View {
        if finished && !failed {
            Image(systemName: "flag.fill").font(.system(size: 13))
                .foregroundStyle(IslandPalette.good)
        } else if failed {
            Image(systemName: "circle.grid.2x1.fill").font(.system(size: 12))
                .foregroundStyle(IslandPalette.bad)
        } else if let fill = frozenFill {
            ZStack {
                dial
                Circle().trim(from: 0, to: fill)
                    .stroke(IslandPalette.lapShade(lap),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
        } else if let window, !stale {
            ZStack {
                dial
                ProgressView(timerInterval: window, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                // Same tint quirk as the linear cell: carry the color in the style.
                .progressViewStyle(CircularProgressViewStyle(tint: IslandPalette.lapShade(lap)))
            }
            .frame(width: size, height: size)
        } else {
            Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 2.5)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - The expanded island, region by region

/// Expanded LEADING: the otter's cream card + what is running.
struct IslandExpandedLeading: View {
    var title: String
    var subtitle: String
    var step: Int
    var finished: Bool
    var failed: Bool
    var bundle: Bundle? = nil

    var body: some View {
        HStack(spacing: 10) {
            IslandOtterTile(step: step, size: 46, finished: finished, failed: failed, bundle: bundle)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.bold()).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Expanded TRAILING: how long it has been going, in minutes, quietly.
struct IslandExpandedTrailing: View {
    var startedAt: Date
    var finished: Bool
    var failed: Bool
    var stale: Bool
    var strings: IslandStrings

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            IslandRelativeTime(start: startedAt, finished: finished, failed: failed,
                               stale: stale, strings: strings)
        }
    }
}

/// Expanded BOTTOM: the trail, then the one line that says what it's doing.
struct IslandExpandedBottom: View {
    var done: Int
    var total: Int
    var finished: Bool
    var failed: Bool
    var current: ClosedRange<Date>?
    var toolGlyph: String
    var toolLine: String
    var staticFillForRender: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IslandTrail(staticFillForRender: staticFillForRender,
                        done: done, total: total, finished: finished,
                        failed: failed, current: current)
                .frame(height: 16)
            if !toolLine.isEmpty && !finished {
                IslandToolRow(glyph: toolGlyph, text: toolLine)
            }
        }
    }
}

// MARK: - Whole-card composites (snapshots + design renders only)

/// The three expanded regions stacked the way the island stacks them. The system
/// owns the real region chrome, so this is the closest a still render can get —
/// the PIECES are the shipped ones, only the black capsule around them is drawn
/// here. Used by the snapshot baselines and by design/render.
struct IslandExpandedCard: View {
    var title: String
    var subtitle: String
    var step: Int
    var done: Int
    var total: Int
    var finished: Bool = false
    var failed: Bool = false
    var stale: Bool = false
    var startedAt: Date
    var current: ClosedRange<Date>? = nil
    var toolGlyph: String = ""
    var toolLine: String = ""
    var strings: IslandStrings = .english
    var width: CGFloat = 360
    var bundle: Bundle? = nil
    /// Snapshot seam — threaded down to the trail's filling cell (see
    /// IslandTrail.staticFillForRender). The app never sets it.
    var staticFillForRender: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                IslandExpandedLeading(title: title, subtitle: subtitle, step: step,
                                      finished: finished, failed: failed, bundle: bundle)
                IslandExpandedTrailing(startedAt: startedAt, finished: finished,
                                       failed: failed, stale: stale, strings: strings)
                    .fixedSize()
            }
            IslandExpandedBottom(done: done, total: total, finished: finished,
                                 failed: failed, current: current,
                                 toolGlyph: toolGlyph, toolLine: toolLine,
                                 staticFillForRender: staticFillForRender)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
        .frame(width: width, alignment: .leading)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 40))
        .environment(\.colorScheme, .dark)
    }
}

/// The compact presentation: otter left, self-sweeping ring right.
struct IslandCompactCard: View {
    var step: Int
    var finished: Bool = false
    var failed: Bool = false
    var stale: Bool = false
    var current: ClosedRange<Date>? = nil
    var frozenFill: CGFloat? = nil
    var bundle: Bundle? = nil

    var body: some View {
        HStack(spacing: 0) {
            IslandOtter(step: step, width: 30, finished: finished, failed: failed, bundle: bundle)
            Spacer(minLength: 22)
            IslandRing(window: current, finished: finished, failed: failed,
                       stale: stale, frozenFill: frozenFill)
        }
        .padding(.horizontal, 12)
        .frame(width: 214, height: 37)
        .background(Color.black, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}
