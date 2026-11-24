import SwiftUI
import WebKit
import UIKit

// MARK: - What counts as "a page on the Mac"

/// The web preview (2026-11-06): a page served on the Mac's own loopback,
/// shown on the phone through an SSH tunnel. These helpers decide which links
/// are that — `localhost`, `127.0.0.1`, `::1`, `0.0.0.0` — and what port they mean.
enum WebPreview {
    static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"]

    static func isLocal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return localHosts.contains(host)
    }

    /// The port a local link means (the scheme's default when it names none).
    static func port(of url: URL) -> Int {
        if let p = url.port { return p }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }

    /// Path + query of a link, "/" when it has none.
    static func path(of url: URL) -> String {
        var p = url.path.isEmpty ? "/" : url.path
        if let q = url.query, !q.isEmpty { p += "?" + q }
        return p
    }

    /// The same link, re-aimed at the phone's end of the tunnel.
    static func rewrite(_ url: URL, toLocalPort local: Int) -> URL? {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.scheme = "http"
        c?.host = "127.0.0.1"
        c?.port = local
        return c?.url
    }
}

/// What a tap on a local link in a reply opens: the port, and the page on it.
struct WebPreviewTarget: Identifiable, Hashable {
    let port: Int
    let path: String
    var id: String { "\(port)\(path)" }
}

/// The tap handler views install for localhost links (SelectableText reads
/// it) — a `LinkAction` from the page's `LinkRouter`, comparable between
/// evaluations (see LinkRouter.swift for the why).
struct OpenLocalURLKey: EnvironmentKey {
    static let defaultValue: LinkAction<URL>? = nil
}
extension EnvironmentValues {
    var openLocalURL: LinkAction<URL>? {
        get { self[OpenLocalURLKey.self] }
        set { self[OpenLocalURLKey.self] = newValue }
    }
}

// MARK: - The page: a tunnel of its own and a web view

/// One preview: its own SSH connection (the chat's channels are never shared
/// with page traffic), a tunnel to one port on the Mac, a web view aimed at
/// the phone's end. Torn down when the page leaves the screen or the app goes
/// to the background; put back when the app returns.
@MainActor
final class WebPreviewModel: NSObject, ObservableObject {
    enum Phase: Equatable {
        case connecting
        case up(localPort: Int)
        case paused               // the app went to the background: nothing open behind the person's back
        case down(String)
    }
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var pageTitle = ""
    @Published private(set) var currentURL: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var loadError: String?

    let profile: ServerProfile
    let secret: String
    private(set) var port: Int
    private var path: String
    let webView: WKWebView
    private let ssh = SSHService()
    private var tunnel: SSHTunnel?
    private var observers: [NSKeyValueObservation] = []

    init(profile: ServerProfile, secret: String, port: Int, path: String = "/") {
        self.profile = profile
        self.secret = secret
        self.port = port
        self.path = path
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()      // a dev site's cookies never outlive the preview
        cfg.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.allowsBackForwardNavigationGestures = true
        self.webView = wv
        super.init()
        wv.navigationDelegate = self
        wv.uiDelegate = self
        observers = [
            wv.observe(\.title) { [weak self] w, _ in Task { @MainActor in self?.pageTitle = w.title ?? "" } },
            wv.observe(\.url) { [weak self] w, _ in Task { @MainActor in self?.currentURL = w.url } },
            wv.observe(\.canGoBack) { [weak self] w, _ in Task { @MainActor in self?.canGoBack = w.canGoBack } },
        ]
    }

    var localPort: Int? { if case .up(let p) = phase { return p } else { return nil } }

    /// The page's own address, as the person reads it.
    var addressLine: String {
        if let u = currentURL, !WebPreview.isLocal(u), let host = u.host { return host }
        return "localhost:\(port)"
    }

    /// The current page is somewhere else on the web (a link the page sent us to).
    var isExternal: Bool { currentURL.map { !WebPreview.isLocal($0) } ?? false }

    func connect() async {
        phase = .connecting
        loadError = nil
        do {
            try await ssh.connect(profile: profile, secret: secret)
            let t = SSHTunnel(opener: ssh, targetPort: port)
            let local = try await t.start(preferring: port)
            tunnel = t
            phase = .up(localPort: local)
            load()
        } catch {
            phase = .down(Self.describe(error))
        }
    }

    /// The app left the screen: close every stream now; `resume()` reopens.
    func pause() async {
        await tearDown()
        phase = .paused
    }

    func resume() async {
        guard phase == .paused else { return }
        await connect()
    }

    func disconnect() async {
        await tearDown()
        phase = .down("")
    }

    private func tearDown() async {
        await tunnel?.stop()
        tunnel = nil
        await ssh.disconnect()
    }

    func load() {
        guard let local = localPort else { return }
        if let url = URL(string: "http://127.0.0.1:\(local)\(path)") {
            webView.load(URLRequest(url: url))
        }
    }

    func reload() { loadError = nil; webView.reload() }
    func goBack() { webView.goBack() }

    /// A link to another port on the Mac: the same preview, re-aimed.
    func retarget(port newPort: Int, path newPath: String) async {
        port = newPort
        path = newPath
        await tearDown()
        await connect()
    }

    /// The page as a picture, for the chat.
    func snapshot() async -> Data? {
        await withCheckedContinuation { cont in
            webView.takeSnapshot(with: nil) { image, _ in
                cont.resume(returning: image?.jpegData(compressionQuality: 0.85))
            }
        }
    }

    static func describe(_ error: Error) -> String {
        let text = String(describing: error).lowercased()
        if text.contains("channelcreationfailed") || text.contains("administratively prohibited")
            || text.contains("open failed") || text.contains("channel open") {
            return L.webPreviewForwardRefused()
        }
        if let e = error as? SSHService.ConnectionError { return e.message }
        return error.localizedDescription
    }
}

extension WebPreviewModel: WKNavigationDelegate, WKUIDelegate {
    /// Links back to the Mac keep riding the tunnel (a page's own absolute
    /// localhost:3000 links, or a link to another port — the preview re-aims);
    /// links elsewhere on the web load here too, with "Open in Safari" offered.
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, WebPreview.isLocal(url) else { decisionHandler(.allow); return }
        Task { @MainActor in
            let wanted = WebPreview.port(of: url)
            if let local = self.localPort, url.host == "127.0.0.1", wanted == local {
                decisionHandler(.allow)                       // already the phone's end of the tunnel
                return
            }
            decisionHandler(.cancel)
            if wanted == self.port, let local = self.localPort, let re = WebPreview.rewrite(url, toLocalPort: local) {
                self.webView.load(URLRequest(url: re))        // the page named the Mac's port; ride the tunnel
            } else {
                await self.retarget(port: wanted, path: WebPreview.path(of: url))
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }   // target=_blank stays here
        return nil
    }

    /// A dev server's self-signed certificate is trusted only for the tunnel's
    /// own loopback end; every other host keeps the strict check.
    nonisolated func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                             completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           WebPreview.localHosts.contains(host), let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let text = error.localizedDescription
        Task { @MainActor in self.loadError = text }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.loadError = nil }
    }
}

/// The web view as a SwiftUI view: the model owns it, this just hosts it.
private struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - The page on screen

struct WebPreviewPage: View {
    @StateObject private var model: WebPreviewModel
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var shotDone = false

    init(profile: ServerProfile, secret: String, port: Int, path: String = "/", store: ChatStore) {
        _model = StateObject(wrappedValue: WebPreviewModel(profile: profile, secret: secret, port: port, path: path))
        self.store = store
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ZStack {
                WebViewHost(webView: model.webView)
                    .accessibilityIdentifier("web-page")
                if model.phase == .connecting {
                    VStack(spacing: 8) { ProgressView(); Text(L.webPreviewConnecting()).font(.subheadline).foregroundStyle(.secondary) }
                }
                if case .down(let why) = model.phase, !why.isEmpty {
                    VStack(spacing: 10) {
                        Text(why).font(.subheadline).multilineTextAlignment(.center).padding(.horizontal, 24)
                        Button(L.webPreviewRetry()) { Task { await model.connect() } }.buttonStyle(.bordered)
                    }
                    .padding()
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                } else if let err = model.loadError {
                    VStack(spacing: 10) {
                        Text(L.webPreviewLoadFailed()).font(.subheadline.weight(.semibold))
                        Text(err).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                        Button(L.webPreviewRetry()) { model.reload() }.buttonStyle(.bordered)
                    }
                    .padding()
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            Divider()
            statusLine
        }
        .background(Palette.bg)
        .task { await model.connect() }
        .onDisappear { Task { await model.disconnect() } }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: Task { await model.pause() }
            case .active: Task { await model.resume() }
            default: break
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left").frame(width: 34, height: 34) }
                .disabled(!model.canGoBack)
                .accessibilityIdentifier("web-back")
            Text(model.addressLine)
                .font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("web-address")
            if model.isExternal, let url = model.currentURL {
                Button { UIApplication.shared.open(url) } label: { Image(systemName: "safari").frame(width: 34, height: 34) }
                    .accessibilityLabel(L.webPreviewOpenSafari())
            }
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise").frame(width: 34, height: 34) }
                .accessibilityIdentifier("web-reload")
            Button { Task { await shoot() } } label: {
                Image(systemName: shotDone ? "checkmark.circle" : "camera").frame(width: 34, height: 34)
            }
            .disabled(model.localPort == nil || store.isUploading)
            .accessibilityLabel(L.webPreviewShot())
            .accessibilityIdentifier("web-shot")
            Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 34, height: 34) }
                .accessibilityIdentifier("web-close")
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            switch model.phase {
            case .connecting:
                ProgressView().controlSize(.mini)
                Text(L.webPreviewConnecting())
            case .up(let local):
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(L.webPreviewTunnelOn(model.port) + (local != model.port ? " · :\(local)" : ""))
            case .paused:
                ProgressView().controlSize(.mini)
                Text(L.webPreviewPaused())
            case .down:
                Circle().fill(.red).frame(width: 7, height: 7)
                Button(L.webPreviewTunnelOff()) { Task { await model.connect() } }.buttonStyle(.plain)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityIdentifier("web-status")
    }

    /// The page as a picture in the composer, then back to the chat to say
    /// what's wrong with it.
    private func shoot() async {
        guard let data = await model.snapshot() else { return }
        let jpeg = ComposerPlusMenu<EmptyView>.downscaledJPEG(data)
        let thumb = ComposerPlusMenu<EmptyView>.downscaledJPEG(data, maxDim: 200, quality: 0.6)
        let name = "web-\(model.port)-\(UUID().uuidString.prefix(6)).jpg"
        store.attachAsync(data: jpeg, filename: name, isImage: true, thumbnail: thumb)
        shotDone = true
        Haptics.success()
        try? await Task.sleep(nanoseconds: 350_000_000)
        dismiss()
    }
}

// MARK: - The menu: what is listening on the Mac

struct WebPreviewSheet: View {
    let profile: ServerProfile
    let secret: String
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service: SessionService
    @State private var ports: [ListeningPort] = []
    @State private var loading = true
    @State private var typed = ""
    @State private var target: WebPreviewTarget?

    init(profile: ServerProfile, secret: String, store: ChatStore) {
        self.profile = profile
        self.secret = secret
        self.store = store
        _service = StateObject(wrappedValue: SessionService(profile: profile, secret: secret))
    }

    private var typedPort: Int? {
        let n = Int(typed.trimmingCharacters(in: .whitespaces)) ?? 0
        return (1...65535).contains(n) ? n : nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if loading {
                        HStack { ProgressView(); Text(L.webPreviewLoading()).foregroundStyle(.secondary) }
                    } else if ports.isEmpty {
                        Text(L.webPreviewNone()).font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(ports) { p in
                            Button { target = WebPreviewTarget(port: p.port, path: "/") } label: {
                                HStack(spacing: 10) {
                                    Text(String(p.port)).font(.body.weight(.semibold).monospacedDigit())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.process.isEmpty ? "—" : p.process).font(.subheadline)
                                        HStack(spacing: 4) {
                                            if let d = p.sinceDate { Text(d, format: .relative(presentation: .named)) }
                                            if p.isLoopback { Text("· " + L.webPreviewOnlyMac()) }
                                        }
                                        .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("web-port-\(p.port)")
                        }
                    }
                } header: {
                    Text(L.webPreviewListening())
                }
                Section {
                    HStack {
                        TextField(L.webPreviewPortField(), text: $typed)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("web-port-field")
                        Button(L.webPreviewOpen()) {
                            if let p = typedPort { target = WebPreviewTarget(port: p, path: "/") }
                        }
                        .disabled(typedPort == nil)
                        .accessibilityIdentifier("web-port-open")
                    }
                }
            }
            .navigationTitle(L.webPreview())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.cancel()) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .navigationDestination(item: $target) { t in
                WebPreviewPage(profile: profile, secret: secret, port: t.port, path: t.path, store: store)
                    .navigationBarBackButtonHidden(true)
                    .toolbar(.hidden, for: .navigationBar)
            }
            .task { await load() }
            .onDisappear { Task { await service.disconnect() } }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        ports = (try? await service.listeningPorts()) ?? []
    }
}
