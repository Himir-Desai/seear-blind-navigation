import XCTest
@testable import SeearCore

final class ItemDirectionAnchorTests: XCTestCase {
    func testSmallAngleNoiseDoesNotMoveTheStoredDirection() {
        var anchor = ItemDirectionAnchor(bearing:30,elevation:-20,captured:10)!
        for (i,delta) in [1.0,-1.0,2.0,-2.0].enumerated() {
            anchor.observe(bearing:30+delta,elevation:-20+delta/4,captured:10.1+Double(i)*0.1)
        }
        XCTAssertEqual(anchor.bearing,30,accuracy:1e-8)
        XCTAssertEqual(anchor.elevation,-20,accuracy:1e-8)
    }
    func testSingleOutlierAndDuplicateCaptureCannotCorrectTheAnchor() {
        var anchor = ItemDirectionAnchor(bearing:0,elevation:0,captured:10)!
        anchor.observe(bearing:45,elevation:20,captured:10.1)
        anchor.observe(bearing:45,elevation:20,captured:10.1)
        XCTAssertEqual(anchor.bearing,0,accuracy:1e-8)
        anchor.observe(bearing:0,elevation:0,captured:10.2)
        XCTAssertEqual(anchor.bearing,0,accuracy:1e-8)
    }
    func testConsistentParallaxCorrectsYawAndElevation() {
        var anchor = ItemDirectionAnchor(bearing:0,elevation:0,captured:10)!
        anchor.observe(bearing:15,elevation:-10,captured:10.1)
        XCTAssertEqual(anchor.bearing,0,accuracy:1e-8)
        anchor.observe(bearing:20,elevation:-15,captured:10.3)
        XCTAssertEqual(anchor.bearing,17.5,accuracy:0.05)
        XCTAssertEqual(anchor.elevation,-12.5,accuracy:0.05)
    }
    func testOpposingChangesAndLongGapsCannotConfirmAnOutlier() {
        var anchor = ItemDirectionAnchor(bearing:0,elevation:0,captured:10)!
        anchor.observe(bearing:15,elevation:0,captured:10.1)
        anchor.observe(bearing:-15,elevation:0,captured:10.2)
        XCTAssertEqual(anchor.bearing,0,accuracy:1e-8)
        anchor.observe(bearing:-15,elevation:0,captured:11.3)
        XCTAssertEqual(anchor.bearing,0,accuracy:1e-8)
        anchor.observe(bearing:0,elevation:0,captured:9)
        XCTAssertEqual(anchor.captured,11.3)
    }
    func testYawSeamVerticalDirectionsAndPassingTheItemStayFinite() {
        var seam = ItemDirectionAnchor(bearing:179,elevation:0,captured:10)!
        seam.observe(bearing:-179,elevation:0,captured:10.1)
        XCTAssertEqual(seam.bearing,179,accuracy:1e-8) // 2°, not a 358° jump.
        var vertical = ItemDirectionAnchor(bearing:170,elevation:89.5,captured:10)!
        vertical.observe(bearing:-10,elevation:89.5,captured:10.1)
        XCTAssertEqual(vertical.elevation,89.5,accuracy:1e-8)
        var passed = ItemDirectionAnchor(bearing:0,elevation:0,captured:10)!
        passed.observe(bearing:180,elevation:0,captured:10.1)
        passed.observe(bearing:180,elevation:0,captured:10.2)
        XCTAssertEqual(abs(passed.bearing),180,accuracy:1e-8)
        XCTAssertTrue(passed.elevation.isFinite)
        XCTAssertNil(ItemDirectionAnchor(bearing:.nan,elevation:0,captured:10))
    }
    func frame(_ feed: String, time: Double, yaw: Double = 0, bearing: Double = 30, elevation: Double = -10,
               distance: Double = 2, id: String = "chosen", score: Double = 0.8, hazard: Observation? = nil) -> SceneFrame {
        let item = Observation(label:"backpack",confidence:score,bearing:bearing,elevation:elevation,distance:distance,
                               box:[0.2,0.2,0.4,0.6],trackID:id,classificationCaptured:10,trackingQuality:0.9)
        return SceneFrame(feed:feed,captured:time,yaw:yaw,target:"backpack",objects:feed == "front" ? [item] : [],obstacles:hazard.map { [$0] } ?? [])
    }
    func engine() -> GuidanceEngine {
        let e = GuidanceEngine(); e.search("backpack")
        e.ingest(frame("feet",time:10)); e.ingest(frame("front",time:10))
        _ = e.evaluate(now:10,yaw:0,tracking:true); return e
    }
    func testEngineUpdatesDistanceWhileDirectionAndHeadTurnCompensationRemainAnchored() {
        let e = engine()
        // Same inertial bearing (31°) after a 60° head turn, with live range.
        e.ingest(frame("front",time:10.2,yaw:60,bearing:-29,elevation:-9,distance:1.2))
        let result = e.evaluate(now:10.2,yaw:60,tracking:true)
        XCTAssertEqual(result.target!.bearing,30,accuracy:1e-8)
        XCTAssertEqual(result.target!.elevation,-10,accuracy:1e-8)
        XCTAssertEqual(result.target!.distance,1.2)
        XCTAssertEqual(Geometry.relative(result.target!.bearing,yaw:60),-30,accuracy:1e-8)
        XCTAssertEqual(e.selectedItem!.observation.bearing,-29) // Overlay stays on the actual image track.
    }
    func testNewSelectedIdentityResetsDirectionImmediatelyAndSearchClearsIt() {
        let e = engine()
        e.ingest(frame("front",time:10.2,bearing:-45,elevation:5,id:"new",score:0.95))
        let result = e.evaluate(now:10.2,yaw:0,tracking:true)
        XCTAssertEqual(result.target!.bearing,-45,accuracy:1e-8)
        XCTAssertEqual(result.target!.elevation,5,accuracy:1e-8)
        e.search("white cane"); XCTAssertNil(e.itemDirectionAnchor)
    }
    func testAnchorDoesNotReplayLostItemAndLowFeetEmergencyKeepsAnchorWhilePreemptingAudio() {
        let e = engine()
        let low = Observation(label:"low_obstacle",confidence:1,bearing:0,elevation:-85,distance:0.15)
        e.ingest(frame("feet",time:10.1,hazard:low))
        let urgent = e.evaluate(now:10.1,yaw:0,tracking:true)
        XCTAssertNil(urgent.target); XCTAssertTrue(urgent.obstacle!.lowObstacle)
        XCTAssertEqual(urgent.obstacle?.feed,"feet"); XCTAssertNotNil(e.itemDirectionAnchor)
        e.ingest(SceneFrame(feed:"front",captured:10.2,yaw:0,target:"backpack",objects:[],obstacles:[]))
        e.ingest(frame("feet",time:10.2))
        XCTAssertNil(e.evaluate(now:10.2,yaw:0,tracking:true).target)
        XCTAssertNotNil(e.itemDirectionAnchor)
        e.reset(); XCTAssertNil(e.itemDirectionAnchor)
    }
}
