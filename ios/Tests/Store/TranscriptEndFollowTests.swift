import XCTest
@testable import Pervio

/// The transcript's follow decision: a reader at the end keeps following through
/// a landing chunk and through the keyboard coming up; only a finger leaves.
final class TranscriptEndFollowTests: XCTestCase {
    func testNearTheEndAlwaysFollows() {
        XCTAssertTrue(TranscriptEndFollow.atEnd(near: true, wasAtEnd: false, grew: false, viewportShrank: false))
        XCTAssertTrue(TranscriptEndFollow.atEnd(near: true, wasAtEnd: true, grew: false, viewportShrank: false))
    }

    func testALandingChunkDoesNotUnfollow() {
        XCTAssertTrue(TranscriptEndFollow.atEnd(near: false, wasAtEnd: true, grew: true, viewportShrank: false))
    }

    /// The regression (a tester, 2026-10-18): the keyboard shrinks the viewport,
    /// the end moves out of view with nobody scrolling — still following, so the
    /// focus handler's scroll lands and the latest reply stays above the keyboard.
    func testTheKeyboardComingUpDoesNotUnfollow() {
        XCTAssertTrue(TranscriptEndFollow.atEnd(near: false, wasAtEnd: true, grew: false, viewportShrank: true))
    }

    func testAFingerScrollUnfollows() {
        XCTAssertFalse(TranscriptEndFollow.atEnd(near: false, wasAtEnd: true, grew: false, viewportShrank: false))
    }

    func testAReaderAwayFromTheEndStaysAwayWhileContentGrows() {
        XCTAssertFalse(TranscriptEndFollow.atEnd(near: false, wasAtEnd: false, grew: true, viewportShrank: false))
        XCTAssertFalse(TranscriptEndFollow.atEnd(near: false, wasAtEnd: false, grew: false, viewportShrank: true))
    }
}
