import SwiftUI

// =====================================================================
// ISLAND MOTION SAMPLES — "时钟之外的活法"
// =====================================================================
// Five variants of the SHIPPED trail island (方向 B), each answering one
// question: if the mm:ss clock goes away, what is left that MOVES?
//
// Same rules as IslandDesignMocks.swift: real SwiftUI rendered to PNG by
// ImageRenderer (see DesignRenderTests), the REAL otter frames from the
// widget's own asset catalog, the brand hexes restated (this target links
// nothing from the app or the widget). Nothing here touches ios/LiveActivity —
// these are proposals, not code.
//
// THE MOTION BUDGET (why the samples look the way they do). A Live Activity is
// a STATIC SNAPSHOT: SpringBoard re-renders it only when new ContentState
// lands. It cannot run a frame loop — no breathing, no blinking, no looping
// walk cycle, ever. Exactly three things move without an update:
//   1. Text(timerInterval:)          — the system ticks mm:ss for free
//   2. ProgressView(timerInterval:)  — the system FILLS a bar/ring for free
//   3. Text(date, style: .relative)  — the system refreshes "3 分钟" for free
// and one thing moves AT the moment of an update:
//   4. contentTransition(.numericText()) — digits roll once, ~0.3s, then stop
// Everything below is built out of those four and nothing else. Every element
// that moves is labelled with WHICH of them it is.

// MARK: - Palette (mirror of the widget's perAccent + brand cream)

private enum SPalette {
    static let accent     = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255) // terracotta
    static let accentDeep = Color(red: 0xC1 / 255, green: 0x5F / 255, blue: 0x3C / 255) // Crail
    static let cream      = Color(red: 0xF9 / 255, green: 0xF4 / 255, blue: 0xF0 / 255) // card
    static let good       = Color(red: 0x5B / 255, green: 0x8C / 255, blue: 0x5A / 255) // muted forest (done)
    static let bad        = Color(red: 0xC4 / 255, green: 0x5A / 255, blue: 0x3A / 255) // rust (failed)
}

// MARK: - The mascot, from the widget's real frames

/// Anchors `Bundle(for:)` to THIS render bundle so the otter art resolves from
/// the compiled Assets.car (SwiftUI's `Image(_:)` would otherwise look in
/// `Bundle.main` — the test runner — and come up blank).
private final class SampleBundleAnchor {}
private let sampleBundle = Bundle(for: SampleBundleAnchor.self)

private struct SOtter: View {
    var step: Int = 0
    var w: CGFloat = 46
    var body: some View {
        Image("otter\(((step % 8) + 8) % 8)", bundle: sampleBundle)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: w, height: w * 156.0 / 300.0)
    }
}

/// The otter on its cream card (expanded leading region).
private struct SOtterTile: View {
    var step: Int = 0
    var size: CGFloat = 56
    var dim: Bool = false
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(SPalette.cream)
            .frame(width: size, height: size * 0.82)
            .overlay(SOtter(step: step, w: size * 0.82).saturation(dim ? 0.25 : 1))
    }
}

// MARK: - Island chrome

private struct SCompact<L: View, T: View>: View {
    @ViewBuilder var leading: L
    @ViewBuilder var trailing: T
    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer(minLength: 22)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(width: 214, height: 37)
        .background(Color.black, in: Capsule())
    }
}

private struct SExpanded<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
            .frame(width: 360, alignment: .leading)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 40))
    }
}

private func sTag(_ s: String) -> some View {
    Text(s).font(.caption2.weight(.semibold)).tracking(1)
        .foregroundStyle(.white.opacity(0.45))
}

// MARK: - The motion annotation (what moves, and by which primitive)

private enum SMotion {
    case auto       // the system animates it with no update from us
    case onUpdate   // it changes only when a new ContentState lands
    case still      // it never moves

    var label: String {
        switch self {
        case .auto:     return "自动"
        case .onUpdate: return "更新时"
        case .still:    return "静止"
        }
    }
    var tint: Color {
        switch self {
        case .auto:     return SPalette.accent
        case .onUpdate: return Color(red: 0.55, green: 0.60, blue: 0.66)
        case .still:    return Color(white: 0.42)
        }
    }
}

/// One annotation line: a colour-coded badge (自动 / 更新时 / 静止) and the
/// mechanism in plain words. Every moving element in every sample gets one.
private struct SNote: View {
    let kind: SMotion
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(kind.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(kind == .auto ? Color.black : Color.white.opacity(0.9))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(kind.tint.opacity(kind == .auto ? 1 : 0.35), in: Capsule())
                .frame(width: 46, alignment: .leading)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// A titled board: heading, one-line premise, the mock states, and a closing
/// 取舍 (trade-off) sentence — so each PNG argues its own case standalone.
private struct SampleBoard<Content: View>: View {
    let title: String
    let blurb: String
    let tradeoff: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(blurb).font(.caption).foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            VStack(alignment: .leading, spacing: 7) {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                HStack(alignment: .top, spacing: 8) {
                    Text("取舍")
                        .font(.system(size: 10, weight: .semibold)).tracking(1)
                        .foregroundStyle(SPalette.accent)
                        .frame(width: 46, alignment: .leading)
                    Text(tradeoff)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(24)
        .frame(width: 452, alignment: .leading)
        .background(Color(red: 0x14 / 255, green: 0x13 / 255, blue: 0x11 / 255))
    }
}

// MARK: - Trails

/// The workflow trail (N segments), optionally with the CURRENT cell drawn as a
/// self-filling bar — that bar is a real `ProgressView(timerInterval:)`, which
/// the system fills on its own between updates. `currentFill` is the frozen
/// value this still shows; on device it slides from 0 to 1 by itself.
private struct SegTrail: View {
    let total: Int
    let done: Int
    var currentFill: CGFloat? = nil
    var finished: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let y = geo.size.height / 2
            let n = max(total, 1)
            let seg = w / CGFloat(n)
            ZStack(alignment: .leading) {
                dashed(0, w, y)
                solid(0, seg * CGFloat(min(done, n)), y)
                paws(n: n, seg: seg, y: y)
                if let f = currentFill, done < n {
                    fillingCell(seg: seg, f: f)
                }
                if finished {
                    Image(systemName: "flag.fill").font(.system(size: 11))
                        .foregroundStyle(SPalette.good).position(x: w - 4, y: y - 1)
                }
            }
        }
        .frame(height: 16)
    }

    private func paws(n: Int, seg: CGFloat, y: CGFloat) -> some View {
        ForEach(0..<n, id: \.self) { i in
            let isCurrent = (currentFill != nil && i == done)
            Image(systemName: "pawprint.fill")
                .font(.system(size: 8))
                .foregroundStyle(i < done ? SPalette.accent : Color.white.opacity(0.32))
                .opacity(isCurrent ? 0 : 1)          // the filling bar takes this cell
                .position(x: seg * (CGFloat(i) + 0.5), y: y)
        }
    }

    /// The one cell the otter is inside right now: a track + a fill that the
    /// system drives. Drawn taller than the trail so it reads as "this is the
    /// bit that is moving".
    private func fillingCell(seg: CGFloat, f: CGFloat) -> some View {
        let cw = max(seg - 3, 6)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(SPalette.accent.opacity(0.22))
            .frame(width: cw, height: 8)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(SPalette.accent)
                    .frame(width: max(cw * f, 4), height: 8)
            }
            .offset(x: seg * CGFloat(done) + 1.5)
    }

    private func dashed(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) -> some View {
        line(x0, x1, y).stroke(style: StrokeStyle(lineWidth: 2, dash: [2, 4]))
            .foregroundStyle(.white.opacity(0.24))
    }
    private func solid(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) -> some View {
        line(x0, x1, y).stroke(SPalette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }
    private func line(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) -> Path {
        Path { p in p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y)) }
    }
}

/// The open-ended run (unknown total): a solid lead-in with a few prints, then —
/// if `currentFill` is set — the stretch the otter is on right now as a
/// self-filling bar, then the faint receding tail.
private struct OpenTrail: View {
    var currentFill: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let y = geo.size.height / 2
            ZStack(alignment: .leading) {
                line(0, w * 0.30, y).stroke(SPalette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: "pawprint.fill").font(.system(size: 8))
                        .foregroundStyle(SPalette.accent)
                        .position(x: w * (0.07 + 0.10 * CGFloat(i)), y: y)
                }
                if let f = currentFill {
                    let cw = w * 0.17
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(SPalette.accent.opacity(0.22))
                        .frame(width: cw, height: 8)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(SPalette.accent).frame(width: max(cw * f, 4), height: 8)
                        }
                        .offset(x: w * 0.32)
                }
                line(w * (currentFill == nil ? 0.36 : 0.52), w, y)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [2, 5]))
                    .foregroundStyle(.white.opacity(0.22))
            }
        }
        .frame(height: 16)
    }

    private func line(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) -> Path {
        Path { p in p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y)) }
    }
}

// MARK: - Small parts

/// A quiet relative time. On device this is TWO views: `Text(startedAt, style:
/// .relative)` (which the system refreshes by itself) plus a plain label beside
/// it — concatenating them into one Text would lose the auto-refresh.
private struct SRelative: View {
    var value: String = "3 分钟"
    var suffix: String = "前开始"
    var body: some View {
        HStack(spacing: 3) {
            Text(value).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.62))
            Text(suffix).font(.caption2).foregroundStyle(.white.opacity(0.42))
        }
    }
}

/// A small ring for the compact slot — `ProgressView(timerInterval:)` in the
/// circular style, which the system sweeps on its own.
private struct SRing: View {
    var fill: CGFloat = 0.55
    var size: CGFloat = 19
    var body: some View {
        ZStack {
            Circle().stroke(SPalette.accent.opacity(0.28), lineWidth: 2.5)
            Circle().trim(from: 0, to: fill)
                .stroke(SPalette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// The "what is it doing" line: glyph + tool call.
private struct SToolRow: View {
    let glyph: String
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: glyph).font(.caption2).foregroundStyle(SPalette.accent).frame(width: 14)
            Text(text).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.78)).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// The step counter as a supporting actor, with the numericText roll implied.
private struct SSteps: View {
    let done: Int
    let total: Int
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(done)").font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(SPalette.accent)
            Text("/\(total)").font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

/// A caption over a demo strip that is NOT part of the island — a time-lapse or
/// a frame-by-frame, so a still PNG can show something that moves.
private struct SStripLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.white.opacity(0.40))
    }
}

// =====================================================================
// MARK: - 样例 1 · 迈步中(当前格自己填)
// =====================================================================

struct IslandSampleStride: View {
    var body: some View {
        SampleBoard(
            title: "样例 1 · 迈步中(当前格自己填)",
            blurb: "小径不变,但水獭正在迈的那一格是一条会自己填色的进度条 —— 不用推送,系统按这一步的预估时长把它从左填到右。右上角不放秒表,只有一句安静的相对时间。",
            tradeoff: "唯一「一直在动」的方案,代价是它按预估时间填、不按真实进度:一步超时就会先填满再干等,填满 ≠ 做完。"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    sTag("EXPANDED · 工作流 4/6,第 5 格正在填")
                    SExpanded {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                SOtterTile(step: 4)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("组会周报").font(.subheadline.bold()).foregroundStyle(.white)
                                    Text("打分 12 篇候选").font(.caption2).foregroundStyle(.white.opacity(0.6))
                                }
                                Spacer(minLength: 0)
                                SRelative()
                            }
                            SegTrail(total: 6, done: 4, currentFill: 0.5)
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        SNote(kind: .auto, text: "当前格 = ProgressView(timerInterval: 这一步的预估区间),系统自己从左往右填,App 一次都不用推")
                        SNote(kind: .auto, text: "右上角 = Text(startedAt, style: .relative),系统自动刷新,但只按分钟粗颗粒变 —— 不像秒表那样每秒跳")
                        SNote(kind: .onUpdate, text: "走满一格 → 实心多一段、水獭换一帧、下一格从头开始填(一次 ContentState 更新做完三件事)")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SStripLabel(text: "同一格,时间推移(不需要任何推送 —— 系统自己走完这三帧)")
                    HStack(spacing: 10) {
                        strip("刚踏进这一格", 0.06)
                        strip("半分钟后", 0.52)
                        strip("快满了", 0.94)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    sTag("COMPACT")
                    SCompact {
                        SOtter(step: 4, w: 30)
                    } trailing: {
                        Text("3 分钟").font(.caption2).foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        }
    }

    private func strip(_ label: String, _ f: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SegTrail(total: 6, done: 4, currentFill: f)
                .frame(width: 104)
                .padding(.horizontal, 7).padding(.vertical, 6)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
            SStripLabel(text: label)
        }
    }
}

// =====================================================================
// MARK: - 样例 2 · 讲故事(底部一行「正在干什么」)
// =====================================================================

struct IslandSampleTool: View {
    var body: some View {
        SampleBoard(
            title: "样例 2 · 讲故事(底部一行「正在干什么」)",
            blurb: "小径照旧,底部换成工具图标 +「Bash · npm test」;右上角一个时间元素都没有。会动的是内容本身 —— Claude 每换一次工具,这行就换一次字。",
            tradeoff: "最像「它在跟你讲它在干嘛」,但没有任何时间锚点;而且一条命令跑三分钟不换工具时,整个岛完全静止 —— 分不清在跑还是卡住。"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    sTag("EXPANDED · 这一刻")
                    SExpanded {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 10) {
                                SOtterTile(step: 2)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Pervio").font(.subheadline.bold()).foregroundStyle(.white)
                                    Text("跑测试").font(.caption2).foregroundStyle(.white.opacity(0.6))
                                }
                                Spacer(minLength: 0)
                            }
                            SegTrail(total: 6, done: 2)
                            SToolRow(glyph: "terminal", text: "Bash · npm test")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    sTag("EXPANDED · 下一次工具调用之后")
                    SExpanded {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 10) {
                                SOtterTile(step: 3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Pervio").font(.subheadline.bold()).foregroundStyle(.white)
                                    Text("改代码").font(.caption2).foregroundStyle(.white.opacity(0.6))
                                }
                                Spacer(minLength: 0)
                            }
                            SegTrail(total: 6, done: 3)
                            SToolRow(glyph: "pencil", text: "Edit · ChatView.swift")
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        SNote(kind: .onUpdate, text: "工具行随每次工具调用重绘:字本身不会动,是「换了一行字」—— 图标也跟着换(terminal / pencil / magnifyingglass …)")
                        SNote(kind: .onUpdate, text: "同一次更新里,小径多实心一段、水獭换一帧")
                        SNote(kind: .still, text: "画面里没有任何自动刷新的元素:两次工具调用之间,岛是一张冻住的图")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    sTag("COMPACT · 尾槽只放工具图标,没有时间")
                    SCompact {
                        SOtter(step: 2, w: 30)
                    } trailing: {
                        Image(systemName: "terminal").font(.caption).foregroundStyle(SPalette.accent)
                    }
                }
            }
        }
    }
}

// =====================================================================
// MARK: - 样例 3 · 翻牌数字(数字当配角)
// =====================================================================

struct IslandSampleRoll: View {
    var body: some View {
        SampleBoard(
            title: "样例 3 · 翻牌数字(数字当配角)",
            blurb: "时钟去掉,右上角换成步数;更新落地那一刻,数字用 contentTransition(.numericText()) 像翻牌一样滚一下。小径仍是主角,数字只是配角。",
            tradeoff: "滚动只闪一下(约 0.3 秒)就归于静止,平时和一张死图没区别;而且它把眼睛又拉回「数字」—— 正是你嫌普通的那种读法。"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    sTag("EXPANDED · 更新前")
                    SExpanded { rollCard(step: 3, done: 3) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    sTag("EXPANDED · 更新后(3 → 4 滚一下)")
                    SExpanded { rollCard(step: 4, done: 4) }
                    VStack(alignment: .leading, spacing: 5) {
                        SNote(kind: .onUpdate, text: "数字 = Text(\"\\(done)\").contentTransition(.numericText()):只在 ContentState 变化的那一瞬滚动一次,约 0.3 秒")
                        SNote(kind: .onUpdate, text: "同一瞬间小径多一段实心、水獭换一帧 —— 三个动作同时发生,才有「走了一步」的整体感")
                        SNote(kind: .still, text: "两次更新之间:数字不动、小径不动、水獭不动")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SStripLabel(text: "翻牌示意(左 → 右 = 约 0.3 秒内发生的事)")
                    HStack(spacing: 10) {
                        rollFrame { Text("3").font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(SPalette.accent) }
                        rollFrame {
                            ZStack {
                                Text("3").font(.title3.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(SPalette.accent.opacity(0.28)).offset(y: -11)
                                Text("4").font(.title3.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(SPalette.accent.opacity(0.55)).offset(y: 9)
                            }
                        }
                        rollFrame { Text("4").font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(SPalette.accent) }
                        SStripLabel(text: "旧数字向上滑出,新数字从下滑入")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    sTag("COMPACT")
                    SCompact {
                        SOtter(step: 4, w: 30)
                    } trailing: {
                        Text("4/6").font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(SPalette.accent)
                    }
                }
            }
        }
    }

    private func rollCard(step: Int, done: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SOtterTile(step: step)
                VStack(alignment: .leading, spacing: 1) {
                    Text("组会周报").font(.subheadline.bold()).foregroundStyle(.white)
                    Text("打分 12 篇候选").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
                SSteps(done: done, total: 6)
            }
            SegTrail(total: 6, done: done)
        }
    }

    private func rollFrame<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(width: 40, height: 34)
            .clipped()
            .background(Color.black, in: RoundedRectangle(cornerRadius: 10))
    }
}

// =====================================================================
// MARK: - 样例 4 · 极静(一切靠小径说话)
// =====================================================================

struct IslandSampleQuiet: View {
    var body: some View {
        SampleBoard(
            title: "样例 4 · 极静(一切靠小径说话)",
            blurb: "只有水獭和小径 —— 没有时钟、没有步数、没有工具行、一个数字都没有。走到头插一面小旗,其余时候什么都不说。",
            tradeoff: "最克制、最像一幅画,但也最沉默:一步跑久了,岛看起来和卡死没有区别 —— 用户唯一的信息是「小径没长」。"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    sTag("EXPANDED · 进行中")
                    SExpanded {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                SOtterTile(step: 3)
                                Text("组会周报").font(.subheadline.bold()).foregroundStyle(.white)
                                Spacer(minLength: 0)
                            }
                            SegTrail(total: 6, done: 3)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    sTag("EXPANDED · 完成(小径尽头一面小旗)")
                    SExpanded {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                SOtterTile(step: 0)
                                Text("组会周报").font(.subheadline.bold()).foregroundStyle(.white)
                                Spacer(minLength: 0)
                            }
                            SegTrail(total: 6, done: 6, finished: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        SNote(kind: .still, text: "画面里没有任何自动刷新的元素 —— 时钟、进度条、相对时间全部拿掉了")
                        SNote(kind: .onUpdate, text: "只有推进一步时才重绘:水獭换一帧 + 小径多一段实心。这是全部的动")
                        SNote(kind: .onUpdate, text: "开放式运行(不知道总共几步)只能画一条无尽后退的路,连「还剩多少」都不说")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    sTag("COMPACT · MINIMAL(尾槽只有三枚爪印,连数字都不要)")
                    HStack(spacing: 12) {
                        SCompact {
                            SOtter(step: 3, w: 30)
                        } trailing: {
                            HStack(spacing: 4) {
                                ForEach(0..<3, id: \.self) { i in
                                    Image(systemName: "pawprint.fill").font(.system(size: 7))
                                        .foregroundStyle(SPalette.accent.opacity(i == 2 ? 0.35 : 1))
                                }
                            }
                        }
                        HStack { SOtter(step: 3, w: 24) }
                            .padding(.horizontal, 10).frame(height: 37)
                            .background(Color.black, in: Capsule())
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    sTag("EXPANDED · 开放式运行(无尽后退的路)")
                    SExpanded {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                SOtterTile(step: 5)
                                Text("Pervio").font(.subheadline.bold()).foregroundStyle(.white)
                                Spacer(minLength: 0)
                            }
                            OpenTrail()
                        }
                    }
                }
            }
        }
    }
}

// =====================================================================
// MARK: - 样例 5 · 组合(1 + 2)
// =====================================================================

struct IslandSampleCombo: View {
    var body: some View {
        SampleBoard(
            title: "样例 5 · 组合(1 + 2)· 预判最优",
            blurb: "当前格自己填(有事在进行)+ 底部工具行(在干什么)+ 右上角相对时间(跑了多久)。三种「动」各管一件事,互不抢戏,而且没有一个是秒表。",
            tradeoff: "元素最多、expanded 最满,compact 塞不下工具行 —— 只能留水獭 + 一个自己转的小圆环;另外当前格仍然是按预估时间填的,超时会先满后等。"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    sTag("EXPANDED · 工作流 4/6")
                    SExpanded {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 10) {
                                SOtterTile(step: 4)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("组会周报").font(.subheadline.bold()).foregroundStyle(.white)
                                    Text("打分 12 篇候选").font(.caption2).foregroundStyle(.white.opacity(0.6))
                                }
                                Spacer(minLength: 0)
                                SRelative()
                            }
                            SegTrail(total: 6, done: 4, currentFill: 0.55)
                            SToolRow(glyph: "doc.text", text: "Read · paper_07.pdf")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    sTag("EXPANDED · 开放式运行(不知道总共几步)")
                    SExpanded {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 10) {
                                SOtterTile(step: 6)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Pervio").font(.subheadline.bold()).foregroundStyle(.white)
                                    Text("在跑").font(.caption2).foregroundStyle(.white.opacity(0.6))
                                }
                                Spacer(minLength: 0)
                                SRelative(value: "12 分钟")
                            }
                            OpenTrail(currentFill: 0.45)
                            SToolRow(glyph: "terminal", text: "Bash · npm test")
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        SNote(kind: .auto, text: "当前格 = ProgressView(timerInterval:),系统自己填 —— 这是「还活着」的证据,哪怕十分钟不换工具")
                        SNote(kind: .auto, text: "相对时间 = Text(startedAt, style: .relative),分钟粒度自动刷新;后面「前开始」是旁边另一个 Text(拼进同一个 Text 会丢掉自动刷新)")
                        SNote(kind: .onUpdate, text: "工具行 + 小径 + 水獭:每次工具调用一起变,一次更新讲清「刚才做了什么、又往前一格」")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    sTag("COMPACT · 尾槽是一个自己转的小圆环")
                    SCompact {
                        SOtter(step: 4, w: 30)
                    } trailing: {
                        SRing(fill: 0.55)
                    }
                    SNote(kind: .auto, text: "小圆环 = ProgressView(timerInterval:) 的 .circular 样式,系统自己扫一圈 —— compact 尾槽塞得下的唯一「会自己动」的东西")
                }
            }
        }
    }
}
