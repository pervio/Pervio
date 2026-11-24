import SwiftUI

/// Everything the engine runs beside the conversation, listed: each sub-agent
/// with its type, how long it has been going, the tokens and tool calls it has
/// used and what it is doing now; each background command; then what has
/// ended, with what it came back with. Opened from the one line above the
/// composer (2026-11-22, the person: "可以点击查看一共有多少").
///
/// It reads the store, so a row counts and an ending moves down while the
/// sheet is up. A running row has a stop key where one task CAN be stopped on
/// its own (a living Claude run — `ChatStore.canStopBackgroundTasks`); the
/// whole run stops from the tasks list as ever.
struct BackgroundTaskSheet: View {
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BackgroundTaskList(tasks: store.backgroundTasks, done: store.backgroundDone,
                               stopping: store.stoppingTasks,
                               onStop: store.canStopBackgroundTasks ? { id in Task { await store.stopBackgroundTask(id) } } : nil)
                .background(Palette.bg)
                .pervioBar(L.bgSheetTitle(), back: false)
                .toolbar {
                    BarItem(.confirmationAction) { BarWord(text: L.done(), weight: .semibold) { dismiss() } }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The list, scrolling and counting.
struct BackgroundTaskList: View {
    let tasks: [BackgroundTask]
    let done: [BackgroundTaskRecord]
    var stopping: Set<String> = []
    var onStop: ((String) -> Void)? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            ScrollView {
                BackgroundTaskRows(tasks: tasks, done: done, now: ctx.date, stopping: stopping, onStop: onStop)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("background-list")
        }
    }
}

/// The list's content on plain values at one moment — what the sheet shows,
/// and what a snapshot draws.
struct BackgroundTaskRows: View {
    let tasks: [BackgroundTask]
    let done: [BackgroundTaskRecord]
    let now: Date
    /// Rows asked to stop, not yet reported as ended.
    var stopping: Set<String> = []
    /// nil where one task cannot be stopped on its own: no key is drawn.
    var onStop: ((String) -> Void)? = nil
    /// The row whose stop key was tapped: asked about once before it is sent.
    @State private var asking: BackgroundTask?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if tasks.isEmpty && done.isEmpty {
                Text(L.bgSheetEmpty()).font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 36)
                    .accessibilityIdentifier("background-empty")
            }
            if !tasks.isEmpty {
                section(L.bgSectionRunning(tasks.count), note: L.bgCount(BackgroundCount(tasks.map(\.kind)))) {
                    ForEach(Array(BackgroundFormat.nested(tasks, parent: \.parentId).enumerated()), id: \.element.row.id) { i, item in
                        RunningRow(task: item.row, depth: item.depth, first: i == 0, now: now,
                                   stopping: stopping.contains(item.row.id),
                                   onStop: onStop == nil ? nil : { asking = item.row })
                    }
                }
            }
            if !done.isEmpty {
                section(L.bgSectionEnded(done.count), note: nil) {
                    ForEach(Array(BackgroundFormat.nested(done, parent: \.parentId).enumerated()), id: \.element.row.id) { i, item in
                        EndedRow(record: item.row, depth: item.depth, first: i == 0)
                    }
                }
            }
            if !tasks.isEmpty {
                Text(L.bgCardHint()).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .confirmationDialog(asking.map { L.bgStopAsk($0.description.isEmpty ? L.bgUnnamed($0.kind) : $0.description) } ?? "",
                            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible) {
            Button(L.bgStop(), role: .destructive) {
                if let id = asking?.id { onStop?(id) }
                asking = nil
            }
            .accessibilityIdentifier("background-stop-confirm")
        } message: {
            Text(L.bgStopNote())
        }
    }

    private func section<Rows: View>(_ title: String, note: String?, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 8)
                if let note { Text(note).font(.caption).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1) }
            }
            VStack(alignment: .leading, spacing: 0) { rows() }
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
        }
    }
}

// MARK: - Rows

/// A sub-agent's totals as they are said in a row: "12k tokens · 6 tool uses".
private func totals(tokens: Int?, toolUses: Int?) -> [String] {
    var parts: [String] = []
    if let tokens, tokens > 0 { parts.append(L.bgTokens(BackgroundFormat.tokens(tokens))) }
    if let toolUses, toolUses > 0 { parts.append(L.bgToolUses(toolUses)) }
    return parts
}

/// A sub-agent's type ("general-purpose", "Explore", a custom agent's name) in
/// front of its figures; nothing for a command.
private struct FiguresLine: View {
    let agentType: String?
    let figures: Text

    var body: some View {
        if let agentType {
            // On one line when it fits; a long type or a long line of figures
            // (English, an ended row) puts the figures under the type instead
            // of cutting them short.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) { badge(agentType); line }
                VStack(alignment: .leading, spacing: 3) { badge(agentType); line }
            }
        } else {
            line
        }
    }

    private var line: some View { figures.font(.caption).monospacedDigit().lineLimit(1) }

    private func badge(_ type: String) -> some View {
        Text(type).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Palette.surface2, in: Capsule())
            .fixedSize()
    }
}

private func icon(_ kind: BackgroundTask.Kind) -> String {
    switch kind {
    case .agent: return "sparkles"            // the Agent tool's mark in the transcript
    case .command: return "terminal"
    case .other: return "gearshape"
    }
}

/// The frame every row shares: the kind's mark, the task's name on a line of
/// its own, and whatever lines the row has under it (a sub-agent's type leads
/// the first of them — beside the name it was squeezed to "gene…"). A task a
/// sub-agent launched itself sits indented under that sub-agent.
private struct TaskRowFrame<Lines: View>: View {
    let kind: BackgroundTask.Kind
    let title: String
    let depth: Int
    /// The section's first row: no rule above it.
    let first: Bool
    let dim: Bool
    /// The stop key of a running row, where there is one.
    var stop: (() -> Void)? = nil
    var stopId: String = ""
    /// The words of the row read as ONE element under this name — beside a
    /// stop key that stays a control of its own (and apart from the kind's
    /// mark, whose own description is "Terminal Command Prompt").
    let wordsId: String
    @ViewBuilder var lines: Lines

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(kind))
                .font(.footnote).foregroundStyle(dim ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Palette.accent))
                .frame(width: 20, alignment: .center).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline).foregroundStyle(dim ? .secondary : .primary).lineLimit(2)
                lines
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(wordsId)
            Spacer(minLength: 0)
            if let stop {
                Button(action: stop) {
                    Image(systemName: "stop.circle").font(.title3).foregroundStyle(.secondary)
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.bgStop())
                .accessibilityIdentifier("background-stop-\(stopId)")
            }
        }
        .padding(.leading, 12 + CGFloat(min(depth, 3)) * 22).padding(.trailing, stop == nil ? 12 : 4).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.leading, 12) }
        }
    }
}

private struct RunningRow: View {
    let task: BackgroundTask
    let depth: Int
    let first: Bool
    let now: Date
    var stopping = false
    var onStop: (() -> Void)? = nil

    var body: some View {
        TaskRowFrame(kind: task.kind, title: task.description.isEmpty ? L.bgUnnamed(task.kind) : task.description,
                     depth: depth, first: first, dim: false,
                     stop: stopping ? nil : onStop, stopId: task.id, wordsId: "background-running-\(task.id)") {
            FiguresLine(agentType: task.agentType,
                        figures: Text(([BackgroundClock.elapsed(since: task.startedAt, now: now)]
                                       + totals(tokens: task.tokens, toolUses: task.toolUses)).joined(separator: " · "))
                            .foregroundStyle(.secondary))
            if stopping {
                Text(L.bgStopping()).font(.caption).foregroundStyle(.orange)
            } else if let doing = task.activity, !doing.isEmpty, doing != task.description {
                Text(doing).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

private struct EndedRow: View {
    let record: BackgroundTaskRecord
    let depth: Int
    let first: Bool

    var body: some View {
        let took = BackgroundClock.format(record.duration)
        let (word, tint): (String, Color) = {
            switch record.status {
            case "completed": return (L.bgCardDone(took), .green)
            case "stopped": return (L.bgCardStopped(took), Palette.midGray)
            default: return (L.bgCardFailed(took), .orange)
            }
        }()
        TaskRowFrame(kind: record.kind, title: record.description.isEmpty ? L.bgUnnamed(record.kind) : record.description,
                     depth: depth, first: first, dim: true, wordsId: "background-ended-\(record.id)") {
            FiguresLine(agentType: record.agentType,
                        figures: Text(word).foregroundStyle(tint)
                            + Text(totals(tokens: record.tokens, toolUses: record.toolUses).map { " · " + $0 }.joined())
                                .foregroundStyle(.secondary))
            if let said = record.summary, !said.isEmpty {
                Text(said).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }
}
