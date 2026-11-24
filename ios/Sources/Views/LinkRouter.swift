import SwiftUI

/// An action a page installs in the environment for the views below it — a
/// tap on a `pervio-file:` link, on a localhost link — made COMPARABLE: two
/// actions are the same when they were created as the same one (`id`).
///
/// Why: a bare closure written into the environment is a new value on every
/// body evaluation, and SwiftUI cannot compare closures, so every view reading
/// the key was re-run on every evaluation of the page — each keystroke in the
/// composer, each streamed chunk — and each transcript text view re-set its
/// text and re-laid it out: 180 of them, 153 ms a key, on a 60-turn
/// conversation (measured 2026-11-18). With an identity, a re-applied
/// environment reads as unchanged and the rows stay still.
struct LinkAction<Input>: Equatable {
    let id: UUID
    let call: (Input) -> Void

    init(id: UUID = UUID(), _ call: @escaping (Input) -> Void) {
        self.id = id
        self.call = call
    }

    static func == (a: LinkAction, b: LinkAction) -> Bool { a.id == b.id }
}

/// Where a page's links go, created ONCE per page: the actions it installs in
/// the environment (stable for the page's life) and the navigation they
/// trigger, published so the page can present the sheets. `webPreview: false`
/// is the report reader, which previews Mac files but leaves every other link
/// to the system, as it always did.
@MainActor
final class LinkRouter: ObservableObject {
    /// A `pervio-file:` link tapped in a bubble — the Mac path to preview.
    @Published var previewFile: ServerFileTarget?
    /// A localhost link tapped in a reply: the web preview on that port.
    @Published var webPreview: WebPreviewTarget?

    private let localPages: Bool

    init(webPreview localPages: Bool = true) {
        self.localPages = localPages
    }

    /// For `SelectableText` (UITextView links) — the file preview.
    private(set) lazy var openServerFile = LinkAction<String> { [weak self] path in
        self?.previewFile = ServerFileTarget(path: path)
    }

    /// For `SelectableText` — a localhost link, "it's on http://localhost:3000":
    /// the Mac's page through the tunnel, since Safari on the phone could never
    /// reach it (2026-11-06).
    private(set) lazy var openLocalURL = LinkAction<URL> { [weak self] url in
        self?.webPreview = WebPreviewTarget(port: WebPreview.port(of: url), path: WebPreview.path(of: url))
    }

    /// SwiftUI's own link action (Text links in tables, `Link`): the same
    /// routes, then the system for anything else.
    private(set) lazy var openURL = OpenURLAction { [weak self] url in
        guard let self else { return .systemAction }
        if let path = ServerFileLink.path(of: url) {
            self.previewFile = ServerFileTarget(path: path)
            return .handled
        }
        if self.localPages, WebPreview.isLocal(url) {
            self.openLocalURL.call(url)
            return .handled
        }
        return .systemAction
    }
}
