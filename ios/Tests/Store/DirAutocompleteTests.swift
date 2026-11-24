import XCTest
@testable import Pervio

/// Path completion for the directory field: the typed text splits into the
/// directory to list and the prefix to match; only sub-folders complete, in the
/// typed spelling, one level at a time.
final class DirAutocompleteTests: XCTestCase {
    private func entries(_ names: [(String, Bool)]) throws -> [ServerFileEntry] {
        let json = "[" + names.map { #"{"name":"\#($0.0)","type":"\#($0.1 ? "dir" : "file")","size":1,"mtime":1}"# }.joined(separator: ",") + "]"
        return try JSONDecoder().decode([ServerFileEntry].self, from: Data(json.utf8))
    }

    func testSplitTypedPath() {
        XCTAssertEqual(DirAutocomplete.split("").parent, "~")
        XCTAssertEqual(DirAutocomplete.split("~/Doc").parent, "~")
        XCTAssertEqual(DirAutocomplete.split("~/Doc").prefix, "Doc")
        XCTAssertEqual(DirAutocomplete.split("~/Documents/").parent, "~/Documents")
        XCTAssertEqual(DirAutocomplete.split("~/Documents/").prefix, "")
        XCTAssertEqual(DirAutocomplete.split("/srv/pro").parent, "/srv")
        XCTAssertEqual(DirAutocomplete.split("/s").parent, "/")
        XCTAssertEqual(DirAutocomplete.split("Doc").prefix, "Doc", "a bare word completes under the home")
    }

    func testCompletionsAreFoldersOnlyPrefixedCaseInsensitiveInTypedSpelling() throws {
        let e = try entries([("Documents", true), ("Downloads", true), ("docs", true), ("notes.txt", false), (".hidden", true)])
        XCTAssertEqual(DirAutocomplete.completions(typed: "~/Doc", entries: e), ["~/Documents/", "~/docs/"])
        XCTAssertEqual(DirAutocomplete.completions(typed: "~/", entries: e), ["~/Documents/", "~/Downloads/", "~/docs/"],
                       "a trailing slash lists every sub-folder; hidden ones and files never complete")
        XCTAssertEqual(DirAutocomplete.completions(typed: "/s", entries: try entries([("srv", true)])), ["/srv/"])
        XCTAssertEqual(DirAutocomplete.completions(typed: "~/Documents/", entries: try entries([("Pervio", true)])), ["~/Documents/Pervio/"])
    }
}
