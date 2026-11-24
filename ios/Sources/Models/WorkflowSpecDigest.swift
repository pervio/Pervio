import Foundation

/// What a workflow would DO — the rows the Allow/Deny sheet shows before one is
/// started from a conversation (security reviews 2026-11-18 #2, 2026-11-22 #2).
///
/// The sheet used to show only the spec's name, which is whatever the model
/// chose to call it: a person approving 「整理一下笔记」 could not see that a step
/// held full permissions, that it ran in another directory, or that the Mac's
/// shell would run a line of the model's own writing. And for a template
/// started by name, a named tool or a past run run again, it showed the name
/// and nothing else.
///
/// The bytes read here are the Mac's: its approval tool resolves the call —
/// template looked up, parameters filled in — and sends the workflow as it
/// would run (`ToolCall.shownSpec`); the start then goes ahead only if what it
/// is about to run is exactly that. Nothing the model says ABOUT a workflow is
/// taken on trust.
///
/// One rule keeps it honest: what cannot be shown whole cannot be allowed. A
/// spec the phone cannot decode, a shell line too long to put on the sheet, a
/// workflow with more rows than a person would read — `readable` is false, the
/// sheet says why, and Allow is off.
enum WorkflowSpecDigest {
    /// The most characters of ONE shell line the sheet will show — all of them,
    /// or the workflow cannot be allowed.
    static let lineCap = 6000
    /// The most rows; past it the workflow cannot be allowed.
    static let rowCap = 400

    struct Digest {
        var rows: [(String, String)] = []
        /// Everything the workflow would do is on the sheet.
        var readable = true
        /// Why not, in the person's language.
        var problem: String?
    }

    static func rows(b64: String, lang: PromptLanguage = .current) -> [(String, String)] {
        read(b64: b64, lang: lang).rows
    }

    /// `own`: the model wrote this spec itself (it is "custom"); false for a
    /// saved template, a named tool or a past run the Mac looked up.
    static func read(b64: String, lang: PromptLanguage = .current, own: Bool = true) -> Digest {
        // Strict, like the Mac's own reading of a spec the model submits
        // (pervio-mcp `_spec_from_b64`): no stray whitespace, no missing
        // padding. Two readers that disagreed were how a sheet came to show a
        // size while the Mac ran the workflow.
        guard let data = Data(base64Encoded: b64),
              let spec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return Digest(rows: [("Spec", L.permSpecSize(b64.count, lang))], readable: false,
                          problem: L.permSpecUnreadable(lang))
        }
        var d = Digest()
        func runs(_ line: String) -> String {
            if line.count > lineCap {
                d.readable = false
                d.problem = L.permSpecTooLong(lang)
                return L.permSpecRuns(String(line.prefix(lineCap)) + " …(+\(line.count - lineCap))", lang)
            }
            return L.permSpecRuns(line, lang)
        }
        let name = (spec["name"] as? String) ?? ""
        d.rows.append(("Spec", name.isEmpty ? L.permSpecSize(b64.count, lang)
                               : own ? L.permSpecNamed(name, lang) : L.permSpecSaved(name, lang)))
        // No directory named: the runner works in the home directory.
        d.rows.append((L.permLabelDir(lang), text(spec["dir"]) ?? "~"))
        if let setup = text(spec["setup"]) { d.rows.append((L.permSpecBefore(lang), runs(setup))) }

        let steps = (spec["steps"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        for s in steps {
            let label = L.permSpecStep((s["id"] as? String) ?? "?", lang)
            let dir = text(s["dir"]).map { " · \($0)" } ?? ""
            if let command = text(s["command"]) {
                d.rows.append((label, runs(command) + dir))
            } else {
                let backend = (s["backend"] as? String) ?? "claude"
                let tier = backend == "codex" ? ((s["sandbox"] as? String) ?? "workspace-write")
                                              : ((s["perm"] as? String) ?? "default")
                d.rows.append((label, "\(backend) · \(tierWords(tier, lang))" + dir))
            }
            for key in ["setup", "verify"] {
                if let line = text(s[key]) { d.rows.append((label, runs(line) + " (\(key))")) }
            }
            // A published step's output is a file the Mac itself writes.
            if let target = text(s["publish"]) {
                d.rows.append((label, L.permSpecPublishes(target, lang)))
            } else if (s["publish"] as? Bool) == true {
                d.rows.append((label, L.permSpecPublishes(L.permSpecShelf(lang), lang)))
            }
        }
        for a in (spec["actions"] as? [Any])?.compactMap({ $0 as? [String: Any] }) ?? [] {
            if let run = text(a["run"]) { d.rows.append((L.permSpecMenu(lang), runs(run))) }
        }
        if d.rows.count > rowCap {
            d.rows = Array(d.rows.prefix(rowCap))
            d.readable = false
            d.problem = L.permSpecTooMany(lang)
        }
        return d
    }

    /// A step's permission in plain words, with the engine's own word kept so
    /// it can be looked up. An unknown word is shown as it is.
    static func tierWords(_ tier: String, _ lang: PromptLanguage = .current) -> String {
        switch tier {
        case "plan", "read-only":                        return L.permTierRead(lang) + " (\(tier))"
        case "default":                                  return L.permTierAsk(lang) + " (\(tier))"
        case "acceptEdits", "dontAsk", "workspace-write": return L.permTierWrite(lang) + " (\(tier))"
        case "auto":                                     return L.permTierAuto(lang) + " (\(tier))"
        case "bypassPermissions", "danger-full-access":  return L.permTierFull(lang) + " (\(tier))"
        default:                                         return tier
        }
    }

    /// The same scale the Mac holds a spec to (pervio-mcp / _pervio_lib.tier_power);
    /// a word neither knows counts as the most.
    static func power(_ tier: String) -> Int {
        switch tier {
        case "plan", "default", "read-only": return 0
        case "acceptEdits", "dontAsk", "auto", "workspace-write": return 1
        default: return 2
        }
    }

    private static func text(_ v: Any?) -> String? {
        guard let s = v as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
