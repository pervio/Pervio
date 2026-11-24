import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// The composer's reusable parts. ChatView's own bar and the group strip
/// (双开, GroupView) are built from these, so a photo or file from the phone,
/// a file on the Mac, a past conversation as background and the workflows
/// key work the same in both — the group's one input lost all of that on
/// its first cut and the user asked where it went (2026-10-12).

// MARK: - Attachment chips

/// The folders this conversation can write to (handed over on earlier turns,
/// recovered from the transcript — so they show on reopen and in a branch).
/// Quiet chips; long-press one to stop sending it (2026-10-17).
struct ConversationDirsBar: View {
    @ObservedObject var store: ChatStore
    @State private var formerShown: String?

    var body: some View {
        let dirs = store.conversationDirs
        let former = store.formerDirs
        if !dirs.isEmpty || !former.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // Named in the conversation's text, not handed over: shown,
                    // never used. A tap says why and how to hand it over again.
                    ForEach(former, id: \.self) { d in
                        Button { formerShown = d } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.badge.questionmark").font(.caption2)
                                Text((d as NSString).lastPathComponent.isEmpty ? d : (d as NSString).lastPathComponent)
                                    .font(.caption2).lineLimit(1).strikethrough()
                            }
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .overlay(Capsule().strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("conversation-dir-former")
                    }
                    ForEach(dirs, id: \.self) { d in
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill").font(.caption2).foregroundStyle(.tint)
                            Text((d as NSString).lastPathComponent.isEmpty ? d : (d as NSString).lastPathComponent)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.surface, in: Capsule())
                        .contextMenu {
                            Text(d)
                            Button(role: .destructive) { store.stopUsingDir(d) } label: {
                                Label(L.stopUsingFolder(), systemImage: "folder.badge.minus")
                            }
                        }
                        .accessibilityIdentifier("conversation-dir")
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 28)
            .alert(L.formerFolderTitle(), isPresented: Binding(get: { formerShown != nil },
                                                                 set: { if !$0 { formerShown = nil } })) {
                Button(L.gotIt(), role: .cancel) { formerShown = nil }
            } message: {
                Text(L.formerFolderBody(formerShown ?? ""))
            }
        }
    }
}

/// Chips for the files waiting on the next message, plus what is on its way
/// in: one strip, worded by stage (TransferStage) — a pick from another
/// computer reads "connecting", then "reading from", then "sending to", each
/// with its own percentage, where it used to say "Uploading 0%" for all of it.
struct ComposerAttachmentsBar: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        if store.isUploading || !store.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if store.isUploading {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text(store.transferStage.label(percent: Int(store.uploadProgress * 100)))
                                .font(.caption).foregroundStyle(.secondary)
                                .monospacedDigit()      // the number changes, the strip does not jitter
                                .lineLimit(1)
                                .accessibilityIdentifier("transfer-strip")
                            // A file from another computer can be a minute on its
                            // way, over a link that may have stopped answering:
                            // the same ✕ a chip has, to stop it.
                            Button { store.cancelTransfer() } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L.transferStop())
                            .accessibilityIdentifier("transfer-stop")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Palette.surface, in: Capsule())
                    }
                    ForEach(store.attachments) { att in
                        HStack(spacing: 6) {
                            if let data = att.thumbnail, let ui = UIImage(data: data) {
                                Image(uiImage: ui).resizable().scaledToFill()
                                    .frame(width: 22, height: 22)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
                                Image(systemName: att.inlinePrompt != nil ? "square.stack.3d.up"
                                      : att.isDirectory ? "folder"
                                      : att.isContext ? "text.bubble"
                                      : (att.isImage ? "photo" : "doc"))
                                    .font(.caption).foregroundStyle(.tint)
                            }
                            Text(att.name).font(.caption).lineLimit(1)
                            Button { store.removeAttachment(att) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Palette.surface, in: Capsule())
                        .overlay(Capsule().stroke(Palette.hairline, lineWidth: 0.5))
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 40)
        }
    }
}

// MARK: - ＋ menu

/// ＋: a photo or a file from the phone (uploaded to ~/.pervio/uploads), a
/// file on the Mac (attached by path), or a past conversation as background.
/// Owns its pickers and sheets. `extra` adds entries under the standard four
/// (ChatView puts 双开 there).
struct ComposerPlusMenu<Extra: View>: View {
    @ObservedObject var store: ChatStore
    let secret: String
    /// Where the Mac-file browser starts — the conversation's own dir.
    let dir: String
    /// A handed-over DIRECTORY appends its guidance to the draft.
    @Binding var input: String
    let extra: () -> Extra

    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var showServerFiles = false
    @State private var showContextPicker = false
    @State private var showWebPreview = false
    /// The saved computers; the ones that are not this conversation's can be
    /// read from in the two pickers below (2026-11-22).
    @Environment(\.savedServers) private var savedServers
    /// A second entry for this same Mac (its "~" and its "~/a") is not another
    /// computer — see ServerProfile.reachesSameMachine.
    private var otherComputers: [ServerProfile] {
        savedServers.filter { $0.id != store.profile.id && !$0.reachesSameMachine(as: store.profile) }
    }

    init(store: ChatStore, secret: String, dir: String, input: Binding<String>,
         @ViewBuilder extra: @escaping () -> Extra) {
        self.store = store
        self.secret = secret
        self.dir = dir
        self._input = input
        self.extra = extra
    }

    var body: some View {
        Menu {
            Button { showPhotoPicker = true } label: { Label(L.attachPhoto(), systemImage: "photo") }
            Button { showFileImporter = true } label: { Label(L.attachFile(), systemImage: "doc") }
            // Browse the SERVER's files (the browser the 背景 sheet embeds,
            // surfaced): pick a file to attach by path, or hand a directory
            // over. Its own entry because buried under 背景… it went unfound.
            Button { showServerFiles = true } label: {
                Label(L.attachServerFile(), systemImage: "externaldrive")
            }
            // Attach a past conversation's transcript as background context.
            // (剧本 lives in the market — its 在对话中用 opens a prefilled
            // chat — not in this menu.)
            Button { showContextPicker = true } label: {
                Label(L.attachContext(), systemImage: "clock.arrow.circlepath")
            }
            // The Mac's dev server on the phone, through the SSH tunnel (2026-11-06).
            Button { showWebPreview = true } label: {
                Label(L.webPreview(), systemImage: "globe")
            }
            extra()
        } label: {
            Image(systemName: "plus")
                .font(.title3).foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Palette.surface, in: Circle())
                .overlay(Circle().stroke(Palette.hairline, lineWidth: 1))
        }
        // A fixed handle for the UI tests: the SF Symbol's own label is "Add",
        // so by label the + is never found (panels probe, 2026-10-17).
        .accessibilityIdentifier("composer-plus")
        .disabled(store.isUploading)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await loadPhoto(item) }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await loadFile(url) }
        }
        // ＋ → 背景…: pick a past conversation (any project); the App exports its
        // transcript over SSH and attaches it to the current message as context —
        // the model needs no extra read permissions.
        .sheet(isPresented: $showWebPreview) {
            WebPreviewSheet(profile: store.profile, secret: secret, store: store)
        }
        .sheet(isPresented: $showContextPicker) {
            ContextPickerSheet(profile: store.profile, secret: secret,
                               currentDir: dir,
                               currentSessionId: store.sessionId,
                               others: otherComputers,
                               // Picked on ANOTHER computer: read there, written
                               // here, through the phone.
                               onPickRemote: { source, projectPath, sessions, docs in
                showContextPicker = false
                // Notes, rules and memory files ticked there cross as background
                // documents (their source and "not instructions" on top), like
                // the ones picked on this computer.
                store.attachFromAsync(source, projectPath: projectPath, sessions: sessions, notes: docs)
            },
                               onPick: { projectPath, session in
                showContextPicker = false
                store.attachContextAsync(projectPath: projectPath, session: session)
            },
                               onPickMany: { projectPath, sessions, docs in
                showContextPicker = false
                store.attachManyAsync(projectPath: projectPath, sessions: sessions, docs: docs)
            },
                               // F2: a picked server file — copied into
                               // ~/.pervio/uploads server-side and attached as a
                               // path (one route, both backends), on the chat's
                               // own connection like the transcript path above.
                               onPickServerFile: { path in
                showContextPicker = false
                store.attachServerFileAsync(path: path)
            },
                               // F3: hand a directory over BY PATH — append the
                               // guidance below any existing draft (blank-line
                               // separated); the user can keep typing, then
                               // send. Nothing is packed; the agent reads the
                               // directory itself.
                               onHandoffDir: { path in
                showContextPicker = false
                appendHandoff(path)
            })
        }
        // ＋ → 服务器文件…: the same browser, same two outcomes as its embedded
        // twin above — a picked FILE attaches by path (uploads-copy route, both
        // backends), a handed-over DIRECTORY appends the guidance to the draft.
        .sheet(isPresented: $showServerFiles) {
            ServerFileSheet(profile: store.profile, secret: secret,
                            startPath: dir,
                            others: otherComputers,
                            onPickRemoteFile: { source, path in
                showServerFiles = false
                store.attachFromAsync(source, files: [path])
            },
                            onPickFile: { path in
                showServerFiles = false
                store.attachServerFileAsync(path: path)
            },
                            onHandoffDir: { path in
                showServerFiles = false
                appendHandoff(path)
            })
        }
    }

    /// A handed-over directory becomes a 📁 chip in the composer (the guidance
    /// rides the wire unseen) — it used to be pasted into the draft, so the
    /// person sent and saw a paragraph they never wrote (2026-10-15).
    private func appendHandoff(_ path: String) {
        store.attachDirectory(path)
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let jpeg = Self.downscaledJPEG(data)
        let thumb = Self.downscaledJPEG(data, maxDim: 200, quality: 0.6)   // tiny chip preview
        let name = "image-\(UUID().uuidString.prefix(6)).jpg"   // distinct per pick
        await store.attachAsync(data: jpeg, filename: name, isImage: true, thumbnail: thumb)
    }

    private func loadFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.lowercased()
        let isImage = ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(ext)
        await store.attachAsync(data: data, filename: url.lastPathComponent, isImage: isImage)
    }

    /// Shrink a picked photo so uploads stay small/fast (max 2048px, JPEG ~0.72).
    static func downscaledJPEG(_ data: Data, maxDim: CGFloat = 2048,
                               quality: CGFloat = 0.72) -> Data {
        guard let img = UIImage(data: data) else { return data }
        let side = max(img.size.width, img.size.height)
        let scale = side > maxDim ? maxDim / side : 1
        let target = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            img.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality) ?? data
    }
}

extension ComposerPlusMenu where Extra == EmptyView {
    init(store: ChatStore, secret: String, dir: String, input: Binding<String>) {
        self.init(store: store, secret: secret, dir: dir, input: input) { EmptyView() }
    }
}

// MARK: - Workflows key + panel

/// Pervio workflows-context key: lit while the panel is OPEN (so the same
/// tap obviously closes it) and stays lit when the conversation carries the
/// wf context (`--pervio-context`). Sticky per conversation; flipping
/// mid-chat applies from the NEXT message.
struct ComposerWfKey: View {
    @ObservedObject var store: ChatStore
    @Binding var open: Bool
    /// Called when the panel opens — the owner loads the templates once.
    let onOpen: () -> Void

    var body: some View {
        Button {
            Haptics.tick()
            withAnimation(.snappy(duration: 0.18)) { open.toggle() }
            if open { onOpen() }
        } label: {
            let lit = open || store.pervioContext
            Image(systemName: "arrow.triangle.branch")
                .font(.title3)
                .foregroundStyle(lit ? Color.white : Color.secondary)
                .frame(width: 34, height: 34)
                .background(lit ? Palette.accent : Palette.surface, in: Circle())
                .overlay(Circle().stroke(lit ? Palette.accent : Palette.hairline,
                                         lineWidth: 1))
        }
        .accessibilityLabel("Pervio workflows context")
    }
}

/// What the page wants put into the composer: a bubble's words to restate, a
/// message handed back after a refusal. A fresh id each time, so the same
/// words twice in a row land twice.
struct ComposerPrefill: Equatable {
    let id = UUID()
    let text: String
}

/// The composer: plus menu, workflow key, the text field and the one send/stop
/// key. It OWNS the draft. Why a view of its own: the draft used to be a
/// @State of the chat page, so every keystroke re-evaluated the page and its
/// whole transcript — 22 ms a key on a 60-turn conversation on the simulator
/// even with every row skipping its body, a dropped frame or more on a phone
/// (2026-11-18). Here a keystroke re-evaluates this bar alone.
struct ComposerInputBar<Extra: View>: View {
    @ObservedObject var store: ChatStore
    let secret: String
    /// Where the Mac-file browser starts — the conversation's own dir.
    let dir: String
    /// What the page puts into the draft (see ComposerPrefill); nil = nothing.
    let prefill: ComposerPrefill?
    /// The page keeps the focus state (it drops it when the terminal closes,
    /// scrolls to the end when the keyboard opens, focuses after a pick).
    var focus: FocusState<Bool>.Binding
    @Binding var showWfSuggest: Bool
    /// The fork key opened — the owner loads the templates once.
    let onWfKey: () -> Void
    /// The typed message, on Send; the page decides how it goes out.
    let onSend: (String) -> Void
    /// Extra rows of the plus menu (the group entry on a full page).
    let extra: () -> Extra

    @State private var input: String

    init(store: ChatStore, secret: String, dir: String, initialInput: String,
         prefill: ComposerPrefill?, focus: FocusState<Bool>.Binding, showWfSuggest: Binding<Bool>,
         onWfKey: @escaping () -> Void, onSend: @escaping (String) -> Void,
         @ViewBuilder extra: @escaping () -> Extra) {
        self.store = store
        self.secret = secret
        self.dir = dir
        self.prefill = prefill
        self.focus = focus
        self._showWfSuggest = showWfSuggest
        self.onWfKey = onWfKey
        self.onSend = onSend
        self.extra = extra
        _input = State(initialValue: initialInput)
    }

    private var canSend: Bool {
        !(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.attachments.isEmpty)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ComposerPlusMenu(store: store, secret: secret, dir: dir, input: $input, extra: extra)
            ComposerWfKey(store: store, open: $showWfSuggest, onOpen: onWfKey)

            HStack(alignment: .bottom, spacing: 6) {
                TextField("Message \(store.profile.backend.tag)…", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .focused(focus)
                // One key (2026-10-21, the person: no more buttons): while a turn
                // runs it reads Stop until something is typed, then Send — the
                // words go into the running turn (Run mode) or queue for after.
                // To stop with a draft in hand, clear the draft.
                switch ComposerKey.resolve(busy: store.isBusy || store.activeRunId != nil, hasText: canSend) {
                case .send: sendButton
                case .stop: stopButton
                }
            }
            .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.hairline, lineWidth: 1))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .onChange(of: prefill) { _, p in
            guard let p else { return }
            // Never over a draft in progress: the handed text goes first, the
            // draft stays after it.
            input = input.isEmpty ? p.text : p.text + "\n" + input
        }
    }

    /// Send (Chat) / launch (Run). The page's `onSend` queues the message when
    /// a turn is already in flight, so a typed follow-up is never stranded.
    private var sendButton: some View {
        Button {
            Haptics.tick()
            let text = input
            input = ""
            onSend(text)
        } label: {
            // Into a turn being answered the words go as they are (an arrow), not
            // as a new launch (the moon).
            let midTurn = store.isBusy && store.activeRunId != nil
            Image(systemName: store.profile.runMode && !midTurn ? "moon.circle.fill" : "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(store.profile.runMode ? Palette.accent : Color.accentColor)
        }
        .disabled(!canSend)
    }

    private var stopButton: some View {
        Button { store.stop() } label: {
            Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(.red)
        }
        .accessibilityIdentifier("stop-turn")
    }
}

/// The fork key's candidate strip — the CC-slash idiom: a compact list
/// floating above the composer. Row 1 keeps the key's ORIGINAL function (the
/// workflows-context toggle) so nothing is lost; then scratch + the server's
/// own templates. Picking INSERTS a prompt; anything already typed becomes
/// the request tail — type first, pick second, both orders work.
/// `preview: true` is the SNAPSHOT path: ImageRenderer draws ScrollViews
/// empty and UIKit-backed controls (Toggle, TextField) as warning
/// placeholders — so the preview swaps in same-geometry stand-ins.
struct ComposerWfPanel: View {
    @ObservedObject var store: ChatStore
    var preview: Bool = false
    let templates: [ServerTemplate]
    let loaded: Bool
    /// A pick becomes a 🧩 chip on the composer; the prompt rides the wire.
    let onPick: (Attachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if preview {
                HStack {
                    Label(L.wfCtxToggle(), systemImage: "arrow.triangle.branch")
                        .font(.caption)
                    Spacer()
                    // A Toggle's visual twin, off-state, drawn in plain shapes.
                    Capsule().fill(Color.secondary.opacity(0.35))
                        .frame(width: 46, height: 28)
                        .overlay(Circle().fill(Color.white).padding(2),
                                 alignment: .leading)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            } else {
                Toggle(isOn: Binding(get: { store.pervioContext },
                                     set: { _ in store.togglePervioContext() })) {
                    Label(L.wfCtxToggle(), systemImage: "arrow.triangle.branch")
                        .font(.caption)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            Divider().overlay(Palette.hairline)
            if preview {
                rows
            } else {
                ScrollView { rows }.frame(maxHeight: 250)
            }
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.hairline, lineWidth: 1))
        .padding(.horizontal, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(title: L.buildPickScratch(), subtitle: nil, system: "plus.circle") {
                onPick(.workflowBuilder())
            }
            if !loaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L.buildPickLoading()).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            ForEach(templates) { t in
                row(title: t.name.isEmpty ? t.file : t.name,
                    subtitle: t.summary, system: "square.stack.3d.up") {
                    onPick(.workflowRevise(name: t.name.isEmpty ? t.file : t.name, file: t.file))
                }
                .disabled(!t.ok)
                .opacity(t.ok ? 1 : 0.4)
            }
        }
    }

    private func row(title: String, subtitle: String?, system: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: system).font(.subheadline).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The templates the panel lists, on a short-lived connection of their own.
/// nil = the list could not be fetched (the owner keeps what it had).
enum ComposerWfTemplates {
    static func load(profile: ServerProfile, secret: String) async -> [ServerTemplate]? {
        let ssh = SSHService()
        defer { Task { await ssh.disconnect() } }
        guard let all = try? await {
            try await ssh.connect(profile: profile, secret: secret)
            return try await ssh.listTemplates(profile: profile)
        }() else { return nil }
        return all.filter { $0.kind != "playbook" }
    }
}
