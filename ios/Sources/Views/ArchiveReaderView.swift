import SwiftUI
import UIKit

/// Reader for one "publication" — a workflow that declared `display.archiveDir`.
/// Issues are the dated *.md files the server listed (newest first); the spec's
/// presentation contract (collapse hints + long-press actions) renders each one
/// exactly like the workflow monitor renders results. Unlike the home page,
/// the reader IS allowed to show errors — you asked for this issue, so a
/// failure to load it must say so.
struct ArchiveReaderView: View {
    let profile: ServerProfile
    let secret: String
    let publication: ArchivePublication
    @StateObject private var store: ArchiveReaderStore
    /// Index into publication.files (0 = newest). ◀ moves to older issues
    /// (index + 1), ▶ back toward the latest (index − 1).
    @State private var index = 0
    @State private var actionToast: String?
    @State private var actionError: String?
    /// The loopback address pervio-view printed, once the user asked for it.
    /// Presented for READING — the phone never opens anything, and neither does
    /// the server: the human types/pastes it into the browser themselves.
    @State private var desktopURL: String?
    @State private var desktopBusy = false

    init(profile: ServerProfile, secret: String, publication: ArchivePublication,
         previewContent: String? = nil) {
        self.profile = profile
        self.secret = secret
        self.publication = publication
        // `previewContent` is a test-only seam (default nil = the shipped path):
        // it pre-seeds the issue body so a snapshot test can render the top bar +
        // a real morning report WITHOUT an SSH connection. When set, `read()`
        // no-ops, so the on-appear `.task` below can't overwrite the seeded body.
        _store = StateObject(wrappedValue:
            ArchiveReaderStore(profile: profile, secret: secret, previewContent: previewContent))
    }

    private var files: [ArchiveFile] { publication.files }
    private var current: ArchiveFile? {
        files.indices.contains(index) ? files[index] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            dateBar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg.ignoresSafeArea())
        // Page-turn by swipe. DragGesture over TabView(.page): the issues load
        // lazily over SSH, and a paged TabView wants every neighbour view alive
        // (prefetch + three connections' worth of state) — a plain horizontal
        // drag on the one visible issue is simpler and can't half-swipe into a
        // blank page. simultaneousGesture so the vertical ScrollView keeps
        // scrolling normally; the guard only fires on a clearly-horizontal flick.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { v in
                guard abs(v.translation.width) > 60,
                      abs(v.translation.width) > abs(v.translation.height) * 2
                else { return }
                if v.translation.width > 0 { older() } else { newer() }
            })
        .pervioBar(publication.name.isEmpty ? "Publication" : publication.name)
        .toolbar {
            BarItem(.navigationBarTrailing) {
                HStack(spacing: 2) {
                    if desktopBusy {
                        ProgressView().frame(width: 30, height: 30)
                    } else {
                        BarGlyph(systemImage: "desktopcomputer", tint: Palette.accent, label: L.openOnComputer()) { askForDesktopURL() }
                            .disabled(current == nil)
                    }
                    NavigationLink {
                        ChatView(profile: profile, secret: secret,
                                 initialInput: discussPrompt,
                                 pervioContext: true)   // wf-born: workflows context on by birth
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.body.weight(.medium)).foregroundStyle(Palette.accent)
                            .frame(width: 30, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Discuss with Claude")
                    .disabled(current == nil)
                }
            }
        }
        .task(id: current?.file) {
            guard let f = current else { return }
            store.registerFigureLane()      // SSH fast lane for embedded figures
            await store.read(dir: publication.dir, file: f.file)
        }
        .actionFeedback(toast: $actionToast, error: $actionError)
        .sheet(isPresented: Binding(get: { desktopURL != nil },
                                    set: { if !$0 { desktopURL = nil } })) {
            DesktopAddressSheet(url: desktopURL ?? "")
        }
        .onDisappear { store.stop(); store.unregisterFigureLane() }
    }

    // MARK: date bar

    private var dateBar: some View {
        HStack {
            Button { older() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(index >= files.count - 1)
            Spacer()
            Text(current.map { issueTitle($0.file) } ?? "—")
                .font(.headline)
            Spacer()
            Button { newer() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(index <= 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func older() {
        guard index < files.count - 1 else { return }
        index += 1
    }

    private func newer() {
        guard index > 0 else { return }
        index -= 1
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        if files.isEmpty {
            Spacer()
            Text("No issues yet.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        } else if store.loading {
            Spacer()
            ProgressView()
            Spacer()
        } else if let err = store.errorText {
            ScrollView {
                Text(err).font(.caption).foregroundStyle(.red)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ScrollView { reportBody }
        }
    }

    /// The rendered issue, split out of `content` so a snapshot can render it
    /// WITHOUT the enclosing `ScrollView` — `ImageRenderer` rasterizes a
    /// `ScrollView` as EMPTY (its content is laid out lazily and never drawn), so
    /// a snapshot of the whole reader shows only the fixed `dateBar` and a blank
    /// page. Pinning THIS (the exact `RichMessageText` the reader scrolls) inside
    /// a fixed frame gives the report body real pixels to compare. `content` still
    /// wraps it in the ScrollView, so the shipped reader is unchanged.
    @ViewBuilder var reportBody: some View {
        RichMessageText(text: store.content, streaming: false,
                        reportStyle: true,
                        collapseSections: publication.display?.collapseSections ?? [],
                        actions: publication.actions ?? [],
                        onAction: { fireAction($0) })
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A report that links its own figures/PDFs by Mac path opens them
            // in the same QuickLook preview the chat uses.
            // Actions created once for the page (LinkRouter.swift): a closure
            // written here would be a new environment value on every body, and
            // every text view of a long report would re-render with it.
            .environment(\.openServerFile, links.openServerFile)
            .environment(\.openURL, links.openURL)
            .sheet(item: $links.previewFile) { target in
                ServerFilePreview(profile: profile, secret: secret, path: target.path)
            }
    }
    /// Mac-file links preview; every other link stays with the system.
    @StateObject private var links = LinkRouter(webPreview: false)

    /// Same feedback pipeline as the workflow monitor: tick + toast the written
    /// line on success, alert on failure. Fire-and-forget from the menu button.
    private func fireAction(_ command: String) {
        Task {
            do {
                let out = try await store.runAdhoc(command)
                Haptics.tick()
                withAnimation(.easeOut(duration: 0.2)) { actionToast = actionFeedbackLine(out) }
            } catch {
                actionError = pervioErrorText(error, "Couldn't run the action on the server.")
            }
        }
    }

    /// Ask the server to render THIS issue for a real screen. All this does on
    /// the phone is show the address that comes back — no window is raised
    /// anywhere, and the server closes itself when nobody reads it.
    private func askForDesktopURL() {
        guard let f = current, !desktopBusy else { return }
        desktopBusy = true
        Task {
            defer { desktopBusy = false }
            do {
                let url = try await store.startDesktopView(dir: publication.dir,
                                                           file: f.file)
                Haptics.tick()
                desktopURL = url
            } catch {
                actionError = pervioErrorText(
                    error, "Couldn't prepare the desktop view on the server.")
            }
        }
    }

    private var discussPrompt: String {
        Prompts.readerDiscuss(dir: publication.dir, file: current?.file ?? "")
    }
}

/// The handoff screen: one address, big enough to read across a desk and one tap
/// to copy. Deliberately inert — there is no button here that makes anything
/// appear on the computer; the human decides when to look.
private struct DesktopAddressSheet: View {
    let url: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            Text(L.desktopReady())
                .font(.headline)
                .multilineTextAlignment(.center)
            SelectableText(plain: url, color: .label)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(Palette.hairline, lineWidth: 0.5))
            Button {
                UIPasteboard.general.string = url
                Haptics.tick()
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
            } label: {
                Label(copied ? L.copied() : L.copyAddress(), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            Text(L.desktopAddressNote())
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button(L.done()) { dismiss() }
                .font(.subheadline)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg.ignoresSafeArea())
        .presentationDetents([.medium])
    }
}

/// Owns the reader's SSH channel: fetches issues and runs the report's
/// long-press action commands. Mirrors WorkflowStore's runAdhoc contract —
/// in-band exit code, one reconnect retry on a dead channel (a transport
/// failure can't have run the command to completion, so the retry is safe).
@MainActor
final class ArchiveReaderStore: ObservableObject {
    @Published private(set) var content = ""
    @Published private(set) var loading = false
    @Published private(set) var errorText: String?

    private let profile: ServerProfile
    private let secret: String
    private let ssh = SSHService()
    /// Test-only: when non-nil, the store is a fixed body and never touches SSH
    /// (default nil = the shipped path). Lets a snapshot render a real issue.
    private let previewContent: String?
    /// Issue text by "dir/file". Past issues are immutable, so a flip back
    /// paints from here instantly (the user watched a spinner on every flip,
    /// 2026-08-30); today's issue can be re-published after a manual re-run,
    /// so a cache hit still re-reads silently in the background and repaints
    /// only if the bytes actually changed.
    private var issueCache: [String: String] = [:]
    /// Test seam (same pattern as FigureStore.sshFetcher): lets a test script
    /// the issue bytes and gate the revalidation round trip without faking SSH.
    var archiveReadOverride: ((String, String) async throws -> String)?

    init(profile: ServerProfile, secret: String, previewContent: String? = nil) {
        self.profile = profile
        self.secret = secret
        self.previewContent = previewContent
        if let previewContent { content = previewContent }
    }

    /// The reader owns a live channel to the Mac, which cached every figure at
    /// publish time — register the SSH fast lane for embedded method figures
    /// (2026-08-27: phones on bad routes spun forever fetching arxiv directly).
    /// base64 over runCommand keeps the transport text-safe; a miss returns nil
    /// and the view falls back to the direct URL.
    func registerFigureLane() {
        guard previewContent == nil else { return }
        FigureStore.shared.bulkFetcher = { [weak self] ids in
            guard let self else { return [:] }
            let safe = ids.filter { $0.range(of: "^[0-9.]{9,10}$", options: .regularExpression) != nil }
            guard !safe.isEmpty else { return [:] }
            // One round trip for the whole issue: "id bytecount base64" per
            // line. The count is the transfer's receipt — a dropped SSH channel
            // yields a clean prefix that still base64-decodes, and without the
            // receipt a half figure passes for whole (2026-08-28 black-bottom).
            // Pieces joined, not added: a chain of + over literals inside this
            // closure is more than Xcode 16's type checker gets through in time.
            let pieces: [String] = [
                "for i in ", safe.joined(separator: " "), "; do ",
                "f=$(ls \"$HOME/.pervio/papers/figures/$i\".* 2>/dev/null | head -1); ",
                "[ -n \"$f\" ] && printf '%s %s %s\\n' \"$i\" \"$(stat -f%z \"$f\")\" \"$(base64 < \"$f\" | tr -d '\\n')\"; ",
                "done; true",
            ]
            let cmd = pieces.joined()
            guard let out = try? await self.ssh.runCommand(cmd, maxBytes: 24_000_000) else { return [:] }
            var got: [String: Data] = [:]
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2)
                guard parts.count == 3,
                      let stated = Int(parts[1]),
                      let data = Data(base64Encoded: String(parts[2]),
                                      options: .ignoreUnknownCharacters),
                      data.count == stated else { continue }
                got[String(parts[0])] = data
            }
            return got
        }
        FigureStore.shared.sshFetcher = { [weak self] id in
            guard let self, id.range(of: "^[0-9.]{9,10}$", options: .regularExpression) != nil
            else { return nil }
            // First line is the byte count — the same truncation receipt the
            // bulk lane carries; a short read must not be cached as the figure.
            let cmd = "f=$(ls \"$HOME/.pervio/papers/figures/\"" + id
                + ".* 2>/dev/null | head -1); [ -n \"$f\" ] && { stat -f%z \"$f\"; base64 < \"$f\"; }"
            guard let out = try? await self.ssh.runCommand(cmd) else { return nil }
            let parts = out.split(separator: "\n", maxSplits: 1)
            guard parts.count == 2,
                  let stated = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let data = Data(base64Encoded: String(parts[1]),
                                  options: .ignoreUnknownCharacters),
                  data.count == stated else { return nil }
            return data
        }
    }

    func unregisterFigureLane() {
        FigureStore.shared.sshFetcher = nil
        FigureStore.shared.bulkFetcher = nil
    }

    func read(dir: String, file: String) async {
        // A seeded preview store renders its fixed body and never dials out.
        if previewContent != nil { return }
        let key = dir + "/" + file
        if let hit = issueCache[key] {
            // Paint the cached issue before any suspension point — the flip is
            // instant even if this task is about to be cancelled by another.
            content = hit
            errorText = nil
            loading = false
            prefetchFigures(in: hit)
            if let fresh = try? await fetchIssue(dir: dir, file: file),
               !Task.isCancelled, !fresh.isEmpty, fresh != hit {
                issueCache[key] = fresh
                content = fresh
                // A re-published issue can carry figures the cached text never
                // mentioned — warm those too, or they'd trickle in one by one.
                prefetchFigures(in: fresh)
            }
            return
        }
        loading = true
        errorText = nil
        // The SSH read isn't cancellation-aware: a fast issue-flip cancels this
        // task but the old read still completes. Every state write below must
        // re-check cancellation, or the STALE read's defer would kill the
        // CURRENT read's spinner and its content could clobber the newer issue.
        defer { if !Task.isCancelled { loading = false } }
        do {
            let text = try await fetchIssue(dir: dir, file: file)
            guard !Task.isCancelled else { return }
            issueCache[key] = text
            content = text
            prefetchFigures(in: text)
        } catch {
            // Flipping issues cancels the previous read mid-flight — that's
            // navigation, not a failure, so it must not paint the error line.
            if Task.isCancelled || error is CancellationError { return }
            content = ""
            errorText = pervioErrorText(error, "Couldn't load this issue.")
        }
    }

    private func fetchIssue(dir: String, file: String) async throws -> String {
        if let override = archiveReadOverride { return try await override(dir, file) }
        return try await withRetry {
            try await self.ssh.readArchiveFile(profile: self.profile,
                                               dir: dir, file: file)
        }
    }

    /// Warm the figure cache for this whole issue in one SSH round trip,
    /// so scrolling meets local images instead of per-figure fetches.
    private func prefetchFigures(in text: String) {
        let ids = FigureStore.ids(inMarkdown: text)
        if !ids.isEmpty {
            Task { await FigureStore.shared.prefetch(ids) }
        }
    }

    /// Hand this issue to a desktop browser: the server renders it and answers
    /// with a loopback URL. Same one-reconnect retry as every other call here.
    func startDesktopView(dir: String, file: String) async throws -> String {
        try await withRetry {
            try await self.ssh.startDesktopView(profile: self.profile,
                                                dir: dir, file: file)
        }
    }

    func runAdhoc(_ command: String) async throws -> String {
        let wrapped = "{ " + command + " ; } 2>&1; printf '\\n__PERVIO_RC=%d' $?"
        let out = try await withRetry { try await self.ssh.runCommand(wrapped) }
        // Our marker is printed last, so a backwards search can't be fooled by
        // command output that happens to contain the same text.
        guard let r = out.range(of: "\n__PERVIO_RC=", options: .backwards) else {
            return out                        // marker lost (truncated output) — return raw
        }
        let body = String(out[..<r.lowerBound])
        let rc = Int(out[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        guard rc == 0 else {
            let msg = body.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "Pervio.action", code: rc, userInfo: [
                NSLocalizedDescriptionKey: (msg.isEmpty ? "command failed" : msg) + " (exit \(rc))"])
        }
        return body
    }

    func stop() {
        Task { await ssh.disconnect() }
    }

    /// Connect lazily, run, and retry ONCE on a fresh channel — the connection
    /// may be long dead by the time the user flips to the next issue.
    private func withRetry(_ body: () async throws -> String) async throws -> String {
        if !ssh.isConnected { try await ssh.connect(profile: profile, secret: secret) }
        do {
            return try await body()
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            await ssh.disconnect()
            try await ssh.connect(profile: profile, secret: secret)
            return try await body()
        }
    }
}
