import SwiftUI

/// Lists the server's projects (directories Claude Code has history for) and
/// lets the user open an arbitrary directory. Tapping a project drills into its
/// past conversations.
struct ProjectsView: View {
    let profile: ServerProfile
    let secret: String

    @EnvironmentObject var store: AppStore
    @StateObject private var service: SessionService
    @State private var projects: [ProjectInfo] = []
    /// Nothing has been read yet: the spinner's only time.
    @State private var loading = true
    /// Reads the list at the page's four times, and again by itself while the
    /// Mac cannot be reached (PageRefresher).
    @StateObject private var refresher = PageRefresher()
    @State private var ticket = LoadTicket()
    @State private var customDir = ""
    @State private var showDirPicker = false
    @State private var checkingDir = false
    @State private var typedNote: String?
    /// A directory picked from the browser: pushed into its sessions page.
    @State private var pickedDir: PickedDir?
    private struct PickedDir: Identifiable, Hashable { let path: String; var id: String { path } }

    /// The saved default (the row with the tag), read live so "set as
    /// default" updates the tag at once.
    private var defaultDir: String {
        store.profiles.first { $0.id == profile.id }?.projectDir ?? profile.projectDir
    }

    init(profile: ServerProfile, secret: String) {
        self.profile = profile
        self.secret = secret
        _service = StateObject(wrappedValue: SessionService(profile: profile, secret: secret))
    }

    private func setDefault(_ dir: String) {
        guard var p = store.profiles.first(where: { $0.id == profile.id }) else { return }
        p.projectDir = dir
        store.upsert(p, secret: nil)
        Haptics.tick()
    }

    var body: some View {
        List {
            Section("Open a directory") {
                // Browse the Mac (the same browser the composer's Mac-file pick
                // uses), or type with completions — nobody spells a path by hand.
                Button { showDirPicker = true } label: {
                    Label(L.dirBrowseMac(), systemImage: "folder.badge.gearshape")
                }
                .listRowBackground(Palette.surface)
                HStack(alignment: .top) {
                    DirAutocompleteField(text: $customDir, service: service, placeholder: "~/path/to/project",
                                         fence: profile.scopeDir)
                    // Checked on the Mac before it opens: exists, is a folder,
                    // and sits inside this server's scope.
                    Button(checkingDir ? "…" : "Open") { openTyped() }
                        .disabled(customDir.trimmingCharacters(in: .whitespaces).isEmpty || checkingDir)
                }
                .listRowBackground(Palette.surface)
                if let typedNote {
                    Text(typedNote).font(.caption).foregroundStyle(.orange)
                        .listRowBackground(Palette.surface)
                }
            }

            Section("Workflows") {
                NavigationLink {
                    WorkflowsView(profile: profile, secret: secret)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.tint).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Multi-step workflows").font(.headline)
                            Text("Chain Claude & Codex across steps")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Palette.surface)
            }

            Section("Projects with history") {
                if refresher.problem != nil {
                    MacProblemRow(problem: refresher.problem, retrying: refresher.retrying,
                                  profile: profile, secret: secret) { refresher.refresh() }
                        .listRowBackground(Palette.surface)
                } else if loading {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                } else if projects.isEmpty {
                    Text("No projects found yet.").foregroundStyle(.secondary)
                }
                ForEach(projects) { project in
                    NavigationLink {
                        SessionsView(profile: profile, secret: secret, dir: project.path,
                                     pins: store.pins)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.tint).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text((project.path as NSString).lastPathComponent).font(.headline)
                                    if project.path == defaultDir {
                                        Text(L.dirDefaultTag()).font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Palette.accent.opacity(0.18), in: Capsule())
                                            .foregroundStyle(Palette.accent)
                                    }
                                }
                                Text("\(project.sessions) conversations · \(project.path)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .listRowBackground(Palette.surface)
                    // Long-press: make this the server's default directory —
                    // where New chat lands. Saved on the profile, keychain untouched.
                    .contextMenu {
                        Button { setDefault(project.path) } label: { Label(L.dirSetDefault(), systemImage: "pin") }
                    }
                }
            }
        }
        .pervioBackground()
        .sheet(isPresented: $showDirPicker) {
            DirectoryPickerSheet(profile: profile, secret: secret, startPath: defaultDir) { d in
                showDirPicker = false
                pickedDir = PickedDir(path: d)
            }
        }
        .navigationDestination(item: $pickedDir) { p in
            SessionsView(profile: profile, secret: secret, dir: p.path, pins: store.pins)
        }
        .pervioBar(profile.name)
        .readsTheMac(refresher) { await read() }
        .onAppear { store.activateRuns(for: profile, secret: secret) }   // keep the runs pill alive for this server
        .onDisappear { Task { await service.disconnect() } }   // NOTE: don't stop the monitor here — pushing
                                                               // deeper fires onDisappear; the server list stops it
        .runPill()
    }

    private func openTyped() {
        let p = customDir.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        checkingDir = true
        Task {
            defer { checkingDir = false }
            guard let listing = try? await service.listDir(p, under: profile.scopeDir) else {
                typedNote = L.directoryReadFailed(); return
            }
            if let code = listing.error { typedNote = SSHService.serverFsErrorText(code); return }
            typedNote = nil
            pickedDir = PickedDir(path: p)
        }
    }

    /// One read of the list, over a connection of its own: the page's standing
    /// one (`service`) serves what the person does on the page, and two reads
    /// overlapping on it — a slow one and its retry — would dial it twice.
    /// What was listed before stays until a read brings the list anew.
    @MainActor
    private func read() async -> PageRefresher.Outcome {
        let mine = ticket.take()
        let svc = SessionService(profile: profile, secret: secret)
        defer { Task { await svc.disconnect() } }
        do {
            let listed = try await svc.projects()
            if ticket.isLatest(mine) { projects = listed; loading = false }
            return .reached
        } catch {
            if ticket.isLatest(mine) { loading = false }
            return .of(error, "Couldn't load projects.")
        }
    }
}
