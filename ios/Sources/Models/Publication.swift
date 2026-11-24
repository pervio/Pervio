import Foundation

/// Everything the app needs to SAY "this workflow prints a home card", in one
/// place: where the issues land, what time a subscription arms at, and the one
/// word the badge uses.
///
/// It exists because the fact was invisible. The only switch is `publish` on a
/// single step, buried behind that step's detail page — the editor's top level,
/// the workflow list and the market rows all said nothing, so the user found the
/// toggle by hunting. Every surface that now shows it reads from here, so they
/// can't drift into saying three different things about the same workflow.
enum PublicationTarget {
    /// Where `publish: true` archives issues, mirroring the server's default.
    static let root = "~/.pervio/archives"

    /// The time a one-tap 订阅 arms when the template suggests none. The market
    /// button, the detail copy and `subscribe()` all read THIS — a row that
    /// promises 06:30 while the schedule fires at some other hour is a
    /// subscription the user stops trusting.
    static let defaultDailyTime = "06:30"

    /// The badge word, identical to the market's 刊物 shelf so a badge on a row
    /// and a shelf heading mean the same thing. Reads `L` so it follows the app
    /// language — one source, so every 刊物 chip (market, Workflows list, editor
    /// step row) switches together.
    static var badge: String { L.publicationBadge() }

    /// The server's `_publish_slug`, mirrored: lowercased, every run of
    /// non-alphanumerics collapsed to one "-", edges trimmed, nothing left →
    /// "workflow".
    ///
    /// Unicode-aware ON PURPOSE. `SSHService.templateSlug` (used for template
    /// FILENAMES) is ASCII-only and answers "workflow" for every Chinese name;
    /// borrowing it here would print "issues land in ~/.pervio/archives/workflow"
    /// under a workflow whose issues actually land in ~/.pervio/archives/论文晨报
    /// — a claim the user can check, and find wrong.
    static func slug(_ name: String) -> String {
        var out = ""
        var lastDash = true          // suppresses a leading dash
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "workflow" : out
    }

    /// Where this workflow's dated issues are written: the publishing step's own
    /// directory when it names one, else the server's per-workflow default.
    static func archiveDir(workflowName: String, publishDir: String?) -> String {
        let custom = (publishDir ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return root + "/" + slug(workflowName)
    }
}

/// The publication a spec (or an editor draft) produces: which step prints it
/// and where the issues are kept. `nil` everywhere means "this workflow prints
/// no card" — never a guess, never a default-shaped placeholder.
struct PublicationNotice: Equatable {
    /// The step whose output becomes the issue. Empty for the legacy
    /// `display.archiveDir` form, which names a directory but no step.
    let stepId: String
    /// Where dated issues land, as the user would type it ("~/…").
    let archiveDir: String
    /// True when the directory was declared (step `publish: "<dir>"` or the
    /// legacy key) rather than derived from the workflow's name.
    let isCustomDir: Bool
}

extension WorkflowSpec {
    /// This spec's publication, or nil. Kept in lockstep with `publishes` (the
    /// market's shelf judgment): both read the same two sources, a step-level
    /// `publish` first and the legacy `display.archiveDir` after, so a workflow
    /// can never sit on the 刊物 shelf while the editor claims it prints nothing.
    var publicationNotice: PublicationNotice? {
        if let s = steps.first(where: { $0.publishEnabled }) {
            let custom = (s.publishDir ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return PublicationNotice(
                stepId: s.id,
                archiveDir: PublicationTarget.archiveDir(workflowName: name,
                                                         publishDir: custom),
                isCustomDir: !custom.isEmpty)
        }
        let legacy = (display?.archiveDir ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !legacy.isEmpty {
            return PublicationNotice(stepId: "", archiveDir: legacy, isCustomDir: true)
        }
        return nil
    }
}
