import SwiftUI

/// Path completion over the Mac's real directories, pure so a test can pin it.
/// `typed` is what the person has so far ("~/Doc", "/srv/", ""): the part up to
/// the last "/" is the directory to list, the rest the prefix to match
/// (case-insensitively) against that directory's sub-folders. Files never
/// complete — this picks a working directory.
enum DirAutocomplete {
    /// (directory to list, prefix to match). "" lists the home.
    static func split(_ typed: String) -> (parent: String, prefix: String) {
        let t = typed.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return ("~", "") }
        if t.hasSuffix("/") { return (t.count > 1 ? String(t.dropLast()) : t, "") }
        if let slash = t.lastIndex(of: "/") {
            let parent = String(t[..<slash])
            return (parent.isEmpty ? "/" : parent, String(t[t.index(after: slash)...]))
        }
        return (t == "~" ? "~" : "~", t == "~" ? "" : t)     // "Doc" → under home
    }

    /// Completions in the TYPED spelling ("~/Documents/"), one level deeper,
    /// directories only, prefix-matched, listing order kept.
    static func completions(typed: String, entries: [ServerFileEntry], limit: Int = 8) -> [String] {
        let (parent, prefix) = split(typed)
        let base = parent == "/" ? "" : parent
        return entries
            .filter { $0.isDir && !$0.name.hasPrefix(".") && (prefix.isEmpty || $0.name.lowercased().hasPrefix(prefix.lowercased())) }
            .prefix(limit)
            .map { base + "/" + $0.name + "/" }
    }
}

/// A path field that completes as you type: 250 ms after the last keystroke it
/// lists the typed directory's parent on the Mac and shows the matching
/// sub-folders as chips; a tap fills that level and the next listing starts.
struct DirAutocompleteField: View {
    @Binding var text: String
    @ObservedObject var service: SessionService
    var placeholder: String = "~/path/to/project"
    /// The server's scope: a parent outside it lists nothing, so no chip can
    /// lead out of it. nil = unfenced (the server form's own directory field).
    var fence: String? = nil
    @State private var chips: [String] = []
    @State private var listedParent = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(placeholder, text: $text)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .keyboardType(.URL)
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { c in
                            Button { text = c } label: {
                                Text((c as NSString).lastPathComponent + "/")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Palette.surface2, in: Capsule())
                                    .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let (parent, _) = DirAutocomplete.split(text)
            // One listing per parent directory; a new prefix under the same
            // parent is filtered locally, no extra round trip.
            if parent != listedParent || chips.isEmpty {
                guard let listing = try? await service.listDir(parent, under: fence), listing.error == nil else { chips = []; return }
                listedParent = parent
                lastEntries = listing.entries ?? []
            }
            chips = DirAutocomplete.completions(typed: text, entries: lastEntries)
        }
    }
    @State private var lastEntries: [ServerFileEntry] = []
}

/// Pick a working directory on the Mac: recent projects, a completing path
/// field, or the real file browser. One sheet, used by the server page, the
/// chat's directory chip and the home page's New-chat long-press.
struct DirectoryPickerSheet: View {
    let profile: ServerProfile
    let secret: String
    let startPath: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service: SessionService
    @State private var typed = ""
    @State private var recent: [ProjectInfo] = []
    @State private var loadedRecent = false
    @State private var typedNote: String?
    @State private var checking = false

    /// Every pick stays inside the server's scope: the browser is fenced, the
    /// completions are fenced, a typed path is checked on the Mac before it is
    /// used, and the recent list is the scoped project list.
    private var fence: String { profile.scopeDir }

    init(profile: ServerProfile, secret: String, startPath: String, onPick: @escaping (String) -> Void) {
        self.profile = profile
        self.secret = secret
        self.startPath = startPath
        self.onPick = onPick
        _service = StateObject(wrappedValue: SessionService(profile: profile, secret: secret))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ServerFileBrowser(service: service, startPath: startPath,
                                          onPickFile: { f in pick((f as NSString).deletingLastPathComponent) },
                                          onHandoffDir: { d in pick(d) },
                                          dirActionLabel: L.dirUseThis(), fence: fence)
                    } label: {
                        Label(L.dirBrowseMac(), systemImage: "folder.badge.gearshape")
                    }
                }
                Section {
                    DirAutocompleteField(text: $typed, service: service, fence: fence)
                    Button { useTyped() } label: { Label(checking ? "…" : L.dirUseThis(), systemImage: "checkmark.circle") }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                    if let typedNote { Text(typedNote).font(.caption).foregroundStyle(.orange) }
                } header: {
                    Text(L.dirTypePath())
                } footer: {
                    Text(L.dirTypeHint())
                }
                Section(L.dirRecent()) {
                    if !loadedRecent {
                        HStack { ProgressView(); Text("…").foregroundStyle(.secondary) }
                    } else if recent.isEmpty {
                        Text("—").foregroundStyle(.secondary)
                    }
                    ForEach(recent) { p in
                        Button { pick(p.path) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((p.path as NSString).lastPathComponent).foregroundStyle(.primary)
                                    Text(p.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if p.path == startPath {
                                    Text(L.dirDefaultTag()).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .pervioBar(L.dirChooseTitle(), back: false)
            .toolbar {
                BarItem(.cancellationAction) { BarWord(text: L.cancel()) { dismiss() } }
            }
            .task {
                recent = ((try? await service.projects()) ?? []).sorted { $0.modified > $1.modified }
                loadedRecent = true
            }
            .onDisappear { Task { await service.disconnect() } }
        }
    }

    /// A typed path is asked of the Mac first: it must exist, be a folder, and
    /// sit inside the scope — the fence is enforced there, not guessed here.
    private func useTyped() {
        let p = typed.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        checking = true
        Task {
            defer { checking = false }
            guard let listing = try? await service.listDir(p, under: fence) else {
                typedNote = L.directoryReadFailed(); return
            }
            if let code = listing.error { typedNote = SSHService.serverFsErrorText(code); return }
            typedNote = nil
            pick(p)
        }
    }

    private func pick(_ path: String) {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        Haptics.tick()
        onPick(p)
        dismiss()
    }
}
