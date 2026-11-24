import Foundation

/// The language of every prompt the APP ITSELF injects into the model: the
/// Build-with-Claude builder seed, the reader/monitor discuss seeds, the 背景
/// attachment scaffolding (frames, provenance headers, ask lines), the
/// directory-handoff guidance, the playbook load prefix, and — via `--lang en`
/// to pervio-chat — the pervio-context discovery pointer the server appends.
///
/// Boundary (deliberate, 2026-08-10):
///  * UI copy is NOT covered — this is a prompt-language setting, not app
///    localization.
///  * Server-side templates (晨报 and the rest of ~/.pervio/templates), the
///    reports they produce, playbook BODIES from the market, and pervio-mcp's
///    tool descriptions stay as authored on the server; switching those is a
///    server-side project, out of this setting's scope.
///  * The default is ENGLISH (2026-09-01, first-run audience went global);
///    Chinese is one tap away in Settings. On the wire the app sends `--lang en` ONLY when
///    non-default (and only alongside `--pervio-context`), so an older
///    pervio-chat — whose parser hard-rejects unknown args — keeps working for
///    every default send: the same ship-together compatibility contract as
///    `--pervio-context` itself.
enum PromptLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh"
    case english = "en"

    var id: String { rawValue }

    /// UserDefaults key (Settings page). Absent = `.english`, the shipped default.
    static let defaultsKey = "pervio.promptLanguage"

    /// Read fresh on every prompt build (prompts are built rarely; caching would
    /// make a Settings change apply only after an app restart).
    static var current: PromptLanguage {
        PromptLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "")
            ?? .english
    }

    /// The picker label — the language names name themselves.
    var displayName: String { self == .chinese ? "中文" : "English" }
}

/// The small conversation-seed prompts, together in one language-aware place so
/// every entry point builds its seed here and a test can pin the wire text
/// byte-for-byte. The Chinese strings are the shipped ones, verbatim.
enum Prompts {
    /// ArchiveReaderView "Discuss with Claude": read this issue first.
    static func readerDiscuss(dir: String, file: String,
                              language: PromptLanguage = .current) -> String {
        switch language {
        case .chinese:
            return "请先读 \(dir)/\(file) 这期报告,读完等我提问。我的问题:"
        case .english:
            return "Please read this issue of the report first: \(dir)/\(file). "
                 + "When you have read it, wait for my questions. My question:"
        }
    }

    /// WorkflowMonitorView "Discuss": read this run's ledger first.
    static func monitorDiscuss(title: String, wfId: String,
                               language: PromptLanguage = .current) -> String {
        switch language {
        case .chinese:
            return "请先读工作流「\(title)」(run \(wfId))的账本 ~/.pervio/wf/\(wfId)/ledger.json,了解各步骤输出,读完等我提问。我的问题:"
        case .english:
            return "Please read the ledger of the workflow \"\(title)\" (run \(wfId)) "
                 + "at ~/.pervio/wf/\(wfId)/ledger.json first to understand each step's "
                 + "output, then wait for my questions. My question:"
        }
    }
}
