import XCTest
@testable import SeearCore

final class HeadTiltTests: XCTestCase {
    func attitude(pitch: Double, roll: Double, yaw: Double = 0) -> Rotation3D {
        Rotation3D.axis(SIMD3(0,0,1),degrees:roll)
            .followed(by:.axis(SIMD3(1,0,0),degrees:pitch)).followed(by:.heading(yaw))
    }
    func testHeadphoneAxesAndTurnSign() {
        let half = sqrt(0.5)
        let rightTurn = Rotation3D.headphone(x:0,y:0,z:-half,w:half)
        let forward = rightTurn.applied(to:SIMD3(0,0,-1))
        XCTAssertEqual(forward.x,1,accuracy:1e-8)
        let nodUp = Rotation3D.headphone(x:half,y:0,z:0,w:half).applied(to:SIMD3(0,0,-1))
        XCTAssertEqual(nodUp.y,1,accuracy:1e-8)
    }
    func testInitialTiltIsGravityAlignedRatherThanSubtractedAsANeutralPitch() {
        var tracker = HeadOrientation()
        tracker.ingest(rotation:attitude(pitch:35,roll:25,yaw:125),at:10)
        XCTAssertEqual(tracker.yaw,0,accuracy:1e-8)
        let worldUp = tracker.pose.rotation.applied(to:attitude(pitch:35,roll:25).inverse.applied(to:SIMD3(0,1,0)))
        XCTAssertEqual(worldUp.y,1,accuracy:1e-8)
        XCTAssertGreaterThan(tracker.pose.rotation.applied(to:SIMD3(0,0,-1)).y,0.5)
    }
    func testTiltsIncludingVerticalAndInvertedDoNotResetOrPauseGuidance() {
        var tracker = HeadOrientation()
        tracker.ingest(rotation:.identity,at:10)
        let engine = GuidanceEngine()
        for (i,pitch) in [-179.0,-100,-90,-40,0,40,90,100,179].enumerated() {
            let time = 10.05+Double(i)*0.05
            tracker.ingest(rotation:attitude(pitch:pitch,roll:Double(i)*40,yaw:70),at:time)
            XCTAssertTrue(tracker.isFresh(at:time))
            XCTAssertEqual(tracker.generation,1)
            for feed in ["front","feet"] {
                engine.ingest(SceneFrame(feed:feed,captured:time,yaw:tracker.yaw,target:"",objects:[],obstacles:[],rotation:tracker.pose.rotation))
            }
            XCTAssertFalse(engine.evaluate(now:time,yaw:tracker.yaw,tracking:true).fault)
            let original = SIMD3(0.4,-1.2,-2.0)
            let headRay = tracker.pose.rotation.inverse.applied(to:original)
            let level = tracker.pose.tilt.applied(to:headRay)
            let restored = Rotation3D.heading(tracker.yaw).applied(to:level)
            XCTAssertLessThan(simdLength(restored-original),1e-8)
        }
    }
    private func simdLength(_ v: SIMD3<Double>) -> Double { sqrt(v.x*v.x+v.y*v.y+v.z*v.z) }
    func testFullAttitudeHistoryInterpolatesAndStillRejectsMissingMotion() {
        var tracker = HeadOrientation()
        tracker.ingest(rotation:.identity,at:10)
        tracker.ingest(rotation:attitude(pitch:80,roll:0),at:10.1)
        let midpoint = tracker.pose(at:10.05)!.rotation.applied(to:SIMD3(0,0,-1))
        XCTAssertEqual(midpoint.y,sin(40 * .pi/180),accuracy:1e-8)
        XCTAssertEqual(tracker.pose(at:10)!.rotation,.identity)
        tracker.ingest(rotation:Rotation3D(x:.nan),at:10.2)
        XCTAssertEqual(tracker.sampled,10.1)
        XCTAssertNil(tracker.pose(at:10.4))
        XCTAssertFalse(tracker.isFresh(at:10.7))
        tracker.ingest(rotation:attitude(pitch:-70,roll:80),at:11)
        XCTAssertEqual(tracker.generation,2)
        XCTAssertNil(tracker.pose(at:10))
        tracker.ingest(rotation:.identity,at:11.3)
        XCTAssertNil(tracker.pose(at:11.15))
    }
    func testFullAttitudeInterpolationCrossesYawAndQuaternionSeams() {
        var tracker = HeadOrientation()
        tracker.ingest(rotation:.identity,at:9.95)
        tracker.ingest(rotation:.heading(179),at:10)
        let next = Rotation3D.heading(-179)
        tracker.ingest(rotation:Rotation3D(x:-next.x,y:-next.y,z:-next.z,w:-next.w),at:10.1)
        let capture = tracker.pose(at:10.05)!
        XCTAssertEqual(abs(capture.yaw),180,accuracy:1e-8)
        XCTAssertEqual(capture.rotation.applied(to:SIMD3(0,0,-1)).z,1,accuracy:1e-8)
    }
    func testItemLockSurvivesBoxMovementFromPitchAndRoll() {
        let engine = GuidanceEngine(); engine.search("backpack")
        let first = Observation(label:"backpack",confidence:0.8,bearing:10,elevation:-10,distance:2,box:[0.1,0.1,0.3,0.3])
        engine.ingest(SceneFrame(feed:"front",captured:10,yaw:0,target:"backpack",objects:[first],obstacles:[],rotation:.identity))
        engine.ingest(SceneFrame(feed:"feet",captured:10,yaw:0,target:"backpack",objects:[],obstacles:[]))
        XCTAssertNotNil(engine.evaluate(now:10,yaw:0,tracking:true).target)
        var moved = first; moved.box = [0.6,0.6,0.8,0.8]
        engine.ingest(SceneFrame(feed:"front",captured:10.1,yaw:0,target:"backpack",objects:[moved],obstacles:[],rotation:attitude(pitch:-30,roll:25)))
        XCTAssertEqual(engine.evaluate(now:10.1,yaw:0,tracking:true).target?.bearing,10)
        XCTAssertEqual(engine.selectedItem?.observation.box,moved.box)
    }
}
