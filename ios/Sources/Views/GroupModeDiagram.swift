import SwiftUI

/// The create sheet's picture of a mode, drawn by the one legend the chips and
/// the rail follow (design page, 2026-10-14): orange filled = the primary,
/// white filled = the partner or watcher, gray outline = the person and the
/// results; a solid edge runs every round, a dashed one only on a condition or
/// the person's tap; every moving dot is gray — a message in flight, whose
/// author is the node it left. 头脑风暴 fans one question out and back into a
/// conclusion; 监督 loops the primary's work past the watcher to a verdict;
/// 双窗 keeps two equal windows apart with the person between them.
struct GroupModeDiagram: View {
    let mode: String
    var primaryEngine: String = "claude"
    var partnerEngine: String = "codex"

    private enum Fill { case accent, ink, outline }
    private struct Node: Identifiable {
        let id: String
        let label: String
        var sub: String? = nil
        let x: CGFloat
        let y: CGFloat
        var fill: Fill = .outline
    }
    private struct Edge {
        let from: String
        let to: String
        var dashed = false
        var phase: Double = 0
        var label: String? = nil
        /// Where the label sits, in unit coordinates.
        var lx: CGFloat = 0
        var ly: CGFloat = 0
        /// Sideways shift in points, so two edges between the same pair of
        /// nodes (result down, feedback back up) do not lie on one line.
        var dx: CGFloat = 0
    }

    private var nodes: [Node] {
        switch mode {
        case "watch":
            return [Node(id: "you", label: L.diagYou(), x: 0.12, y: 0.5),
                    Node(id: "p", label: L.groupPrimary(), x: 0.48, y: 0.2, fill: .accent),
                    Node(id: "w", label: L.groupWatcher(), x: 0.48, y: 0.8, fill: .ink),
                    Node(id: "out", label: L.diagVerdict(), x: 0.86, y: 0.5)]
        case "duo":
            return [Node(id: "p", label: L.groupPartnerN(1), sub: primaryEngine, x: 0.27, y: 0.3, fill: .accent),
                    Node(id: "m", label: L.groupPartnerN(2), sub: partnerEngine, x: 0.73, y: 0.3, fill: .ink),
                    Node(id: "you", label: L.diagYou(), x: 0.5, y: 0.82)]
        default:
            return [Node(id: "you", label: L.diagYou(), x: 0.12, y: 0.5),
                    Node(id: "p", label: L.groupPrimary(), x: 0.46, y: 0.2, fill: .accent),
                    Node(id: "m", label: L.groupPartner(), x: 0.46, y: 0.8, fill: .ink),
                    Node(id: "out", label: L.diagConclusion(), x: 0.86, y: 0.5, fill: .accent)]
        }
    }

    private var edges: [Edge] {
        switch mode {
        case "watch":
            return [Edge(from: "you", to: "p", label: L.diagTask(), lx: 0.27, ly: 0.26),
                    Edge(from: "p", to: "w", phase: 0.33, label: L.diagResult(), lx: 0.6, ly: 0.52, dx: 7),
                    Edge(from: "w", to: "p", dashed: true, phase: 0.66, label: L.diagFeedback(), lx: 0.35, ly: 0.58, dx: -7),
                    Edge(from: "w", to: "out", phase: 0.5)]
        case "duo":
            return [Edge(from: "you", to: "p", label: L.diagSay(), lx: 0.32, ly: 0.66),
                    Edge(from: "you", to: "m", phase: 0.5, label: L.diagSay(), lx: 0.68, ly: 0.66),
                    Edge(from: "m", to: "p", dashed: true, phase: 0.25, label: L.diagCritique(), lx: 0.5, ly: 0.1),
                    Edge(from: "p", to: "m", dashed: true, phase: 0.75)]
        default:
            return [Edge(from: "you", to: "p", label: L.diagAsk(), lx: 0.27, ly: 0.26),
                    Edge(from: "you", to: "m", label: L.diagAsk(), lx: 0.27, ly: 0.78),
                    Edge(from: "p", to: "out", phase: 0.5, label: L.diagAnswer(), lx: 0.68, ly: 0.26),
                    Edge(from: "m", to: "out", phase: 0.5, label: L.diagAnswer(), lx: 0.68, ly: 0.78)]
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let pos = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, CGPoint(x: $0.x * w, y: $0.y * h)) })
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6
                ZStack {
                    ForEach(Array(edges.enumerated()), id: \.offset) { _, e in
                        if let a0 = pos[e.from], let b0 = pos[e.to] {
                            let a = CGPoint(x: a0.x + e.dx, y: a0.y), b = CGPoint(x: b0.x + e.dx, y: b0.y)
                            Path { p in p.move(to: a); p.addLine(to: b) }
                                .stroke(Palette.hairline, style: StrokeStyle(lineWidth: 1.5, dash: e.dashed ? [4, 4] : []))
                            let f = (t + e.phase).truncatingRemainder(dividingBy: 1)
                            Circle().fill(Color.secondary)
                                .frame(width: 6, height: 6)
                                .position(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                            if let label = e.label {
                                Text(label).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
                                    .position(x: e.lx * w, y: e.ly * h)
                            }
                        }
                    }
                    ForEach(nodes) { n in
                        VStack(spacing: 0) {
                            Text(n.label).font(.caption2.weight(.semibold))
                            if let sub = n.sub {
                                Text(sub).font(.system(size: 9, design: .monospaced)).opacity(0.85)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, n.sub == nil ? 5 : 4)
                        .background(fill(n.fill), in: Capsule())
                        .overlay(Capsule().stroke(n.fill == .outline ? Palette.hairline : Color.clear, lineWidth: 1))
                        .foregroundStyle(ink(n.fill))
                        .position(pos[n.id] ?? .zero)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func fill(_ f: Fill) -> Color {
        switch f {
        case .accent:  return Palette.accent
        case .ink:     return Color.primary
        case .outline: return Palette.surface2
        }
    }
    private func ink(_ f: Fill) -> Color {
        switch f {
        case .accent:  return Color.white
        case .ink:     return Palette.bg
        case .outline: return Color.primary
        }
    }
}
