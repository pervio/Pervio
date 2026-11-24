import SwiftUI
import QuickLook

/// A reply (or a report) linked a file by its absolute path on the Mac —
/// `[四图对照](/Users/me/exp/output/comparison.png)`. On the phone that link
/// used to be dead. Now it opens here: the bytes come over SSH once, land in a
/// temp file under the original name, and QuickLook shows them — images zoom,
/// PDFs page, text scrolls, and the share sheet is one tap away. Nothing on
/// the Mac is touched.
///
/// Link plumbing: markdown links whose target is an absolute (or `~/`) path
/// are rewritten to `pervio-file:` URLs at render time (ServerFileLink), and
/// the views that show prose hand taps on them to `openServerFile` in the
/// environment, which presents this sheet.
enum ServerFileLink {
    static let scheme = "pervio-file"

    /// A markdown link target that means "a path on the server": absolute
    /// (`/Users/…`) or home-relative (`~/…`), no URL scheme. Everything else
    /// (http, mailto, relative names) is left to the existing rules.
    static func rewrite(_ url: URL) -> URL? {
        guard url.scheme == nil else { return nil }
        let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        guard raw.hasPrefix("/") || raw.hasPrefix("~/") else { return nil }
        var c = URLComponents()
        c.scheme = scheme
        c.host = ""
        c.path = raw.hasPrefix("~/") ? "/~" + raw.dropFirst(1) : raw
        return c.url
    }

    /// The server path back out of a `pervio-file:` URL (nil for any other URL).
    static func path(of url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let p = url.path
        return p.hasPrefix("/~/") ? "~" + p.dropFirst(2) : p
    }
}

/// The tap handler views install for `pervio-file:` links — a `LinkAction`,
/// created once by the page's `LinkRouter`, so the environment compares as
/// unchanged between evaluations (see LinkRouter.swift for the why).
struct OpenServerFileKey: EnvironmentKey {
    static let defaultValue: LinkAction<String>? = nil
}
extension EnvironmentValues {
    var openServerFile: LinkAction<String>? {
        get { self[OpenServerFileKey.self] }
        set { self[OpenServerFileKey.self] = newValue }
    }
}

/// Identifiable wrapper so `.sheet(item:)` can present a path.
struct ServerFileTarget: Identifiable {
    let path: String
    var id: String { path }
}

struct ServerFilePreview: View {
    let profile: ServerProfile
    let secret: String
    let path: String

    @StateObject private var service: SessionService
    @State private var fileURL: URL?
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    init(profile: ServerProfile, secret: String, path: String) {
        self.profile = profile
        self.secret = secret
        self.path = path
        _service = StateObject(wrappedValue: SessionService(profile: profile, secret: secret))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let fileURL {
                    QuickLookView(url: fileURL)
                        .ignoresSafeArea(edges: .bottom)
                } else if let errorText {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.questionmark").font(.largeTitle).foregroundStyle(.secondary)
                        Text(errorText).font(.callout).multilineTextAlignment(.center)
                            .foregroundStyle(.secondary).padding(.horizontal, 24)
                    }
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(L.previewLoading()).font(.caption).foregroundStyle(.secondary)
                        Text((path as NSString).lastPathComponent)
                            .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
            }
            .pervioBar((path as NSString).lastPathComponent, back: false)
            .toolbar {
                BarItem(.cancellationAction) { BarWord(text: L.done(), weight: .semibold) { dismiss() } }
            }
        }
        .task { await load() }
        .onDisappear { Task { await service.disconnect() } }
    }

    private func load() async {
        do {
            let data = try await service.readServerFile(path: path)
            // QuickLook picks the viewer by extension, so keep the real name;
            // a per-path folder keeps two same-named files from clobbering.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("pervio-preview", isDirectory: true)
                .appendingPathComponent(String(path.hashValue, radix: 16), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent((path as NSString).lastPathComponent)
            try data.write(to: url, options: .atomic)
            fileURL = url
        } catch {
            errorText = pervioErrorText(error, L.previewFailed())
        }
    }
}

/// QLPreviewController wrapped for SwiftUI — one viewer for images, PDFs and
/// text alike, with QuickLook's own zoom, paging and share.
private struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ c: QLPreviewController, context: Context) {
        context.coordinator.url = url
        c.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
