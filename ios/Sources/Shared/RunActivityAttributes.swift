import ActivityKit
import Foundation

/// Shared between the app and the widget extension (this single file is compiled
/// into BOTH targets — see project.yml). Describes the Live Activity that shows on
/// the Lock Screen and in the Dynamic Island while a detached "Run" is in progress.
///
/// Fixed attributes are set once when the run starts; ContentState is what we push
/// updates to as the run streams tool calls / finishes.
struct RunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Headline line, e.g. "Working…", "Running in background", "Done", "Stopped".
        var status: String
        /// Secondary line — the latest action, e.g. "Edit ChatView.swift".
        var detail: String
        /// Stops the pulsing animation and the live timer once the turn ends.
        var finished: Bool
        /// Increments on every action. The island can only animate on data updates
        /// (no continuous loops), so we use this to "take a step" each time Claude
        /// does something — the otter mascot advances one walk-cycle frame and the
        /// trail behind it fills. This is the ONLY motion the island affords beyond
        /// the system-ticked timer, so the whole design rides it.
        var step: Int = 0
        /// Milestones traveled on the trail. For a workflow this is real steps
        /// completed; for an open-ended run it stays 0 and the trail becomes an
        /// endless receding path (we don't know how far, but it's moving).
        var stepsDone: Int = 0
        /// Total milestones on the trail. 0 == unknown/open-ended (receding path);
        /// > 0 draws a literal N-segment trail with a finish flag at the end.
        var stepsTotal: Int = 0
        /// The terminal state was a FAILURE (stopped / errored), not a clean finish.
        /// Drives the otter's slumped/desaturated pose and the rust cairn on the
        /// trail, versus the green flag a successful `finished` earns. Only meaningful
        /// when `finished` is true.
        var failed: Bool = false

        // MARK: The tool row (what it is doing right now)

        /// SF Symbol for the bottom tool row's glyph, e.g. "terminal" for a Bash
        /// call. Empty == unspecified: the island derives one from `toolLine`'s
        /// first word (see `IslandGlyph.forLine`). Carried rather than derived so
        /// the SUPPLIER picks it — a workflow step is not a tool call and wants its
        /// own mark, which no string-sniffing on the view side could know.
        var toolIcon: String = ""
        /// The tool row's text, "Bash · npm test" / "Read · paper_07.pdf" — the one
        /// line that says what is happening inside the current step. Empty falls
        /// back to `detail` (which is what pre-tool-row payloads carry), so an old
        /// Mac's push still draws the row it used to draw.
        var toolLine: String = ""

        // MARK: The self-filling current cell (proof of life between updates)

        /// How long the CURRENT step is expected to take, in SECONDS. The island
        /// turns this into `ProgressView(timerInterval:)` — the system fills that
        /// bar on its own, with no push from us, which is the only way the card can
        /// show "still alive" while a single Bash call runs for ten minutes.
        ///
        /// 0 == no estimate; the island substitutes `defaultStepETA`. The estimate
        /// is TIME, not progress: a step that finishes early jumps the trail forward
        /// mid-fill, and a step that overruns leaves the bar sitting full. Full ≠
        /// done — that is the trade this design accepts to get motion at all.
        var stepETA: Int = 0
        /// When the current step started, as UNIX epoch SECONDS (not a `Date`: a
        /// Date in ContentState would drag in JSONDecoder's `.deferredToDate`
        /// reference-date trap, and every producer here — including a shell script
        /// on the Mac — already has epoch seconds in hand). Together with `stepETA`
        /// it fixes the filling cell's absolute window, so a re-render by
        /// SpringBoard resumes the fill instead of restarting it (which is exactly
        /// what a `Date()` read inside the view body would do).
        ///
        /// 0 == unknown → no filling cell (an honest blank rather than a bar that
        /// starts over every time the Lock Screen wakes).
        var stepStartedAt: Int = 0

        /// The fallback when `stepETA` is 0. 90 seconds is a deliberately dull
        /// middle: long enough that a normal tool call (seconds to half a minute)
        /// keeps the bar visibly creeping instead of slamming to full and looking
        /// stuck, short enough that a genuinely slow step still reaches the end of
        /// the cell inside the span a user is willing to stare at the island.
        static let defaultStepETA: TimeInterval = 90

        /// The current step's expected duration, with the fallback applied.
        var etaSeconds: TimeInterval {
            stepETA > 0 ? TimeInterval(stepETA) : Self.defaultStepETA
        }

        /// The absolute window the island hands to `ProgressView(timerInterval:)`,
        /// or nil when there is nothing to fill: the run ended, or we don't know
        /// when the current step began (an old payload).
        var currentStepWindow: ClosedRange<Date>? {
            guard !finished, stepStartedAt > 0 else { return nil }
            let start = Date(timeIntervalSince1970: TimeInterval(stepStartedAt))
            return start...start.addingTimeInterval(etaSeconds)
        }

        // MARK: The compact ring — a real clock, unlike the trail's guessed cell

        /// Lap spans for the compact ring, in seconds: the first sweep is a
        /// minute, the second five, the third fifteen, and every lap after
        /// repeats the deepest span. Escalating, because the ring is a CLOCK on
        /// a known dial (the accuracy the ETA-based cell can't offer): a short
        /// run gets visible motion inside its first minute, while one that runs
        /// half an hour doesn't spin thirty identical laps — it settles into
        /// slow, deep-colored sweeps that read as "long haul".
        static let ringLapSpans: [TimeInterval] = [60, 300, 900]

        /// Which lap of the dial the RUN is in at `now`, plus that lap's
        /// ABSOLUTE window for `ProgressView(timerInterval:)`. Within a lap the
        /// system's sweep is exact — the window's ends are fixed clock times,
        /// not estimates.
        ///
        /// Anchored at the run's `startedAt` ATTRIBUTE, deliberately not at
        /// `stepStartedAt`: the step clock resets on every content update, and
        /// updates STOP the moment iOS suspends the app (a locked phone is the
        /// island's whole audience) — anchored there, the short first lap
        /// swept full within a minute of the last update and then sat parked,
        /// which read as "the ring never moves" (shipped, observed, reverted).
        /// The run's start never moves, so by the time anyone looks mid-run
        /// the current lap is one of the LONG windows (5 then 15 minutes),
        /// which the system sweeps on its own with no update from us. The lap
        /// index (the ring's shade) still only advances when a re-render
        /// lands; a boundary crossed in silence parks the ring full until
        /// then — briefly, since late laps are long. nil once the run ended.
        static func ringLap(started: Date, finished: Bool,
                            at now: Date) -> (index: Int, window: ClosedRange<Date>)? {
            guard !finished else { return nil }
            let elapsed = max(0, now.timeIntervalSince(started))
            var lapStart: TimeInterval = 0
            var index = 0
            var span = ringLapSpans[0]
            while lapStart + span <= elapsed {
                lapStart += span
                index += 1
                span = ringLapSpans[min(index, ringLapSpans.count - 1)]
            }
            let s = started.addingTimeInterval(lapStart)
            return (index, s...s.addingTimeInterval(span))
        }

        // MARK: Decoding

        /// Hand-written so a push from an OLDER Mac still lands.
        ///
        /// Swift's SYNTHESIZED `Codable` ignores property defaults on decode: every
        /// stored property must be present in the JSON or the whole `content-state`
        /// throws — and ActivityKit swallows that failure silently, leaving the
        /// island exactly as stuck as the bug we shipped this to fix. The phone
        /// updates through TestFlight while `server/bin` updates through
        /// `install.sh`, so "new app, old pervio-push" is a normal Tuesday, not an
        /// edge case. The fields the old Mac knows stay REQUIRED (a genuinely
        /// malformed payload must still be rejected); everything added since is
        /// optional and degrades to "no tool row, default ETA, no filling cell".
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status     = try c.decode(String.self, forKey: .status)
            detail     = try c.decode(String.self, forKey: .detail)
            finished   = try c.decode(Bool.self,   forKey: .finished)
            step       = try c.decode(Int.self,    forKey: .step)
            stepsDone  = try c.decode(Int.self,    forKey: .stepsDone)
            stepsTotal = try c.decode(Int.self,    forKey: .stepsTotal)
            failed     = try c.decode(Bool.self,   forKey: .failed)
            toolIcon      = try c.decodeIfPresent(String.self, forKey: .toolIcon) ?? ""
            toolLine      = try c.decodeIfPresent(String.self, forKey: .toolLine) ?? ""
            stepETA       = try c.decodeIfPresent(Int.self,    forKey: .stepETA) ?? 0
            stepStartedAt = try c.decodeIfPresent(Int.self,    forKey: .stepStartedAt) ?? 0
        }

        /// The memberwise init the app builds states with — restated because
        /// writing `init(from:)` suppresses the synthesized one.
        init(status: String, detail: String, finished: Bool, step: Int = 0,
             stepsDone: Int = 0, stepsTotal: Int = 0, failed: Bool = false,
             toolIcon: String = "", toolLine: String = "",
             stepETA: Int = 0, stepStartedAt: Int = 0) {
            self.status = status
            self.detail = detail
            self.finished = finished
            self.step = step
            self.stepsDone = stepsDone
            self.stepsTotal = stepsTotal
            self.failed = failed
            self.toolIcon = toolIcon
            self.toolLine = toolLine
            self.stepETA = stepETA
            self.stepStartedAt = stepStartedAt
        }
    }

    /// Project directory name (row title).
    var project: String
    /// First line of the prompt (subtitle).
    var preview: String
    /// When the run started — drives the live elapsed timer in the island.
    var startedAt: Date
    /// The detached run this activity tracks, so a poller can end it once the run
    /// is no longer running (it may finish while the app is backgrounded, where no
    /// local code is left to end it — that's the "stuck island" bug).
    var runId: String = ""
}

// MARK: - Tool glyphs (shared by the supplier and the island's fallback)

/// Maps a tool call to the SF Symbol the island's bottom row shows. Lives in the
/// SHARED file because both sides need it and they are different modules: the app
/// stamps `toolIcon` into the ContentState it pushes, and the widget resolves a
/// glyph itself when a payload arrives without one.
enum IslandGlyph {
    /// The mark a workflow step gets — the same pawprint the trail drops at each
    /// milestone, because a workflow step IS a milestone (it has no tool name).
    static let step = "pawprint.fill"

    /// Glyph for a tool NAME ("Bash", "Edit", …).
    static func forTool(_ name: String) -> String {
        switch name {
        case "Read":                  return "doc.text"
        case "Edit", "NotebookEdit":  return "pencil"
        case "Write":                 return "square.and.pencil"
        case "Bash", "BashOutput":    return "terminal"
        case "Grep", "Glob":          return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task":                  return "sparkles"
        case "TodoWrite":             return "checklist"
        case "ExitPlanMode":          return "list.bullet.clipboard"
        default:                      return step
        }
    }

    /// Glyph for a whole ROW ("Bash · npm test", or the older two-space "Bash  npm
    /// test" that `detail` carries) — the fallback when a payload has no `toolIcon`.
    static func forLine(_ line: String) -> String {
        forTool(line.split(whereSeparator: { $0 == " " || $0 == "·" }).first.map(String.init) ?? "")
    }
}
