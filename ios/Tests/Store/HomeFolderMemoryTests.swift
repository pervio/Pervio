import XCTest
@testable import Pervio

/// The home page's folders open on a tap and stay the way they were left,
/// per server (2026-10-17). Collapsed is the default.
final class HomeFolderMemoryTests: XCTestCase {
    private let a = UUID(), b = UUID()

    override func tearDown() {
        for id in [a, b] { UserDefaults.standard.removeObject(forKey: HomeFolderMemory.key(id)) }
        super.tearDown()
    }

    func testNothingOpenUntilTheFirstTap() {
        XCTAssertEqual(HomeFolderMemory.expanded(for: a), [])
    }

    func testAnOpenedFolderComesBackOnTheNextVisit() {
        HomeFolderMemory.set(["/home/me/Pervio"], for: a)
        XCTAssertEqual(HomeFolderMemory.expanded(for: a), ["/home/me/Pervio"])
        HomeFolderMemory.set(["/home/me/Pervio", "/home/me/Altas"], for: a)
        XCTAssertEqual(HomeFolderMemory.expanded(for: a), ["/home/me/Pervio", "/home/me/Altas"])
    }

    func testClosingTheLastFolderLeavesNothingBehind() {
        HomeFolderMemory.set(["/x"], for: a)
        HomeFolderMemory.set([], for: a)
        XCTAssertNil(UserDefaults.standard.object(forKey: HomeFolderMemory.key(a)))
        XCTAssertEqual(HomeFolderMemory.expanded(for: a), [])
    }

    func testEachServerRemembersItsOwnFolders() {
        HomeFolderMemory.set(["/x"], for: a)
        XCTAssertEqual(HomeFolderMemory.expanded(for: b), [], "another server entry starts collapsed")
        HomeFolderMemory.set(["/y"], for: b)
        XCTAssertEqual(HomeFolderMemory.expanded(for: a), ["/x"])
    }
}
