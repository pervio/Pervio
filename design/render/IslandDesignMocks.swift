import SwiftUI

// Standalone island / Live Activity design mockups for the mascot redesign.
// REAL SwiftUI, rendered to PNG via ImageRenderer (see DesignRenderTests). They
// are deliberately self-contained: brand hexes are restated here (this target
// links nothing from the app or the widget), and the otter frames come from the
// widget's own asset catalog (referenced in project.yml — never copied), so the
// mockups show the SHIPPING mascot and can never drift the drawing.
//
// WHY MOCKS, NOT the shipping RunLiveActivity: the real widget can only be shown
// by SpringBoard on a device — ImageRenderer cannot host an ActivityConfiguration.
// So we reproduce the exact island geometry (the black pill, the compact
// leading/trailing slots, the expanded regions) around the same views, and pin
// the copy the shipping widget uses. What renders here is what the island shows.
//
// HONESTY ABOUT MOTION. The island is a static snapshot; it re-renders only when
// data changes. It cannot run a frame loop. The only "animation" it gets is:
//   (1) Text(timerInterval:) — the system ticks the mm:ss for free;
//   (2) a content transition when a push/local update lands;
//   (3) ONE otter frame swap + ONE more trail segment filled per update.
// Every mock below lives inside that budget — nothing here needs a render loop.

// MARK: - Palette (mirror of the widget's perAccent + brand cream)

private enum IPalette {
    static let accent     = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255) // terracotta
    static let accentDeep = Color(red: 0xC1 / 255, green: 0x5F / 255, blue: 0x3C / 255) // Crail
    static let cream      = Color(red: 0xF9 / 255, green: 0xF4 / 255, blue: 0xF0 / 255) // card
    static let creamEdge  = Color(red: 0xE7 / 255, green: 0xDD / 255, blue: 0xD2 / 255) // cream hairline
    static let ink        = Color(red: 0x2A / 255, green: 0x24 / 255, blue: 0x1E / 255) // near-black on cream
    static let good       = Color(red: 0x5B / 255, green: 0x8C / 255, blue: 0x5A / 255) // muted forest (done)
    static let bad        = Color(red: 0xC4 / 255, green: 0x5A / 255, blue: 0x3A / 255) // rust (failed)
}

// MARK: - The mascot, drawn from the widget's real frames

/// Anchors `Bundle(for:)` to THIS test target, so the otter frames resolve from
/// the render bundle's compiled Assets.car (SwiftUI's `Image(_:)` defaults to
/// `Bundle.main`, which in a unit-test bundle is the test *runner*, not us — hence
/// the otter came up blank until this was made explicit).
private final class IslandBundleAnchor {}
private let islandBundle = Bundle(for: IslandBundleAnchor.self)

/// One otter frame (0…7) from the shared asset catalog. `renderingMode(.original)`
/// keeps the brown/cream drawing; the island rides `step % 8` to pick the frame,
/// so it "takes a step" on every action — the same trick the shipping widget uses.
private struct IOtter: View {
    var step: Int = 0
    var w: CGFloat = 34
    var body: some View {
        Image("otter\(((step % 8) + 8) % 8)", bundle: islandBundle)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: w, height: w * 156.0 / 300.0)   // the frames' native aspect
    }
}

/// A ticking mm:ss, standing in for the shipping `Text(timerInterval:)`. The real
/// island counts this for free; for a still PNG we freeze a representative value.
private struct IClock: View {
    var text: String = "12:34"
    var color: Color = IPalette.accent
    var big: Bool = false
    var body: some View {
        Text(text)
            .font((big ? Font.title3 : .caption).monospacedDigit().weight(.semibold))
            .foregroundStyle(color)
    }
}

// MARK: - Island chrome (so each mock reads as a real Dynamic Island)

/// The compact pill: a black stadium with a leading and a trailing slot, floated
/// on a phone-status-bar-ish strip, at the island's true corner radius.
private struct CompactIsland<L: View, T: View>: View {
    @ViewBuilder var leading: L
    @ViewBuilder var trailing: T
    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer(minLength: 22)                    // the camera/TrueDepth gap
            trailing
        }
        .padding(.horizontal, 12)
        .frame(width: 214, height: 37)               // ~true compact island size (pt)
        .background(Color.black, in: Capsule())
    }
}

/// The expanded island: a rounded-rect black card the width of the screen top,
/// with the four regions (leading / trailing / center / bottom) we actually use.
private struct ExpandedIsland<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
            .frame(width: 360, alignment: .leading)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 40))
    }
}

/// A titled swatch so each PNG is self-labelling (direction name + the two states).
private struct IslandBoard<Content: View>: View {
    let title: String
    let blurb: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(blurb).font(.caption).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(24)
        .frame(width: 440, alignment: .leading)
        .background(Color(red: 0x14/255, green: 0x13/255, blue: 0x11/255))
    }
}

private func stateTag(_ s: String) -> some View {
    Text(s).font(.caption2.weight(.semibold)).tracking(1)
        .foregroundStyle(.white.opacity(0.45))
}

// =====================================================================
// MARK: - Direction A — "呼吸" (breathing minimalist)
// =====================================================================
// Strip the island to the mascot and a quiet clock. No path, no gauge, no step
// number anywhere. Compact = otter + ticking mm:ss. Expanded = a big otter on a
// cream card, one action line, and the clock as a SUBTITLE (never the hero).
// The otter itself is the content; it swaps a frame each step, so a glance shows
// "still moving". Warmest, least chrome. Trade-off: on a long, quiet stretch
// there's no progress cue beyond the ticking clock and the changing pose.

struct IslandDirectionA: View {
    var body: some View {
        IslandBoard(title: "方向 A · 呼吸",
                    blurb: "只有水獭和一只安静的时钟。没有路、没有仪表、没有步数。水獭每推进一步换一帧,一眼看去「还在动」。最暖、最克制。") {
            VStack(alignment: .leading, spacing: 20) {
                // Compact
                VStack(alignment: .leading, spacing: 8) {
                    stateTag("COMPACT · 进行中")
                    CompactIsland {
                        IOtter(step: 4, w: 30)
                    } trailing: {
                        IClock(text: "12:34")
                    }
                }
                // Expanded
                VStack(alignment: .leading, spacing: 8) {
                    stateTag("EXPANDED · 进行中")
                    ExpandedIsland {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(IPalette.cream)
                                .frame(width: 74, height: 60)
                                .overlay(IOtter(step: 4, w: 58))
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Pervio").font(.subheadline.bold()).foregroundStyle(.white)
                                Text("Edit ChatView.swift")
                                    .font(.caption.monospaced()).foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                IClock(text: "跑了 12:34", color: IPalette.accent)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                // Terminal states
                VStack(alignment: .leading, spacing: 8) {
                    stateTag("终态 · 完成 / 失败")
                    HStack(spacing: 12) {
                        CompactIsland {
                            IOtter(step: 0, w: 30)
                        } trailing: {
                            Image(systemName: "checkmark").font(.caption.bold())
                                .foregroundStyle(IPalette.good)
                        }
                        CompactIsland {
                            IOtter(step: 2, w: 30).saturation(0.25).opacity(0.85)
                        } trailing: {
                            Image(systemName: "xmark").font(.caption.bold())
                                .foregroundStyle(IPalette.bad)
                        }
                    }
                }
            }
        }
    }
}

// =====================================================================
// MARK: - Direction B — "小径" (the trail — progress narrative) — RECOMMENDED
// =====================================================================
// The otter walks a PATH. Expanded gets a horizontal trail with paw-print
// milestones: the segment BEHIND the otter is solid terracotta (traveled), the
// segment AHEAD is a faint dotted hairline (to go). Every step advances the otter
// one notch AND fills one more segment — the walk and the progress are ONE
// gesture (exactly "事情往前一步,它就跑一步,走过的路实心"). Workflows have real
// N/M steps → the trail is literal. Open-ended chat runs (unknown total) get an
// endless receding path (otter ~1/3 in, faint ellipsis ahead) — honest about
// "don't know how far, but moving". Done = otter reaches a little flag; failed =
// otter sits by a rust cairn where the trail stops.

struct IslandDirectionB: View {
    var body: some View {
        IslandBoard(title: "方向 B · 小径(推荐)",
                    blurb: "水獭走在一条小径上:身后走过的路实心(赤陶土),身前未走的路是虚线。每推进一步,水獭前进一格、实心多一段——走路和进度是同一个动作。完成=走到小旗;失败=停在锈色石堆旁。") {
            VStack(alignment: .leading, spacing: 20) {
                // Compact (same slim footprint as A; the trail is an expanded-only story)
                VStack(alignment: .leading, spacing: 8) {
                    stateTag("COMPACT · 进行中")
                    CompactIsland {
                        IOtter(step: 3, w: 30)
                    } trailing: {
                        IClock(text: "12:34")
                    }
                }
                // Expanded — workflow (known steps: 3/6 done)
                VStack(alignment: .leading, spacing: 8) {
                    stateTag("EXPANDED · 工作流 3/6")
                    ExpandedIsland {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(IPalette.cream)
                                    .frame(width: 58, height: 46)
                                    .overlay(IOtter(step: 3, w: 46))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("组会周报").font(.subheadline.bold()).foregroundStyle(.white)
                                    Text("打分 12 篇候选")
                                        .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 2) {
                                    IClock(text: "12:34")
                                    Text("3/6").font(.caption2).foregroundStyle(.white.opacity(0.5))
                                }
                            }
                            TrailBar(total: 6, done: 3)
                        }
                    }
                }
                // Expanded — open run (unknown total: receding path)
                VStack(alignment: .leading, spacing: 8) {
                    stateTag("EXPANDED · 开放式运行(未知总量)")
                    ExpandedIsland {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(IPalette.cream)
                                    .frame(width: 58, height: 46)
                                    .overlay(IOtter(step: 5, w: 46))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Pervio").font(.subheadline.bold()).foregroundStyle(.white)
                                    Text("Bash npm test")
                                        .font(.caption.monospaced()).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                IClock(text: "12:34")
                            }
                            TrailBar(total: nil, done: 5)     // endless receding path
                        }
                    }
                }
                // Terminal — done (flag) + failed (cairn)
                VStack(alignment: .leading, spacing: 8) {
                    stateTag("终态 · 完成(小旗)/ 失败(石堆)")
                    ExpandedIsland {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 14).fill(IPalette.cream)
                                    .frame(width: 58, height: 46).overlay(IOtter(step: 0, w: 46))
                                Text("Done").font(.subheadline.bold()).foregroundStyle(IPalette.good)
                                Spacer()
                                Text("12:34").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                            }
                            TrailBar(total: 6, done: 6, terminal: .done)
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 14).fill(IPalette.cream)
                                    .frame(width: 58, height: 46)
                                    .overlay(IOtter(step: 2, w: 46).saturation(0.25).opacity(0.85))
                                Text("Failed").font(.subheadline.bold()).foregroundStyle(IPalette.bad)
                                Spacer()
                                Text("exit 5").font(.caption.monospaced()).foregroundStyle(.white.opacity(0.6))
                            }
                            TrailBar(total: 6, done: 3, terminal: .failed)
                        }
                    }
                }
            }
        }
    }
}

/// The trail: `total` segments, `done` of them solid terracotta with a paw-print
/// at each traveled node; the rest a faint dotted hairline. `total == nil` is the
/// open-ended run — a short solid lead-in, the otter, then a faint receding
/// ellipsis. Terminal states cap the end with a flag (done) or a rust cairn
/// (failed). This is a PURE snapshot: "fill segments 0..<done" — no animation.
private enum TrailTerminal { case none, done, failed }
private struct TrailBar: View {
    let total: Int?
    let done: Int
    var terminal: TrailTerminal = .none

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let y = geo.size.height / 2
            if let total, total > 0 {
                let seg = w / CGFloat(total)
                ZStack(alignment: .leading) {
                    // to-go: dotted hairline across the whole width
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [2, 4]))
                        .foregroundStyle(.white.opacity(0.22))
                    // traveled: solid terracotta up to `done`
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: seg * CGFloat(min(done, total)), y: y)) }
                        .stroke(terminal == .failed ? IPalette.bad : IPalette.accent,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    // milestone paw prints
                    ForEach(0..<total, id: \.self) { i in
                        let x = seg * (CGFloat(i) + 0.5)
                        Image(systemName: "pawprint.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(i < done ? (terminal == .failed ? IPalette.bad : IPalette.accent)
                                                       : .white.opacity(0.3))
                            .position(x: x, y: y)
                    }
                    // end marker
                    if terminal == .done {
                        Image(systemName: "flag.fill").font(.system(size: 11))
                            .foregroundStyle(IPalette.good).position(x: w - 4, y: y - 1)
                    } else if terminal == .failed {
                        // a small "cairn": three stacked dots where the trail stops
                        Image(systemName: "circle.grid.2x1.fill").font(.system(size: 9))
                            .foregroundStyle(IPalette.bad)
                            .position(x: seg * CGFloat(min(done, total)) + 8, y: y)
                    }
                }
            } else {
                // open-ended: short solid lead-in + receding faint ellipsis
                ZStack(alignment: .leading) {
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w * 0.34, y: y)) }
                        .stroke(IPalette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    ForEach(0..<3, id: \.self) { i in
                        Image(systemName: "pawprint.fill").font(.system(size: 8))
                            .foregroundStyle(IPalette.accent)
                            .position(x: w * (0.08 + 0.11 * CGFloat(i)), y: y)
                    }
                    Path { p in p.move(to: CGPoint(x: w * 0.40, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [2, 5]))
                        .foregroundStyle(.white.opacity(0.20))
                }
            }
        }
        .frame(height: 16)
    }
}

// =====================================================================
// MARK: - Direction C — "仪表" (data instrument / mixed)
// =====================================================================
// The otter shares the stage with a compact instrument cluster. Expanded = otter
// on the left; on the right a mini dashboard: the elapsed clock large-mono, a
// step counter as a SMALL chip (deliberately not the hero), and the current tool
// with its glyph. Keeps the number but frames it as one instrument among several.
// The most "pro/utilitarian" read — included as the honest foil to A/B, since it
// is the closest to the "just a number" look the brief pushes away from.

struct IslandDirectionC: View {
    var body: some View {
        IslandBoard(title: "方向 C · 仪表",
                    blurb: "水獭与一个小型数据面板同台:大号计时、步数做成小胶囊(刻意不当主角)、当前工具带图标。保留数字,但把它放进一组仪表里。最偏「工具感」,作为 A/B 的对照。") {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    stateTag("COMPACT · 进行中")
                    CompactIsland {
                        IOtter(step: 6, w: 30)
                    } trailing: {
                        IClock(text: "12:34")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    stateTag("EXPANDED · 进行中")
                    ExpandedIsland {
                        HStack(alignment: .center, spacing: 14) {
                            RoundedRectangle(cornerRadius: 14).fill(IPalette.cream)
                                .frame(width: 64, height: 52).overlay(IOtter(step: 6, w: 50))
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 8) {
                                    IClock(text: "12:34", big: true)
                                    Text("步 24").font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(IPalette.accentDeep, in: Capsule())
                                }
                                HStack(spacing: 7) {
                                    Image(systemName: "terminal").font(.caption2).foregroundStyle(IPalette.accent)
                                    Text("Bash npm test").font(.caption.monospaced())
                                        .foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    stateTag("终态 · 完成 / 失败")
                    HStack(spacing: 12) {
                        CompactIsland {
                            IOtter(step: 0, w: 30)
                        } trailing: {
                            Text("done").font(.caption2.weight(.semibold)).foregroundStyle(IPalette.good)
                        }
                        CompactIsland {
                            IOtter(step: 2, w: 30).saturation(0.25)
                        } trailing: {
                            Text("exit 5").font(.caption2.weight(.semibold).monospaced()).foregroundStyle(IPalette.bad)
                        }
                    }
                }
            }
        }
    }
}

// =====================================================================
// MARK: - SHIPPED — the implemented island (mirror of PervioLiveActivity)
// =====================================================================
// A faithful mirror of what the widget actually renders (ImageRenderer can't host
// an ActivityConfiguration, so we rebuild the exact geometry). This is the "final"
// preview PNG: compact + minimal + expanded (open run + workflow) + both terminal
// states, the recommended Direction B (小径) as it ships.

struct IslandShipped: View {
    var body: some View {
        IslandBoard(title: "最终实现 · 小径(方向 B)",
                    blurb: "落地形态:compact 只留水獭 + 系统计时;expanded 底部是小径——身后实心、身前虚线、赤陶土爪印里程碑;工作流用真实 N/M,开放式运行用无尽后退的路;完成插小旗,失败落锈色石堆。") {
            VStack(alignment: .leading, spacing: 18) {
                // Compact + minimal
                VStack(alignment: .leading, spacing: 8) {
                    stateTag("COMPACT · MINIMAL")
                    HStack(spacing: 12) {
                        CompactIsland { IOtter(step: 3, w: 30) } trailing: { IClock(text: "12:34") }
                        // minimal is a lone pill with just the otter
                        HStack { IOtter(step: 3, w: 24) }
                            .padding(.horizontal, 10).frame(height: 37)
                            .background(Color.black, in: Capsule())
                    }
                }
                // Expanded — open-ended run
                VStack(alignment: .leading, spacing: 8) {
                    stateTag("EXPANDED · 开放式运行")
                    ExpandedIsland {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 13).fill(IPalette.cream)
                                    .frame(width: 56, height: 46).overlay(IOtter(step: 5, w: 46))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Pervio").font(.subheadline.bold()).foregroundStyle(.white)
                                    Text("Working…").font(.caption2).foregroundStyle(.white.opacity(0.6))
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 1) {
                                    IClock(text: "12:34", big: true)
                                    Text("elapsed").font(.caption2).foregroundStyle(.white.opacity(0.5))
                                }
                            }
                            ShippedTrail(done: 0, total: 0, finished: false, failed: false).frame(height: 16)
                            HStack(spacing: 7) {
                                Image(systemName: "terminal").font(.caption2).foregroundStyle(IPalette.accent).frame(width: 14)
                                Text("Bash npm test").font(.caption.monospaced()).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                // Expanded — workflow 3/6
                VStack(alignment: .leading, spacing: 8) {
                    stateTag("EXPANDED · 工作流 3/6")
                    ExpandedIsland {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 13).fill(IPalette.cream)
                                    .frame(width: 56, height: 46).overlay(IOtter(step: 3, w: 46))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("组会周报").font(.subheadline.bold()).foregroundStyle(.white)
                                    Text("3/6 steps done").font(.caption2).foregroundStyle(.white.opacity(0.6))
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 1) {
                                    IClock(text: "12:34", big: true)
                                    Text("3/6").font(.caption2).foregroundStyle(.white.opacity(0.5))
                                }
                            }
                            ShippedTrail(done: 3, total: 6, finished: false, failed: false).frame(height: 16)
                        }
                    }
                }
                // Terminal — done + failed
                VStack(alignment: .leading, spacing: 8) {
                    stateTag("终态 · 完成 / 失败")
                    ExpandedIsland {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 13).fill(IPalette.cream)
                                    .frame(width: 56, height: 46).overlay(IOtter(step: 0, w: 46))
                                Text("Done").font(.subheadline.bold()).foregroundStyle(.white)
                                Spacer(); Text("done").font(.caption2).foregroundStyle(IPalette.good)
                            }
                            ShippedTrail(done: 6, total: 6, finished: true, failed: false).frame(height: 16)
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 13).fill(IPalette.cream)
                                    .frame(width: 56, height: 46)
                                    .overlay(IOtter(step: 0, w: 46).saturation(0.25).opacity(0.85))
                                Text("Ended").font(.subheadline.bold()).foregroundStyle(.white)
                                Spacer(); Text("stopped").font(.caption2).foregroundStyle(IPalette.bad)
                            }
                            ShippedTrail(done: 3, total: 6, finished: true, failed: true).frame(height: 16)
                        }
                    }
                }
            }
        }
    }
}

/// The shipped Trail, restated here (the mocks target links nothing from the
/// widget). Byte-for-byte the same logic as PervioLiveActivity.Trail — kept in
/// sync by eye; this render is only a preview, the widget is the source of truth.
private struct ShippedTrail: View {
    let done: Int, total: Int, finished: Bool, failed: Bool
    private var solid: Color { failed ? IPalette.bad : IPalette.accent }
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, y = geo.size.height / 2
            if total > 0 {
                let n = max(total, 1); let seg = w / CGFloat(n)
                let travelled = CGFloat(min(max(done, 0), n))
                ZStack(alignment: .leading) {
                    line(0, w, y).stroke(style: StrokeStyle(lineWidth: 2, dash: [2, 4])).foregroundStyle(.white.opacity(0.3))
                    line(0, seg * travelled, y).stroke(solid, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    ForEach(0..<n, id: \.self) { i in
                        Image(systemName: "pawprint.fill").font(.system(size: 8))
                            .foregroundStyle(CGFloat(i) < travelled ? solid : Color.white.opacity(0.35))
                            .position(x: seg * (CGFloat(i) + 0.5), y: y)
                    }
                    if finished && !failed {
                        Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(IPalette.good).position(x: w - 4, y: y - 1)
                    } else if failed {
                        Image(systemName: "circle.grid.2x1.fill").font(.system(size: 9)).foregroundStyle(IPalette.bad)
                            .position(x: min(seg * travelled + 8, w - 4), y: y)
                    }
                }
            } else {
                ZStack(alignment: .leading) {
                    line(0, w * 0.34, y).stroke(solid, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    ForEach(0..<3, id: \.self) { i in
                        Image(systemName: "pawprint.fill").font(.system(size: 8)).foregroundStyle(solid)
                            .position(x: w * (0.08 + 0.11 * CGFloat(i)), y: y)
                    }
                    line(w * 0.40, w, y).stroke(style: StrokeStyle(lineWidth: 2, dash: [2, 5])).foregroundStyle(.white.opacity(0.28))
                }
            }
        }
    }
    private func line(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) -> Path {
        Path { p in p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y)) }
    }
}
