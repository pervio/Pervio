import SwiftUI

// MARK: - Playbook detail (market)

/// Full preview of a playbook template (kind == "playbook" in the server's
/// template library): the methodology markdown itself, plus its ONE verb —
/// 在对话中用, which opens a chat with the fixed load prefix + body prefilled
/// in the composer. Never auto-sent. pervioContext comes ON (wf-born style):
/// the 取背景 playbook reads other projects' memories and the personal map,
/// which live OUTSIDE the project dir — the server grants that read surface
/// (--add-dir) only on chip-on conversations, so a playbook chat without the
/// chip would hard-block on its very first read in plan/acceptEdits (probed).
/// There is deliberately no editor, no subscribe and no run here: the server
/// refuses to start a playbook as a workflow, and this page mirrors that.
struct PlaybookDetailView: View {
    let template: ServerTemplate
    let profile: ServerProfile
    let secret: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                natureCard
                specWarnings
                bodySection
                useButton
            }
            .padding(16)
        }
        .background(Palette.bg.ignoresSafeArea())
        .pervioBar(template.name.isEmpty ? template.file : template.name)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L.chipPlaybook())
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.surface2, in: Capsule())
                    .foregroundStyle(.tint)
                if let n = template.body?.count {
                    Text(L.charCount(n)).font(.caption2).foregroundStyle(.secondary)
                }
                if let d = template.mtimeDate {
                    Text(d, format: .relative(presentation: .named))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let s = template.summary, !s.isEmpty {
                Text(s).font(.subheadline).foregroundStyle(.primary)
            }
        }
    }

    /// What a playbook IS (and isn't) — the risk-acknowledgement toggle the
    /// workflow detail page shows is deliberately absent: pure text has no
    /// run-command surface. What it does carry is your first message, so the
    /// card says exactly that.
    private var natureCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L.playbookNature(), systemImage: "text.book.closed")
                .font(.caption).foregroundStyle(.green)
            Text(L.playbookUseExplainer())
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Defensive: a playbook has no spec by contract, but if a wrapper smuggles
    /// one in anyway, the SAME warnings engine that guards workflow imports
    /// still gets its say — the ack toggle is waived, the warnings are not.
    @ViewBuilder private var specWarnings: some View {
        if let spec = template.spec {
            let warnings = WorkflowMarketItem.wrapping(spec: spec).warnings
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L.playbookSmuggledSteps(), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    ForEach(warnings, id: \.self) { w in
                        Text("• \(w)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder private var bodySection: some View {
        if let body = template.body, !body.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.bodyLabel()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                RichMessageText(text: body, streaming: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder private var useButton: some View {
        if let text = template.playbookLoadText {
            NavigationLink {
                ChatView(profile: profile, secret: secret, initialInput: text,
                         pervioContext: true)
            } label: {
                Label(L.useInChat(), systemImage: "bubble.left.and.text.bubble.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Palette.accent.opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 12))
            }
            Text(L.playbookUseFooter())
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
