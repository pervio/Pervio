import SwiftUI

// =====================================================================
// THE SHIPPED ISLAND — 组合版(样例 5)落地后的真实现
// =====================================================================
// Unlike every other file in design/render, this one draws NOTHING of its own.
// It imports the widget's real `IslandViews.swift` (added to this target in
// project.yml) and renders the SHIPPING card — the same structs SpringBoard
// draws on the phone. A design PNG that is a hand-drawn mockup of the code is a
// PNG that starts lying the first time the code changes; this one goes red-ish
// by construction, because if the island's layout moves, this render moves with
// it.
//
// TWO THINGS A STILL PNG CANNOT SHOW, and how they are handled here:
//   * the current trail cell is a real `ProgressView(timerInterval:)`. Rendered
//     with a window centred on now, so the system draws it at ~50% — a true
//     snapshot of a bar that on device slides 0 → 1 by itself.
//   * the compact ring is the same primitive in `.circular` style, which OUTSIDE
//     a widget renders as an indeterminate spinner (WidgetKit is what turns it
//     into a swept ring). `IslandRing(frozenFill:)` stands in with the arc at
//     55%, which is what the phone shows mid-step.

private final class ProductionBundleAnchor {}
private let productionBundle = Bundle(for: ProductionBundleAnchor.self)

/// The board: every presentation of the shipped card, annotated with which of
/// the three motion primitives each moving part is spending.
struct IslandProductionCombo: View {
    /// One clock for the whole board, so every card's relative time and filling
    /// cell agree with each other.
    private let now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("生产版灵动岛 · 组合(样例 5)")
                    .font(.headline).foregroundStyle(.white)
                Text("这张图不是稿子,是 ios/LiveActivity/IslandViews.swift 里那几个 View 直接渲染出来的 —— "
                     + "手机上 SpringBoard 画的就是这些结构。")
                    .font(.caption).foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("EXPANDED · 工作流 4/6,第 5 格正在自己填") {
                IslandExpandedCard(
                    title: "组会周报", subtitle: "4/6 步已完成",
                    step: 4, done: 4, total: 6,
                    startedAt: now.addingTimeInterval(-185),
                    current: now.addingTimeInterval(-45)...now.addingTimeInterval(45),
                    toolGlyph: "doc.text", toolLine: "Read · paper_07.pdf",
                    strings: .chinese, bundle: productionBundle)
            }

            section("EXPANDED · 开放式运行(不知道总共几步)") {
                IslandExpandedCard(
                    title: "Pervio", subtitle: "在跑",
                    step: 6, done: 0, total: 0,
                    startedAt: now.addingTimeInterval(-740),
                    current: now.addingTimeInterval(-40)...now.addingTimeInterval(50),
                    toolGlyph: "terminal", toolLine: "Bash · npm test",
                    strings: .chinese, bundle: productionBundle)
            }

            VStack(alignment: .leading, spacing: 6) {
                note(.auto, "当前格 = ProgressView(timerInterval: 这一步的预估区间),系统自己从左填到右 —— "
                     + "十分钟不换工具也看得出还活着")
                note(.auto, "右上角 = Text(startedAt, style: .relative) + 旁边独立的「前开始」;"
                     + "拼进同一个 Text 会丢掉自动刷新,所以是两个 Text")
                note(.update, "工具行 + 小径 + 水獭:每次工具调用一起变,一次更新讲清「刚做了什么、又往前一格」")
                note(.still, "没有秒表。mm:ss 是上一版的主角,它让一次运行看起来像倒计时,却不说有没有在动")
            }

            section("COMPACT · 左水獭,尾槽一个自己转的小圆环") {
                HStack(spacing: 14) {
                    IslandCompactCard(step: 4, frozenFill: 0.55, bundle: productionBundle)
                    HStack { IslandOtter(step: 4, width: 24, bundle: productionBundle) }
                        .padding(.horizontal, 10).frame(height: 37)
                        .background(Color.black, in: Capsule())
                    Text("MINIMAL").font(.system(size: 10, weight: .semibold)).tracking(1)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }

            section("终态 · 完成(小旗 + 填满)与失败(锈色石堆 + 去饱和水獭)") {
                VStack(alignment: .leading, spacing: 10) {
                    IslandExpandedCard(
                        title: "组会周报", subtitle: "6/6 步已完成",
                        step: 0, done: 6, total: 6, finished: true,
                        startedAt: now.addingTimeInterval(-980),
                        strings: .chinese, bundle: productionBundle)
                    IslandExpandedCard(
                        title: "组会周报", subtitle: "第 3 步失败",
                        step: 3, done: 2, total: 6, finished: true, failed: true,
                        startedAt: now.addingTimeInterval(-420),
                        strings: .chinese, bundle: productionBundle)
                    HStack(spacing: 14) {
                        IslandCompactCard(step: 0, finished: true, bundle: productionBundle)
                        IslandCompactCard(step: 3, finished: true, failed: true, bundle: productionBundle)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                HStack(alignment: .top, spacing: 8) {
                    Text("取舍").font(.system(size: 10, weight: .semibold)).tracking(1)
                        .foregroundStyle(IslandPalette.accent)
                        .frame(width: 46, alignment: .leading)
                    Text("当前格按【预估时间】填,不按真实进度:一步提前做完,小径会在格子填满前就往前跳;"
                         + "一步超时,格子先填满再干等 —— 填满 ≠ 做完。没有预估时,聊天/运行用这次运行"
                         + "自己的工具调用间隔,工作流用它自己的平均步时,都没有就退回 90 秒。")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(24)
        .frame(width: 452, alignment: .leading)
        .background(Color(red: 0x14 / 255, green: 0x13 / 255, blue: 0x11 / 255))
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Board chrome

    private func section<C: View>(_ tag: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tag).font(.caption2.weight(.semibold)).tracking(1)
                .foregroundStyle(.white.opacity(0.45))
            content()
        }
    }

    private enum Motion { case auto, update, still }

    private func note(_ kind: Motion, _ text: String) -> some View {
        let (label, tint): (String, Color) = {
            switch kind {
            case .auto:   return ("自动", IslandPalette.accent)
            case .update: return ("更新时", Color(red: 0.55, green: 0.60, blue: 0.66))
            case .still:  return ("没有", Color(white: 0.42))
            }
        }()
        return HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(kind == .auto ? Color.black : Color.white.opacity(0.9))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(tint.opacity(kind == .auto ? 1 : 0.35), in: Capsule())
                .frame(width: 46, alignment: .leading)
            Text(text).font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
