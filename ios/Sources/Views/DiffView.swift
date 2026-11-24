import SwiftUI

/// Detail shown when a tool chip is tapped: a line-by-line diff for Edit, the
/// new contents for Write, or the command for Bash.
struct ToolDetailView: View {
    @State var call: ToolCall
    /// Lazily fetches the detail for a history turn (live turns already have it).
    var fetch: (ToolCall) async -> ToolCall = { $0 }
    @State private var loading = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {                       // vertical only — long lines wrap to fit the phone
                detail
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.bg)
            .pervioBar(title, back: false)
            .toolbar {
                BarItem(.confirmationAction) { BarWord(text: L.done(), weight: .semibold) { dismiss() } }
            }
            .task {
                // History turns ship only a label + tool_use id; fetch the diff now.
                if !call.hasDetail, call.toolUseId != nil {
                    loading = true
                    call = await fetch(call)
                    loading = false
                }
            }
        }
    }

    private var title: String {
        if let fp = call.filePath, !fp.isEmpty {
            return "\(call.name) · \((fp as NSString).lastPathComponent)"
        }
        return call.name
    }

    @ViewBuilder private var detail: some View {
        if loading {
            HStack(spacing: 8) { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity).padding(.top, 30)
        } else if let old = call.oldString, let new = call.newString {
            DiffView(old: old, new: new)
        } else if let content = call.content {
            DiffView(old: "", new: content)          // a written/overwritten file = all-new
        } else if let command = call.command {
            Text(command)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Color(white: 0.88))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("No detail available.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A simple unified line diff (LCS), red for removals / green for additions.
struct DiffView: View {
    let old: String
    let new: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(computeLineDiff(old: old, new: new)) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text(sign(line.kind))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(signColor(line.kind))
                        .frame(width: 9, alignment: .leading)
                    // Syntax-highlighted code; leading whitespace (indentation) is
                    // preserved by the monospaced attributed string.
                    Text(SyntaxHighlighter.highlight(line.text.isEmpty ? " " : line.text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(background(line.kind))
            }
        }
    }

    private func sign(_ k: DiffLineKind) -> String {
        switch k { case .add: return "+"; case .remove: return "-"; case .same: return " " }
    }
    private func signColor(_ k: DiffLineKind) -> Color {
        switch k {
        case .add: return Color(red: 0.55, green: 0.85, blue: 0.55)
        case .remove: return Color(red: 0.95, green: 0.55, blue: 0.55)
        case .same: return Color(white: 0.5)
        }
    }
    private func background(_ k: DiffLineKind) -> Color {
        switch k {
        case .add: return Color.green.opacity(0.16)
        case .remove: return Color.red.opacity(0.16)
        case .same: return .clear
        }
    }
}

enum DiffLineKind { case same, add, remove }
struct DiffLine: Identifiable { let id = UUID(); let kind: DiffLineKind; let text: String }

/// Line-level LCS diff. Caps huge inputs (e.g. a whole rewritten file) to a flat
/// remove-then-add so the O(n·m) table never blows up.
func computeLineDiff(old: String, new: String) -> [DiffLine] {
    let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
    let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
    let cap = 600
    if a.count > cap || b.count > cap {
        return a.map { DiffLine(kind: .remove, text: $0) } + b.map { DiffLine(kind: .add, text: $0) }
    }
    let n = a.count, m = b.count
    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    if n > 0 && m > 0 {
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
    }
    var out: [DiffLine] = []
    var i = 0, j = 0
    while i < n && j < m {
        if a[i] == b[j] { out.append(DiffLine(kind: .same, text: a[i])); i += 1; j += 1 }
        else if dp[i + 1][j] >= dp[i][j + 1] { out.append(DiffLine(kind: .remove, text: a[i])); i += 1 }
        else { out.append(DiffLine(kind: .add, text: b[j])); j += 1 }
    }
    while i < n { out.append(DiffLine(kind: .remove, text: a[i])); i += 1 }
    while j < m { out.append(DiffLine(kind: .add, text: b[j])); j += 1 }
    return out
}
