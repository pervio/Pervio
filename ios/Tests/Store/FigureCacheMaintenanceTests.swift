import XCTest
@testable import Pervio

/// The figure cache janitor (Settings 存储 + launch trim). All three operations
/// take an explicit directory so these tests run against a scratch folder and
/// never touch the app's real Caches.
final class FigureCacheMaintenanceTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("figcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func drop(_ name: String, bytes: Int, agedDays: Double = 0) throws {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        if agedDays > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-agedDays * 24 * 3600)],
                ofItemAtPath: url.path)
        }
    }

    func testUsageSumsEveryFile() throws {
        try drop("a", bytes: 1000)
        try drop("b", bytes: 2500)
        XCTAssertEqual(FigureStore.diskUsage(at: dir), 3500)
    }

    func testClearEmptiesTheFolder() throws {
        try drop("a", bytes: 1000)
        try drop("b", bytes: 1000)
        FigureStore.clearDisk(at: dir)
        XCTAssertEqual(FigureStore.diskUsage(at: dir), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path),
                      "clear removes contents, not the folder")
    }

    func testTrimDropsStaleFiguresAndKeepsFreshOnes() throws {
        try drop("stale", bytes: 1000, agedDays: 120)
        try drop("fresh", bytes: 1000, agedDays: 3)
        FigureStore.trimDisk(at: dir)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left, ["fresh"])
    }

    func testTrimEnforcesSizeCapOldestFirst() throws {
        try drop("oldest", bytes: 600, agedDays: 30)
        try drop("middle", bytes: 600, agedDays: 10)
        try drop("newest", bytes: 600, agedDays: 1)
        FigureStore.trimDisk(at: dir, maxBytes: 1300)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(left, ["middle", "newest"],
                       "over the cap, the least-recently-used figure goes first")
    }

    func testTrimUnderBothLimitsTouchesNothing() throws {
        try drop("a", bytes: 500, agedDays: 5)
        try drop("b", bytes: 500, agedDays: 50)
        FigureStore.trimDisk(at: dir)
        XCTAssertEqual(FigureStore.diskUsage(at: dir), 1000)
    }
}
