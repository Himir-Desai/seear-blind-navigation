import XCTest
@testable import SeearCore

final class RoomMapSnapshotTests: XCTestCase {
    func snapshot() throws -> RoomMapSnapshot {
        let json = """
        {"status":"tracking","updated":10,"landmarks":30,"confirmed":30,"savedMaps":1,"keyframes":1,"position":[0,1.6,0],"heading":[0,0,-1],"points":[],"path":[],"inliers":30,"units":"estimated_meters","detail":"test","resolution":0.15,"floor":[],"occupied":[],"walls":[]}
        """
        return try JSONDecoder().decode(RoomMapSnapshot.self,from:Data(json.utf8))
    }
    func testOnlyFreshAcceptedPoseIsDisplayed() throws {
        var value = try snapshot()
        XCTAssertTrue(value.poseIsFresh(at:11))
        XCTAssertFalse(value.poseIsFresh(at:13))
        XCTAssertFalse(value.poseIsFresh(at:9))
        value.status = "lost"
        XCTAssertFalse(value.poseIsFresh(at:11))
    }
    func testMalformedOptionalGeometryIsRejectedWithoutIntegerOverflow() throws {
        var value = try snapshot()
        value.floor = [[Int.min,0,1]]
        XCTAssertFalse(value.valid)
        value.floor = []; value.position = [.nan,0,0]
        XCTAssertFalse(value.valid)
        value.position = nil; value.confirmed = 31
        XCTAssertFalse(value.valid)
    }
}
