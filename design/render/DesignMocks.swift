import SwiftUI

// Standalone design mockups for the HomeDashboard redesign (task #19).
// These are REAL SwiftUI, rendered to PNG via ImageRenderer (see
// DesignRenderTests). They are deliberately self-contained: the Palette hexes
// and chip idiom are copied from the app (Sources/PervioApp.swift /
// WorkflowMarketView) so this render target links nothing from the app and can
// never drift the app build. Sample content is fixed (no SSH, no live data).

// MARK: - Palette (mirror of app Palette, so mockups match the shipping look)

enum DPalette {
    static let accent     = Color(dhex: 0xD97757)   // Claude terracotta
    static let accentDeep = Color(dhex: 0xC15F3C)   // Crail (deeper)
    static let bg         = Color(dhex: 0x1A1916)   // warm near-black
    static let surface    = Color(dhex: 0x262421)   // cards, chips, input
    static let surface2   = Color(dhex: 0x312D28)   // elevated
    static let hairline    = Color(dhex: 0x3A3631)
    static let midGray    = Color(dhex: 0xB0AEA5)
}

extension Color {
    init(dhex: UInt32) {
        self.init(.sRGB,
                  red:   Double((dhex >> 16) & 0xFF) / 255.0,
                  green: Double((dhex >> 8) & 0xFF) / 255.0,
                  blue:  Double(dhex & 0xFF) / 255.0,
                  opacity: 1.0)
    }
}

// MARK: - Sample content (Chinese, one morning issue + siblings)

enum DSample {
    static let dateLine = "星期三 · 8月12日"
    static let pubName  = "arXiv 晨报"
    static let issueDate = "2026-08-12"
    static let teaser =
        "今日一句:检索增强让小模型在长上下文问答上追平了两倍参数的对手。"
    static let teaserLong =
        "今日一句:检索增强让小模型在长上下文问答上追平了两倍参数的对手 —— 代价是索引构建的一次性开销。今日 6 篇入选,2 篇标注「必读」。"
    static let bullets = [
        "扩散语言模型的并行解码把吞吐拉高 3.1×",
        "长上下文注意力的 KV 压缩:精度几乎无损",
        "小样本对齐:200 条偏好数据即可显著改善",
    ]
    // A second publication, to show the multi-card / list case.
    static let pub2Name = "组会周报"
    static let pub2Date = "2026-08-11"
    static let pub2Teaser = "本周三条主线:推理成本、评测泄漏、以及一个失败的复现。"
}

// MARK: - Shared bits

/// The app's chip idiom: caption2 on a surface2 capsule.
private struct DChip: View {
    let text: String
    var filled: Bool = false
    var body: some View {
        Text(text)
            .font(.caption2.weight(filled ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, filled ? 8 : 7).padding(.vertical, 3)
            .foregroundStyle(filled ? .white : Color.secondary)
            .background(filled ? DPalette.accent : DPalette.surface2, in: Capsule())
    }
}

/// The resting otter avatar on its cream card (matches HomeGreetingHeader).
private struct DOtter: View {
    var size: CGFloat = 44
    var body: some View {
        // The real app uses Image("otter0"); the render target has no asset
        // catalog, so we stand in with the same cream card + a terracotta paw
        // glyph. Shape/placement/color match; only the drawing differs.
        Image(systemName: "pawprint.fill")
            .font(.system(size: size * 0.5))
            .foregroundStyle(DPalette.accent)
            .frame(width: size, height: size)
            .background(Color(dhex: 0xF9F4F0), in: RoundedRectangle(cornerRadius: size * 0.23))
    }
}

// A phone-sized frame wrapper so every mock renders at a consistent canvas.
struct DPhone<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(width: 393, height: 852, alignment: .top)   // iPhone 16 / Air pts
            .background(DPalette.bg)
            .environment(\.colorScheme, .dark)
    }
}

// =====================================================================
// MARK: - Direction A — Publication-first "Newsstand"
// =====================================================================
// The morning issue is the HERO: a large edge-to-edge spread at the very top
// with masthead, excerpt, and headline bullets. Chat/Workflows/Build shrink to
// one quiet utility row; servers collapse to a single status line. The page is
// unmistakably "today's paper first".

struct DesignA_Newsstand: View {
    var body: some View {
        DPhone {
            // Plain VStack inside the fixed DPhone frame (no ScrollView): the
            // real screen scrolls, but for a snapshot a scroll view reports ~0
            // intrinsic height to ImageRenderer and paints blank. The whole
            // above-the-fold layout fits one screen, which is the point.
            VStack(alignment: .leading, spacing: 18) {
                    // Slim page chrome: otter + date, no big greeting eating space.
                    HStack(spacing: 12) {
                        DOtter(size: 36)
                        Text(DSample.dateLine)
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "person.crop.circle")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20).padding(.top, 16)

                    // HERO issue card.
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(DSample.pubName).font(.title.bold())
                            DChip(text: "今日", filled: true)
                            Spacer()
                            Text(DSample.issueDate)
                                .font(.caption).foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text(DSample.teaserLong)
                            .font(.title3)
                            .foregroundStyle(.primary.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(4)

                        Divider().overlay(DPalette.hairline)

                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(DSample.bullets, id: \.self) { b in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("—").foregroundStyle(DPalette.accent)
                                    Text(b).font(.callout).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        HStack {
                            Spacer()
                            Text("展开阅读 →")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(DPalette.accent)
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DPalette.surface, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(LinearGradient(colors: [DPalette.accent, DPalette.accentDeep],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    lineWidth: 1).opacity(0.5))
                    .padding(.horizontal, 16)

                    // Second publication, compact (the "shelf" continues below the hero).
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(DSample.pub2Name).font(.headline)
                            Text(DSample.pub2Teaser)
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(DSample.pub2Date)
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(16)
                    .background(DPalette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)

                    // Utility row — the former "quick actions", now demoted to a
                    // single quiet strip so it never competes with the paper.
                    HStack(spacing: 0) {
                        utility("对话", "bubble.left.and.bubble.right")
                        utilDivider
                        utility("流程", "square.stack.3d.up")
                        utilDivider
                        utility("搭建", "hammer")
                    }
                    .padding(.vertical, 6)
                    .background(DPalette.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)

                    Spacer(minLength: 0)

                    // Servers collapse to one status line.
                    HStack(spacing: 8) {
                        Circle().fill(DPalette.accent).frame(width: 7, height: 7)
                        Text("home-server · you@…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("切换").font(.caption).foregroundStyle(DPalette.accent)
                    }
                    .padding(.horizontal, 22).padding(.bottom, 24)
                }
        }
    }

    private func utility(_ label: String, _ icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.body).foregroundStyle(DPalette.accent)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
    }
    private var utilDivider: some View {
        Rectangle().fill(DPalette.hairline).frame(width: 1, height: 26)
    }
}

// =====================================================================
// MARK: - Direction B — Conversation-first "Command bar"
// =====================================================================
// The app is, at its core, a line to Claude on your server. So the entry point
// is an "Ask Claude…" composer pinned up top, plus warm shortcuts. The morning
// publication rides just under it as a compact, tappable digest strip — present
// and glanceable, but no longer the visual hero. Recent threads fill the rest.

struct DesignB_CommandBar: View {
    var body: some View {
        DPhone {
            VStack(alignment: .leading, spacing: 20) {
                // Greeting kept (warmth is the point of a conversation-led home).
                HStack(spacing: 12) {
                    DOtter(size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下午好").font(.title2.bold())
                        Text(DSample.dateLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 18)

                // THE command bar — the primary action of the whole screen.
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundStyle(DPalette.accent)
                        Text("问点什么,或让 Claude 开工…")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2).foregroundStyle(DPalette.accent)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(DPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(DPalette.accent.opacity(0.35), lineWidth: 1))

                    HStack(spacing: 8) {
                        DChip(text: "＋ 新对话")
                        DChip(text: "流程")
                        DChip(text: "搭建工作流")
                        Spacer()
                    }
                }
                .padding(.horizontal, 16)

                // Morning publication as a COMPACT digest strip (not a hero).
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "newspaper.fill")
                            .font(.footnote).foregroundStyle(DPalette.accent)
                        Text("今日晨报").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text(DSample.issueDate).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(DSample.pubName).font(.headline)
                        Spacer()
                        Text("阅读 →").font(.caption).foregroundStyle(DPalette.accent)
                    }
                    .padding(.horizontal, 16)

                    Text(DSample.teaser)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14)
                }
                .background(DPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16)

                // Recent threads — the conversation history the home now foregrounds.
                VStack(alignment: .leading, spacing: 12) {
                    Text("最近").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                    ForEach(recent, id: \.0) { r in
                        HStack(spacing: 12) {
                            Image(systemName: r.2).font(.body).foregroundStyle(.secondary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.0).font(.subheadline)
                                Text(r.1).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 20).padding(.vertical, 6)
                    }
                }

                Spacer()

                // Servers stay a quiet footer line.
                HStack(spacing: 8) {
                    Circle().fill(DPalette.accent).frame(width: 7, height: 7)
                    Text("home-server · you@…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("服务器").font(.caption).foregroundStyle(DPalette.accent)
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
    }

    private var recent: [(String, String, String)] {
        [("重构 orchestrator 的合并逻辑", "刚刚 · claude-code", "bubble.left"),
         ("组会周报 已生成", "1 小时前 · 工作流", "square.stack.3d.up"),
         ("修 ChatView 滚动 bug", "昨天 · claude-code", "bubble.left")]
    }
}

// =====================================================================
// MARK: - Direction C — Minimal dashboard "Ledger"
// =====================================================================
// Anthropic-report restraint: no boxed cards, no gradient strokes. Content is
// organised by TYPOGRAPHY and hairline rules alone. The publication is a titled
// entry with its date + one quote line; quick actions are plain text links;
// servers are a terse list. Skeletal, quiet, hierarchy from weight & space.

struct DesignC_Ledger: View {
    var body: some View {
        DPhone {
            VStack(alignment: .leading, spacing: 0) {
                // Masthead: date small-caps feel, no avatar box, no card.
                VStack(alignment: .leading, spacing: 6) {
                    Text(DSample.dateLine.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                    Text("Pervio").font(.largeTitle.bold())
                }
                .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 22)

                rule

                // TODAY — the publication as an editorial entry, not a card.
                sectionLabel("今日")
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(DSample.pubName).font(.title3.weight(.semibold))
                        Spacer()
                        Text(DSample.issueDate).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(DSample.teaser)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                    Text("阅读全文 →").font(.footnote.weight(.medium)).foregroundStyle(DPalette.accent)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 24).padding(.vertical, 16)

                // A second, older publication — one dense line.
                HStack(alignment: .firstTextBaseline) {
                    Text(DSample.pub2Name).font(.callout)
                    Spacer()
                    Text(DSample.pub2Date).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 24).padding(.bottom, 18)

                rule

                // ACTIONS — plain text links, no icon tiles.
                sectionLabel("开始")
                VStack(spacing: 0) {
                    ledgerLink("新对话", "与服务器上的 Claude 对话")
                    thinRule
                    ledgerLink("工作流", "运行与编排已保存的流程")
                    thinRule
                    ledgerLink("搭建工作流", "从一句话生成多步流程")
                }
                .padding(.bottom, 18)

                rule

                // SERVERS — terse list.
                sectionLabel("服务器")
                VStack(spacing: 0) {
                    serverLine("home-server", "you@…:22", home: true)
                    thinRule
                    serverLine("mac-mini", "jh@…:22", home: false)
                }

                Spacer()
            }
        }
    }

    private var rule: some View { Rectangle().fill(DPalette.hairline).frame(height: 1) }
    private var thinRule: some View {
        Rectangle().fill(DPalette.hairline.opacity(0.5)).frame(height: 1).padding(.leading, 24)
    }
    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(DPalette.midGray)
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 4)
    }
    private func ledgerLink(_ title: String, _ sub: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }
    private func serverLine(_ name: String, _ addr: String, home: Bool) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.body)
            if home {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(DPalette.accent)
            }
            Spacer()
            Text(addr).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }
}

// =====================================================================
// MARK: - RECOMMENDED — "Newsstand, quiet frame" (A's hero × C's restraint)
// =====================================================================
// The synthesis I recommend and implement. It keeps the publication card as the
// undisputed protagonist (the existing, liked hero — Palette surface + 1pt
// terracotta stroke + NEW/date capsules), and pushes EVERYTHING ELSE toward
// ledger restraint: the three tinted quick-action tiles become quiet text rows
// with hairline rules; servers stay a clean list. Nothing boxed competes with
// the paper, yet the morning issue still visually leads. Lowest-risk because the
// hero card already ships — the change is mostly REMOVING chrome elsewhere.

struct DesignRecommended: View {
    var body: some View {
        DPhone {
            VStack(alignment: .leading, spacing: 0) {
                // Greeting header — unchanged app chrome (otter + greeting + date).
                HStack(spacing: 14) {
                    DOtter(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下午好").font(.title2.bold())
                        Text(DSample.dateLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 18)

                // PROTAGONIST: the publication hero card (kept as-is).
                heroCard.padding(.horizontal, 16).padding(.bottom, 12)

                // A quieter second publication (still a card, dimmed) — the shelf.
                secondPub.padding(.horizontal, 16).padding(.bottom, 22)

                // Quick actions, demoted from tinted tiles to a ledger list.
                sectionLabel("开始")
                VStack(spacing: 0) {
                    actionRow("新对话", "bubble.left.and.bubble.right", "与服务器上的 Claude 对话")
                    thinRule
                    actionRow("工作流", "square.stack.3d.up", "运行与编排已保存的流程")
                    thinRule
                    actionRow("搭建工作流", "hammer", "从一句话生成多步流程")
                }
                .padding(.bottom, 18)

                rule

                // Servers — terse list (unchanged behaviour, quiet visual).
                sectionLabel("服务器")
                serverLine("home-server", "you@…:22", home: true)
                thinRule
                serverLine("mac-mini", "jh@…:22", home: false)

                Spacer(minLength: 0)
            }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(DSample.pubName).font(.headline)
                Text("NEW").font(.caption2.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(DPalette.accentDeep, in: Capsule())
                Spacer()
                Text(DSample.issueDate).font(.caption2).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(DPalette.accent, in: Capsule()).monospacedDigit()
            }
            Text(DSample.teaser)
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Text("Read →").font(.caption).foregroundStyle(DPalette.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(LinearGradient(colors: [DPalette.accent, DPalette.accentDeep],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1).opacity(0.45))
    }

    private var secondPub: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(DSample.pub2Name).font(.headline)
                Spacer()
                Text(DSample.pub2Date).font(.caption2).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(DPalette.accent.opacity(0.8), in: Capsule()).monospacedDigit()
            }
            Text(DSample.pub2Teaser).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            Text("Read →").font(.caption).foregroundStyle(DPalette.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DPalette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(LinearGradient(colors: [DPalette.accent, DPalette.accentDeep],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1).opacity(0.22))
    }

    private var rule: some View { Rectangle().fill(DPalette.hairline).frame(height: 1) }
    private var thinRule: some View {
        Rectangle().fill(DPalette.hairline.opacity(0.5)).frame(height: 1).padding(.leading, 20)
    }
    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 6)
    }
    private func actionRow(_ title: String, _ icon: String, _ sub: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.body).foregroundStyle(DPalette.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 11)
    }
    private func serverLine(_ name: String, _ addr: String, home: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack").font(.footnote).foregroundStyle(DPalette.accent).frame(width: 24)
            Text(name).font(.body)
            if home {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(DPalette.accent)
            }
            Spacer()
            Text(addr).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 20).padding(.vertical, 11)
    }
}

// =====================================================================
// MARK: - FINAL — B layout with the quiet composer (user-approved synthesis)
// =====================================================================
// The shipped design: Direction B's page order (composer → digest → recent →
// servers footer), but the composer restyled to C's restraint — no boxed
// field, no big capsule: a short underline-style row (plain text over a
// hairline rule) with a subdued send arrow. Chips, digest strips, recent list
// and footer as in B. Mirrors the real HomeDashboard/RootView implementation.

struct DesignFinal_BQuietComposer: View {
    var body: some View {
        DPhone {
            VStack(alignment: .leading, spacing: 20) {
                // Greeting (unchanged app chrome).
                HStack(spacing: 12) {
                    DOtter(size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下午好").font(.title2.bold())
                        Text(DSample.dateLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 18)

                // QUIET composer: underline hairline, no box, small send arrow.
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text("问点什么,或让 Claude 开工…")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "arrow.up.circle")
                            .font(.title3).foregroundStyle(Color.secondary)
                    }
                    .padding(.bottom, 8)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(DPalette.hairline).frame(height: 1)
                    }
                    HStack(spacing: 8) {
                        DChip(text: "＋ 新对话")
                        DChip(text: "流程")
                        DChip(text: "搭建工作流")
                        Spacer()
                    }
                }
                .padding(.horizontal, 16)

                // Publications as compact digest strips (final shell style:
                // surface fill, no gradient stroke, plain date, 2-line teaser).
                VStack(spacing: 10) {
                    digestStrip(DSample.pubName, DSample.issueDate, DSample.teaser, fresh: true)
                    digestStrip(DSample.pub2Name, DSample.pub2Date, DSample.pub2Teaser, fresh: false)
                }
                .padding(.horizontal, 16)

                // Recent threads — bare rows.
                VStack(alignment: .leading, spacing: 12) {
                    Text("最近").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                    ForEach(recent, id: \.0) { r in
                        HStack(spacing: 12) {
                            Image(systemName: r.2).font(.body).foregroundStyle(.secondary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.0).font(.subheadline).lineLimit(1)
                                Text(r.1).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 20).padding(.vertical, 5)
                    }
                }

                Spacer(minLength: 0)

                // Servers footer — one quiet line, management one push away.
                HStack(spacing: 8) {
                    Circle().fill(DPalette.accent).frame(width: 7, height: 7)
                    Text("home-server · you@…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("服务器").font(.caption).foregroundStyle(DPalette.accent)
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
    }

    private func digestStrip(_ name: String, _ date: String, _ teaser: String, fresh: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).font(.headline)
                if fresh {
                    Text("NEW").font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(DPalette.accentDeep, in: Capsule())
                }
                Spacer()
                Text(date).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(teaser).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            Text("Read →").font(.caption).foregroundStyle(DPalette.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DPalette.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var recent: [(String, String, String)] {
        [("重构 orchestrator 的合并逻辑", "刚刚 · Pervio", "bubble.left"),
         ("组会周报 已生成", "1 小时前 · 工作流", "square.stack.3d.up"),
         ("修 ChatView 滚动 bug", "昨天 · Pervio", "bubble.left")]
    }
}
