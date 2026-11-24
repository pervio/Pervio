import SwiftUI

/// The two pieces of chrome that make "this workflow prints a home card"
/// visible, shared by every screen that has to say it: a chip for list rows
/// (market shelves, the Workflows screen's subscriptions) and the editor's
/// top-level block.
///
/// Both are built from `Palette` and the same 刊物 wording/icon as the market's
/// publication shelf — one vocabulary, so a badge on a row and the shelf it came
/// from obviously mean the same thing.

/// Row chip: 刊物, in the same capsule style as the existing 我的 / 剧本 chips.
struct PublicationChip: View {
    var body: some View {
        Label(PublicationTarget.badge, systemImage: "sunrise.fill")
            .font(.caption2.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Palette.surface2, in: Capsule())
            .foregroundStyle(.tint)
    }
}

/// The editor's top-level block: a highlighted card that says the workflow
/// prints a home card and where its issues are archived.
///
/// It exists because the only switch is `Publish as home card`, inside ONE
/// step's detail page — the user found it by hunting, and until they did,
/// nothing anywhere told them the workflow they were editing feeds the home
/// screen. Same card idiom as the market detail page's safety block.
struct PublicationNoticeCard: View {
    let notice: PublicationNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L.publicationCardTitle(), systemImage: "sunrise.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Palette.accent)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(notice.archiveDir)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }

    private var detail: String {
        let where_ = L.publicationCardWhere()
        return notice.stepId.isEmpty
            ? where_
            : L.publicationCardStep(notice.stepId) + where_
    }
}
