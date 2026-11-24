import Foundation

/// The app's own pages on the web, in one place so a move of the site is one
/// edit. Nothing here is fetched by the app — these open in the browser.
enum SiteLinks {
    static let base = "https://pervio.dev"

    /// The privacy policy. App Review 5.1.1(i) wants it reachable inside the app
    /// as well as from the store page. One page holds both languages, Chinese
    /// first and English under the `#en` anchor (web/privacy.html).
    static func privacy(_ lang: PromptLanguage = .current) -> URL {
        URL(string: base + "/privacy.html" + (lang == .english ? "#en" : ""))!
    }
}
