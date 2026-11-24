import XCTest
@testable import Pervio

/// Three things the App Store asks of the bundle itself, pinned on the built
/// app (the unit tests are hosted by it, so `Bundle.main` is the real thing):
/// it is an iPhone app, it carries a privacy manifest that says what the code
/// does, and the privacy policy it links to is the page on the site.
///
/// Each of them fails silently otherwise: a device family put back to "1,2"
/// still builds and still uploads, and after the first release can never be
/// taken away again; a manifest that falls out of the resources phase is only
/// noticed in an e-mail from Apple after an upload.
final class StoreReadinessTests: XCTestCase {

    // MARK: iPhone only

    func testTheAppIsBuiltForIPhoneOnly() throws {
        let family = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIDeviceFamily") as? [Int],
                                   "the built app has no UIDeviceFamily")
        XCTAssertEqual(family, [1], "1 = iPhone, 2 = iPad; the app ships for iPhone only")
    }

    // MARK: Privacy manifest

    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                                "PrivacyInfo.xcprivacy is not in the app bundle")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    func testTheManifestDeclaresNoTrackingAndNoCollection() throws {
        let m = try manifest()
        XCTAssertEqual(m["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((m["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)
        // "Collected" is data the developer can get at afterwards. The app sends
        // nothing to a Pervio server (the push token goes to the person's own
        // Mac over SSH), so the list is empty — and has to be revisited the day
        // the app itself talks to a server of ours.
        XCTAssertEqual((m["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)
    }

    /// The two "required reason" API families the app's own code calls, each
    /// with the reason that is true of it: UserDefaults for its own settings
    /// (CA92.1), and file dates of the figure cache inside its own container
    /// (C617.1 — FigureStore trims by modification date). A new family in the
    /// code (disk space, uptime, active keyboards) needs a line in the manifest
    /// and one here.
    func testTheManifestNamesTheApisTheCodeUsesAndWhy() throws {
        let rows = try XCTUnwrap(try manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var declared: [String: [String]] = [:]
        for row in rows {
            let type = try XCTUnwrap(row["NSPrivacyAccessedAPIType"] as? String)
            declared[type] = try XCTUnwrap(row["NSPrivacyAccessedAPITypeReasons"] as? [String])
        }
        XCTAssertEqual(declared, [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
        ])
    }

    // MARK: The privacy policy link

    func testThePrivacyLinkIsThePageOnTheSiteInTheReadersLanguage() {
        let zh = SiteLinks.privacy(.chinese), en = SiteLinks.privacy(.english)
        XCTAssertEqual(zh.absoluteString, "https://pervio.dev/privacy.html")
        // One page holds both languages; English sits under the #en anchor.
        XCTAssertEqual(en.absoluteString, "https://pervio.dev/privacy.html#en")
        XCTAssertEqual(L.settingsPrivacyPolicy(.chinese), "隐私政策")
        XCTAssertEqual(L.settingsPrivacyPolicy(.english), "Privacy Policy")
    }
}
