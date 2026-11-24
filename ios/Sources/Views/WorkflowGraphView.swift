import SwiftUI
import Foundation

/// Compiled once (global `let` = lazy + thread-safe). This gets called from editor
/// body evaluations — input chips, graph nodes, validation — where compiling the
/// NSRegularExpression on every call added up.
private let workflowOutputRefsRE =
    try? NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z0-9_-]+)\\.output\\s*\\}\\}")

/// Parse the {{id.output}} references in a prompt — i.e. which earlier steps' data
/// this step pulls in. These are the DATA-FLOW edges drawn in the graph.
func workflowOutputRefs(in text: String) -> [String] {
    guard let re = workflowOutputRefsRE else { return [] }
    var ids: [String] = []
    re.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { m, _, _ in
        if let m, let r = Range(m.range(at: 1), in: text) {
            let id = String(text[r])
            if !ids.contains(id) { ids.append(id) }
        }
    }
    return ids
}

/// One node fed to `WorkflowGraphView`. Built from a ledger step (live status),
/// a draft step (editor preview), or a market spec step (template shape).
struct WorkflowGraphNode: Identifiable, Equatable {
    let id: String
    let backend: AgentBackend
    /// "" = neutral (editor/market preview); otherwise pending/running/done/failed/skipped.
    let status: String
    /// Execution / stage ordering — drives the LAYOUT (which row a node sits in).
    let dependsOn: [String]
    /// Data inputs ({{id.output}} refs) — drives the EDGES (whose output feeds whom).
    /// Defaults to `dependsOn` when a caller doesn't separate the two.
    let inputs: [String]

    init(id: String, backend: AgentBackend, status: String,
         dependsOn: [String], inputs: [String]? = nil) {
        self.id = id
        self.backend = backend
        self.status = status
        self.dependsOn = dependsOn
        self.inputs = inputs ?? dependsOn
    }
}

/// Single source of truth for status → color / label, shared by the graph and the
/// `WorkflowStatusBadge` so they can never drift.
enum WorkflowStatusStyle {
    static func color(_ status: String) -> Color {
        switch status {
        case "done":    return .green
        case "failed":  return .red
        case "running": return Palette.accent
        case "skipped": return .orange
        default:        return .secondary   // pending / neutral
        }
    }
    static func label(_ status: String) -> String {
        switch status {
        case "done":    return "DONE"
        case "failed":  return "FAILED"
        case "running": return "RUNNING"
        case "skipped": return "SKIPPED"
        case "pending": return "PENDING"
        default:        return status.uppercased()
        }
    }
}

/// A read-only, auto-laid-out flow diagram of a workflow's DAG. Nodes are placed
/// in topological layers (top → down; independent steps sit side-by-side), edges
/// are drawn behind them, and node cards are colored by live status. Pure SwiftUI
/// (Canvas + deterministic coordinates) — no graph library, no GeometryReader
/// measurement, so layout is stable and cheap for the small graphs we deal with.
///
/// `scrolls`: true = own both-axis ScrollView (fills space — for the monitor);
/// false = horizontal-only scroll at intrinsic height (embeds in a parent's
/// vertical scroll — for the editor / market preview).
struct WorkflowGraphView: View {
    let nodes: [WorkflowGraphNode]
    var onSelect: ((String) -> Void)? = nil
    var scrolls: Bool = true

    // Layout constants (tuned for a phone). Narrower cards + a touch more vertical
    // gap reduce the crowding/overlap on small screens.
    private let nodeW: CGFloat = 108
    private let nodeH: CGFloat = 54
    private let hGap: CGFloat = 14
    private let vGap: CGFloat = 42
    private let pad: CGFloat = 14

    var body: some View {
        if nodes.isEmpty {
            EmptyView()
        } else {
            let layout = computeLayout()
            if scrolls {
                ScrollView([.horizontal, .vertical]) { canvas(layout) }
            } else {
                // Center the diagram when it's narrower than the container; only
                // scroll horizontally when it's actually wider than the screen.
                GeometryReader { geo in
                    ScrollView(.horizontal, showsIndicators: false) {
                        canvas(layout).frame(minWidth: geo.size.width, alignment: .center)
                    }
                }
                .frame(height: layout.size.height)
            }
        }
    }

    private func canvas(_ layout: Layout) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for e in layout.edges {
                    let midY = (e.from.y + e.to.y) / 2
                    var line = Path()
                    line.move(to: e.from)
                    line.addCurve(to: e.to,
                                  control1: CGPoint(x: e.from.x, y: midY),
                                  control2: CGPoint(x: e.to.x, y: midY))
                    ctx.stroke(line, with: .color(e.color), lineWidth: 1.5)
                    // Arrowhead at the target (downward flow).
                    let a: CGFloat = 5
                    var head = Path()
                    head.move(to: CGPoint(x: e.to.x - a, y: e.to.y - a))
                    head.addLine(to: e.to)
                    head.addLine(to: CGPoint(x: e.to.x + a, y: e.to.y - a))
                    ctx.stroke(head, with: .color(e.color), lineWidth: 1.5)
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)

            ForEach(nodes) { n in
                if let c = layout.centers[n.id] {
                    nodeCard(n).position(c)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    // MARK: node card

    private func nodeCard(_ n: WorkflowGraphNode) -> some View {
        let color = WorkflowStatusStyle.color(n.status)
        let neutral = n.status.isEmpty
        return Button {
            onSelect?(n.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(n.backend.iconAsset).resizable().scaledToFit().frame(width: 14, height: 14)
                    Text(n.id).font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if n.status == "running" {
                        ProgressView().controlSize(.mini)
                    } else if !neutral {
                        Circle().fill(color).frame(width: 7, height: 7)
                    }
                }
                if !neutral {
                    Text(WorkflowStatusStyle.label(n.status))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color)
                }
            }
            .frame(width: nodeW, height: nodeH, alignment: .topLeading)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(neutral ? Palette.hairline : color.opacity(0.7), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(onSelect == nil)
        // The card sizes itself via the inner frame; fix the outer footprint too so
        // .position() centers a known box.
        .frame(width: nodeW + 18, height: nodeH + 14)
    }

    // MARK: layout

    private struct Layout {
        var centers: [String: CGPoint]
        var edges: [(from: CGPoint, to: CGPoint, color: Color)]
        var size: CGSize
    }

    /// The structural half (layering → centers/size) is pure in (ids, dependsOn,
    /// inputs) and the topology never changes mid-run — but the monitor republishes
    /// the ledger on every tail emit, re-evaluating body each time. Memoize it;
    /// only the cheap edge pass (whose colors track live status) recomputes.
    @MainActor private static var structureCache: [String: ([String: CGPoint], CGSize)] = [:]

    private func computeLayout() -> Layout {
        let ids = Set(nodes.map { $0.id })
        let nodeById = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let cellH = nodeH + 14

        let key = nodes.map {
            "\($0.id)|\($0.dependsOn.joined(separator: ","))|\($0.inputs.joined(separator: ","))"
        }.joined(separator: ";")
        let centers: [String: CGPoint]
        let size: CGSize
        if let hit = Self.structureCache[key] {
            (centers, size) = hit
        } else {
            (centers, size) = computeStructure(ids: ids, nodeById: nodeById)
            if Self.structureCache.count > 16 { Self.structureCache.removeAll() }  // tiny, crude cap
            Self.structureCache[key] = (centers, size)
        }

        // EDGES are the data flow (inputs), NOT the execution/stage ordering: a line
        // means "this step uses that step's output". A step whose output nobody uses
        // has no outgoing line; the row it sits in still shows when it runs.
        var edges: [(from: CGPoint, to: CGPoint, color: Color)] = []
        for n in nodes {
            guard let dst = centers[n.id] else { continue }
            for dep in n.inputs where ids.contains(dep) && dep != n.id {
                guard let src = centers[dep] else { continue }
                let done = (nodeById[dep]?.status ?? "") == "done"
                edges.append((
                    from: CGPoint(x: src.x, y: src.y + cellH / 2 - 7),
                    to:   CGPoint(x: dst.x, y: dst.y - cellH / 2 + 7),
                    color: done ? Color.green.opacity(0.55) : Palette.hairline))
            }
        }
        return Layout(centers: centers, edges: edges, size: size)
    }

    private func computeStructure(ids: Set<String>,
                                  nodeById: [String: WorkflowGraphNode]) -> ([String: CGPoint], CGSize) {
        let indexById = Dictionary(nodes.enumerated().map { ($0.element.id, $0.offset) },
                                   uniquingKeysWith: { a, _ in a })

        // Longest-path layering with a cycle guard: layer = 1 + max(layer of deps),
        // 0 for roots. A back-edge (cycle) resolves to 0 so recursion can't loop.
        var memo: [String: Int] = [:]
        var visiting: Set<String> = []
        func layer(_ id: String) -> Int {
            if let m = memo[id] { return m }
            if visiting.contains(id) { return 0 }
            visiting.insert(id)
            let deps = (nodeById[id]?.dependsOn ?? []).filter { ids.contains($0) && $0 != id }
            let l = deps.isEmpty ? 0 : 1 + (deps.map { layer($0) }.max() ?? 0)
            visiting.remove(id)
            memo[id] = l
            return l
        }
        for n in nodes { _ = layer(n.id) }

        let maxLayer = memo.values.max() ?? 0
        var byLayer: [[String]] = Array(repeating: [], count: maxLayer + 1)
        for n in nodes { byLayer[memo[n.id] ?? 0].append(n.id) }
        for i in byLayer.indices {
            byLayer[i].sort { (indexById[$0] ?? 0) < (indexById[$1] ?? 0) }
        }

        let cellW = nodeW + 18, cellH = nodeH + 14
        let maxCount = byLayer.map { $0.count }.max() ?? 1
        let contentW = CGFloat(maxCount) * cellW + CGFloat(max(0, maxCount - 1)) * hGap + pad * 2
        let contentH = CGFloat(maxLayer + 1) * cellH + CGFloat(maxLayer) * vGap + pad * 2

        var centers: [String: CGPoint] = [:]
        for (l, row) in byLayer.enumerated() {
            let n = row.count
            let rowW = CGFloat(n) * cellW + CGFloat(max(0, n - 1)) * hGap
            let startX = (contentW - rowW) / 2
            let y = pad + CGFloat(l) * (cellH + vGap) + cellH / 2
            for (i, id) in row.enumerated() {
                centers[id] = CGPoint(x: startX + CGFloat(i) * (cellW + hGap) + cellW / 2, y: y)
            }
        }
        return (centers, CGSize(width: contentW, height: contentH))
    }
}
