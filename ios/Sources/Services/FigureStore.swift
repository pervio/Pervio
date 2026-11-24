import Foundation
import SwiftUI
import UIKit

/// The digest's method-figure loader (2026-08-27, user ruling: "直接 ssh 传递").
///
/// WHY. The issue markdown carries the figure's arxiv.org URL — honest and
/// portable — but a phone in the wrong network weather can spin on arxiv for
/// ages. The Mac, which already fetched every figure once at publish time
/// (pervio-digest-assemble figs caches them under ~/.pervio/papers/figures/),
/// is seconds away over the SSH channel we already hold. So the load order is:
///
///   1. phone disk cache (Caches/pervio-figures/<id>) — instant, offline-proof;
///   2. SSH: `base64` the Mac's cached file over the reader's own channel;
///   3. the caller falls back to a direct AsyncImage fetch of the arxiv URL.
///
/// The fetcher is INJECTED by whichever screen owns an SSH channel (the archive
/// reader registers on appear, clears on disappear); rendering contexts without
/// a server (chat previews, snapshots) simply skip lane 2. Single-flight per id
/// so a scroll bounce doesn't stack duplicate SSH round trips.
@MainActor
final class FigureStore: ObservableObject {
    static let shared = FigureStore()

    /// Lane 2: id -> raw image bytes, over whatever channel the registrar owns.
    var sshFetcher: ((String) async -> Data?)?
    /// Bulk lane (2026-08-27): the whole issue's figures in ONE SSH round trip —
    /// per-image trips were the latency; a digest has ~a dozen figures and the
    /// tunnel charges per call, not per byte.
    var bulkFetcher: (([String]) async -> [String: Data])?

    /// Warm the disk cache for every id not already there, in one bulk call.
    /// Fire-and-forget from the reader the moment an issue's text lands, so by
    /// the time the user scrolls to a card its figure is local.
    func prefetch(_ ids: [String]) async {
        guard let bulk = bulkFetcher else { return }
        let missing = ids.filter { id in
            !FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent(id).path)
        }
        guard !missing.isEmpty else { return }
        let got = await bulk(missing)
        for (id, data) in got where Self.looksComplete(data) {
            try? data.write(to: cacheDir.appendingPathComponent(id))
        }
    }

    /// Does this byte run end the way its format says a WHOLE file must?
    /// A figure travels the SSH channel as one command's stdout; a dropped
    /// channel hands back a clean prefix, `UIImage(data:)` happily decodes the
    /// top rows, and an unvalidated cache would then serve the half-figure
    /// forever (2026-08-28, user's black-bottom screenshots). JPEG must close
    /// with FFD9, PNG must carry IEND in its tail; rarer formats pass — for
    /// them the size check at the transfer layer is the only referee.
    nonisolated static func looksComplete(_ data: Data) -> Bool {
        guard data.count > 64 else { return false }
        let head = [UInt8](data.prefix(4))
        let tail = [UInt8](data.suffix(16))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            let iend: [UInt8] = [0x49, 0x45, 0x4E, 0x44]
            return (0...(tail.count - 4)).contains { Array(tail[$0..<$0 + 4]) == iend }
        }
        if head.starts(with: [0xFF, 0xD8]) {
            return tail.suffix(2) == [0xFF, 0xD9]
        }
        return true
    }

    /// Every figure id referenced by an issue's markdown (arxiv html image URLs).
    nonisolated static func ids(inMarkdown text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for m in text.matches(of: /https:\/\/arxiv\.org\/html\/(\d{4}\.\d{4,5})v/) {
            let id = String(m.1)
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private var cacheDir: URL { Self.cacheDirURL }

    /// One canonical spot on disk; static so Settings and the launch-time trim
    /// can reach it without spinning up the store.
    nonisolated static var cacheDirURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("pervio-figures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Disk maintenance (Settings + launch trim)

    nonisolated static func diskUsage(at dir: URL = cacheDirURL) -> Int64 {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.reduce(Int64(0)) { sum, name in
            let attrs = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            return sum + Int64((attrs?[.size] as? Int) ?? 0)
        }
    }

    nonisolated static func clearDisk(at dir: URL = cacheDirURL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// The automatic janitor (run once per launch, off the main actor): figures
    /// untouched for `maxAge` go first; if the pile still tops `maxBytes`, the
    /// least-recently-used go next. "Used" = file mtime, which `image(for:)`
    /// refreshes on every disk hit — cheap LRU without a database. iOS may also
    /// purge this Caches dir on disk pressure; this trim just keeps us polite
    /// long before the system has to.
    nonisolated static func trimDisk(at dir: URL = cacheDirURL,
                                     maxBytes: Int64 = 500 * 1024 * 1024,
                                     maxAge: TimeInterval = 90 * 24 * 3600,
                                     now: Date = Date()) {
        let fm = FileManager.default
        var entries: [(url: URL, mtime: Date, size: Int64)] = []
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let url = dir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            entries.append((url,
                            (attrs[.modificationDate] as? Date) ?? .distantPast,
                            Int64((attrs[.size] as? Int) ?? 0)))
        }
        let cutoff = now.addingTimeInterval(-maxAge)
        for e in entries where e.mtime < cutoff {
            try? fm.removeItem(at: e.url)
        }
        var kept = entries.filter { $0.mtime >= cutoff }.sorted { $0.mtime < $1.mtime }
        var total = kept.reduce(Int64(0)) { $0 + $1.size }
        while total > maxBytes, let oldest = kept.first {
            try? fm.removeItem(at: oldest.url)
            total -= oldest.size
            kept.removeFirst()
        }
    }

    /// The arXiv paper id inside a figure URL, or nil for any other URL.
    nonisolated static func paperId(from url: URL) -> String? {
        guard url.host == "arxiv.org" else { return nil }
        let m = url.path.range(of: #"/html/(\d{4}\.\d{4,5})v"#, options: .regularExpression)
        guard let m else { return nil }
        return String(url.path[m].dropFirst("/html/".count).dropLast(1))
    }

    func image(for id: String) async -> UIImage? {
        if let running = inFlight[id] { return await running.value }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            let file = self.cacheDir.appendingPathComponent(id)
            if let data = try? Data(contentsOf: file) {
                if Self.looksComplete(data), let img = UIImage(data: data) {
                    // Touch = "still in use"; the launch trim reads mtime as LRU.
                    try? FileManager.default.setAttributes(
                        [.modificationDate: Date()], ofItemAtPath: file.path)
                    return img
                }
                // A poisoned cache heals itself: drop the stump, refetch below.
                try? FileManager.default.removeItem(at: file)
            }
            guard let fetch = self.sshFetcher, let data = await fetch(id),
                  Self.looksComplete(data), let img = UIImage(data: data) else { return nil }
            try? data.write(to: file)
            return img
        }
        inFlight[id] = task
        let out = await task.value
        inFlight[id] = nil
        return out
    }
}


/// Fullscreen pinch-zoom viewer for a method figure. UIScrollView does the
/// gesture math (SwiftUI's MagnificationGesture reimplementation is strictly
/// worse); double-tap toggles 1x/2.5x, swipe-down or the button dismisses.
struct ZoomableFigureViewer: View {
    let image: UIImage
    let caption: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ZoomableScrollView { Image(uiImage: image).resizable().scaledToFit() }
            VStack(alignment: .trailing, spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2).foregroundStyle(.white.opacity(0.85))
                }
                .padding(.top, 8).padding(.trailing, 14)
                Spacer()
                if !caption.isEmpty {
                    Text(caption).font(.caption).foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 20).padding(.bottom, 14)
                }
            }
        }
    }
}

private struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    @ViewBuilder let content: Content

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 5
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.delegate = context.coordinator
        sv.backgroundColor = .clear
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        sv.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: sv.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: sv.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: sv.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: sv.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: sv.frameLayoutGuide.widthAnchor),
            host.view.heightAnchor.constraint(equalTo: sv.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.zoomTarget = host.view
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        sv.addGestureRecognizer(tap)
        return sv
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var zoomTarget: UIView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { zoomTarget }
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? UIScrollView else { return }
            sv.setZoomScale(sv.zoomScale > 1.01 ? 1 : 2.5, animated: true)
        }
    }
}
