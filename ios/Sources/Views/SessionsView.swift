import SwiftUI

/// Past conversations for one directory, plus "New conversation". Tapping a row
/// resumes that session (Claude Code's --resume); the same sessions show up in
/// desktop Claude Code for the identical path.
struct SessionsView: View {
    let profile: ServerProfile
    let secret: String
    let dir: String

    @EnvironmentObject var store: AppStore
    /// The shared phone-local pin state. Observed (not just read) so a leading
    /// swipe here re-sorts and re-marks the rows immediately — and stays in sync
    /// with the home "Recent" list, which reads the very same store.
    @ObservedObject private var pins: PinStore
    @StateObject private var service: SessionService
    @State private var sessions: [SessionSummary] = []
    /// Groups (双开) in this project — each is one row; its members are
    /// reached through it and never listed loose below.
    @State private var groups: [ChatGroup] = []
    /// Nothing has been read yet: the spinner's only time.
    @State private var loading = true
    /// Reads the list at the page's four times, and again by itself while the
    /// Mac cannot be reached (PageRefresher).
    @StateObject private var refresher = PageRefresher()
    @State private var ticket = LoadTicket()
    @State private var renaming: SessionSummary?
    @State private var renameText = ""
    /// The row whose delete is being confirmed (2026-10-21: a question first).
    @State private var pendingDelete: SessionSummary?

    init(profile: ServerProfile, secret: String, dir: String, pins: PinStore) {
        self.profile = profile
        self.secret = secret
        self.dir = dir
        _pins = ObservedObject(wrappedValue: pins)
        _service = StateObject(wrappedValue: SessionService(profile: profile, secret: secret))
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ChatView(profile: profile, secret: secret, dir: dir)
                } label: {
                    Label("New conversation", systemImage: "plus.bubble")
                }
                NavigationLink {
                    TerminalScreen(profile: profile, secret: secret, dir: dir)
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
            }
            .listRowBackground(Palette.surface)

            Section("History") {
                if refresher.problem != nil {
                    MacProblemRow(problem: refresher.problem, retrying: refresher.retrying,
                                  profile: profile, secret: secret) { refresher.refresh() }
                        .listRowBackground(Palette.surface)
                } else if loading {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                } else if sessions.isEmpty && groups.isEmpty {
                    Text("No conversations here yet.").foregroundStyle(.secondary)
                }
                ForEach(groups) { g in
                    NavigationLink {
                        GroupView(profile: profile, secret: secret, group: g)
                    } label: { GroupRowLabel(group: g) }
                }
                ForEach(sortedSessions) { session in
                    NavigationLink {
                        ChatView(profile: resumeProfile(session), secret: secret, dir: dir, resumeSessionId: session.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(session.agent.iconAsset)
                                .resizable().scaledToFit()
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title).lineLimit(2)
                                if let dirs = session.dirs, !dirs.isEmpty {
                                    // The folders this conversation was handed (writable).
                                    HStack(spacing: 6) {
                                        // A plain pair, not a Label: inside a List row a
                                        // Label lines its icon up with the row's icon column,
                                        // leaving a gap the person read as a space (2026-10-17).
                                        ForEach(dirs.prefix(3), id: \.self) { d in
                                            HStack(spacing: 4) {
                                                Image(systemName: "folder.fill")
                                                Text((d as NSString).lastPathComponent).lineLimit(1)
                                            }
                                            .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Text(session.modifiedDate, format: .relative(presentation: .named))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            // A pinned row wears a small, quiet pin — tertiary so
                            // it marks without shouting (same restraint as the
                            // publication date caption).
                            if pins.isPinned(pinKey(session)) {
                                Spacer(minLength: 4)
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .listRowBackground(Palette.surface)
                    .contextMenu {
                        Button { renameText = session.customTitle ?? ""; renaming = session } label: {
                            Label(L.renameConversation(), systemImage: "pencil.line")
                        }
                    }
                    // Leading swipe = pin/unpin (green, like Workflows' "Run now").
                    // The trailing delete is untouched.
                    .swipeActions(edge: .leading) {
                        Button { pins.togglePin(pinKey(session)) } label: {
                            Label(pins.isPinned(pinKey(session)) ? L.unpin() : L.pin(),
                                  systemImage: pins.isPinned(pinKey(session)) ? "pin.slash.fill" : "pin.fill")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        // A pinned conversation cannot be deleted from here — the
                        // Mac refuses it anyway; unpin first, and the trash returns.
                        if !pins.isPinned(pinKey(session)) {
                            // Not role .destructive: that role removes the row the moment
                            // it is tapped, and with the removal deferred behind the question
                            // the List's counts drift and UIKit aborts (2026-10-21).
                            Button {
                                pendingDelete = session
                            } label: { Label(L.delete(), systemImage: "trash") }
                            .tint(.red)
                            .accessibilityIdentifier("delete-conversation")
                        }
                    }
                }
            }
        }
        .pervioBackground()
        .pervioBar((dir as NSString).lastPathComponent)
        .confirmDeleteConversation($pendingDelete) { delete($0) }
        .alert(L.renameConversation(), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L.renamePrompt(), text: $renameText)
            Button(L.save()) {
                guard let s = renaming else { return }
                let t = renameText
                renaming = nil
                Task {
                    try? await service.rename(session: s.id, title: t)
                    refresher.refresh()
                }
            }
            Button(L.cancel(), role: .cancel) { renaming = nil }
        } message: { Text(L.renamePrompt()) }
        .readsTheMac(refresher) { await read() }
        .onAppear { store.activateRuns(for: profile, secret: secret) }
        .onDisappear { Task { await service.disconnect() } }
        .runPill()
    }

    /// One read of the list, over a connection of its own (see
    /// ProjectsView.read): what was listed before stays until a read brings
    /// the list anew.
    @MainActor
    private func read() async -> PageRefresher.Outcome {
        let mine = ticket.take()
        let svc = SessionService(profile: profile, secret: secret)
        defer { Task { await svc.disconnect() } }
        do {
            // Pin sync rides the list load: replay this scope's outbox first
            // (best-effort — an older server without the verbs must not take
            // the list down), then list, then let the Mac's flags win.
            let plan = pins.flushPlan(profileId: profile.id, dir: dir)
            do {
                if !plan.isEmpty { try await svc.replayPins(dir: dir, plan: plan) }
                pins.markFlushed(profileId: profile.id, dir: dir)
            } catch {
                NSLog("[Pervio] pin replay deferred: %@", String(describing: error))
            }
            let listed = try await svc.sessions(dir: dir)
            let grouped = (try? await svc.groupList(dir: dir)) ?? []
            guard ticket.isLatest(mine) else { return .reached }
            sessions = listed
            groups = grouped
            loading = false
            pins.absorb(listed, profileId: profile.id, dir: dir)
            return .reached
        } catch {
            if ticket.isLatest(mine) { loading = false }
            return .of(error, "Couldn't load conversations.")
        }
    }

    /// The rows as drawn: pinned first (most-recently pinned on top), the rest in
    /// the server's newest-first order. `sessions` itself keeps load order so the
    /// underlying list never mutates out from under a delete.
    private var sortedSessions: [SessionSummary] {
        pins.sortedPinnedFirst(sessions.filter { $0.group == nil }, keyFor: pinKey)
    }

    /// This conversation's pin key — the SAME triple the home Recent list builds,
    /// so a pin here shows there and vice versa.
    private func pinKey(_ session: SessionSummary) -> String {
        PinStore.key(profileId: profile.id, dir: dir, sessionId: session.id)
    }

    /// Resume a row with its own backend, so a Codex conversation reopens as Codex
    /// (not whatever the parent profile currently defaults to).
    private func resumeProfile(_ session: SessionSummary) -> ServerProfile {
        var p = profile
        p.backend = session.agent
        return p
    }

    private func delete(_ session: SessionSummary) {
        sessions.removeAll { $0.id == session.id }   // optimistic
        store.removeParams(for: session.id, on: profile)          // drop this conversation's saved knobs
        Task { try? await service.delete(dir: dir, session: session.id, backend: session.agent) }
    }
}

/// The one question every delete of a conversation asks (2026-10-21, the
/// person's ask — three places could delete, none asked, and the Mac's record
/// is gone for good): names the conversation, Delete in red, Cancel.
struct ConfirmDeleteConversation: ViewModifier {
    @Binding var pending: SessionSummary?
    let perform: (SessionSummary) -> Void
    func body(content: Content) -> some View {
        content.alert(L.deleteConversationAsk(),
                      isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                      presenting: pending) { s in
            Button(L.delete(), role: .destructive) { perform(s) }
            Button(L.cancel(), role: .cancel) {}
        } message: { s in
            Text(L.deleteConversationBody(s.title))
        }
    }
}

extension View {
    func confirmDeleteConversation(_ pending: Binding<SessionSummary?>,
                                   perform: @escaping (SessionSummary) -> Void) -> some View {
        modifier(ConfirmDeleteConversation(pending: pending, perform: perform))
    }
}
