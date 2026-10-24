import XCTest
@testable import SeearCore

final class GuidanceTests: XCTestCase {
    func frame(_ feed: String, time: Double = 10, yaw: Double = 0, target: String = "backpack",
               objects: [Observation] = [], obstacles: [Observation] = [], coverage: Double = 1) -> SceneFrame {
        SceneFrame(feed:feed,captured:time,yaw:yaw,target:target,objects:objects,obstacles:obstacles,coverage:coverage)
    }
    func ready() -> GuidanceEngine { let e = GuidanceEngine(); e.ingest(frame("front")); e.ingest(frame("feet")); return e }
    let bag = Observation(label:"backpack",confidence:0.8,bearing:15,distance:2)
    func testBothFeedsRequiredAndNoStaleSafetyClaim() {
        let e = GuidanceEngine(); e.ingest(frame("front"))
        XCTAssertTrue(e.evaluate(now:10,yaw:0,tracking:true).fault)
        e.ingest(frame("feet")); XCTAssertFalse(e.evaluate(now:10,yaw:0,tracking:true).fault)
        XCTAssertTrue(e.evaluate(now:11.6,yaw:0,tracking:true).fault)
        XCTAssertTrue(e.evaluate(now:9,yaw:0,tracking:true).fault)
    }
    func testCaptureTimeNotInferenceCompletionControlsFreshness() {
        let e = ready(); e.search("backpack"); e.ingest(frame("front",objects:[bag]))
        XCTAssertNotNil(e.evaluate(now:10.5,yaw:0,tracking:true).target)
        XCTAssertNil(e.evaluate(now:12,yaw:0,tracking:true).target)
    }
    func testTrackingLossAndOutOfViewMute() {
        let e = ready(); e.search("backpack"); e.ingest(frame("front",objects:[bag]))
        XCTAssertTrue(e.evaluate(now:10,yaw:0,tracking:false).fault)
        XCTAssertTrue(e.evaluate(now:10,yaw:60,tracking:true).fault)
    }
    func testBodyCorridorUsesFrameYawAndNewHeadYawDoesNotMoveSource() {
        let e = ready(); e.search("backpack")
        let o = Observation(label:"obstacle",confidence:1,bearing:-30,distance:2)
        e.ingest(frame("front",yaw:30,objects:[bag],obstacles:[o]))
        let result = e.evaluate(now:10,yaw:30,tracking:true)
        XCTAssertEqual(result.obstacle!.bearing,0,accuracy:1e-8)
        XCTAssertEqual(result.target!.bearing,45,accuracy:1e-8)
        XCTAssertEqual(result.target!.level,0.2)
        XCTAssertEqual(e.evaluate(now:10,yaw:40,tracking:true).target!.bearing,45)
    }
    func testImminentObstaclePreemptsItemButSearchStaysActive() {
        let e = ready(); e.search("backpack")
        e.ingest(frame("feet",objects:[bag],obstacles:[Observation(label:"obstacle",confidence:1,bearing:0,distance:0.8)]))
        let result = e.evaluate(now:10,yaw:0,tracking:true)
        XCTAssertNotNil(result.obstacle); XCTAssertNil(result.target); XCTAssertEqual(e.target,"backpack")
        e.ingest(frame("feet",objects:[bag])); XCTAssertNotNil(e.evaluate(now:10,yaw:0,tracking:true).target)
    }
    func testOffPathAndInvalidDepthDoNotBecomeHazards() {
        let e = ready()
        e.ingest(frame("front",obstacles:[Observation(label:"chair",confidence:1,bearing:80,distance:2),
            Observation(label:"bad",confidence:1,bearing:0,distance:.nan)]))
        XCTAssertNil(e.evaluate(now:10,yaw:0,tracking:true).obstacle)
    }
    func testOldQueryAndOutOfOrderResponsesCannotReplaceCurrentTarget() {
        let e = ready(); e.search("white cane"); e.ingest(frame("front",objects:[bag]))
        XCTAssertNil(e.evaluate(now:10,yaw:0,tracking:true).target)
        e.ingest(frame("front",time:9,coverage:0)); XCTAssertEqual(e.frames["front"]?.captured,10)
    }
    func testTargetLossDoesNotReplayOrSwitchToDifferentInstance() {
        let e = ready(); e.search("backpack"); e.ingest(frame("front",objects:[bag]))
        XCTAssertNotNil(e.evaluate(now:10,yaw:0,tracking:true).target)
        e.ingest(frame("front",objects:[Observation(label:"backpack",confidence:0.99,bearing:-30,distance:2)]))
        XCTAssertNil(e.evaluate(now:10,yaw:0,tracking:true).target)
        e.ingest(frame("front",objects:[bag])); XCTAssertNotNil(e.evaluate(now:10,yaw:0,tracking:true).target)
    }
    func testPoorDepthCoveragePausesGuidance() {
        let e = ready(); e.ingest(frame("feet",coverage:0.2))
        XCTAssertTrue(e.evaluate(now:10,yaw:0,tracking:true).fault)
    }
    func testWakeGrammarAndTargetAliases() {
        XCTAssertEqual(VoiceCommand.parse("Hey Seear, where is my bag pack?"),.find("backpack"))
        XCTAssertEqual(VoiceCommand.parse("Hey seer find the white cane"),.find("white cane"))
        XCTAssertEqual(VoiceCommand.parse("hey see ear stop"),.cancel)
        XCTAssertEqual(VoiceCommand.parse("hey Seear set forward"),.forward)
        XCTAssertNil(VoiceCommand.parse("where is my backpack"))
        XCTAssertNil(VoiceCommand.parse("Hey Seear"))
    }
    func testInheritedHybridDistanceAndFOVMappings() {
        XCTAssertEqual(SoundMapping.visibility(angle:45,distance:2),1)
        XCTAssertEqual(SoundMapping.visibility(angle:90,distance:2),pow(10,-3.0/20),accuracy:1e-8)
        XCTAssertEqual(SoundMapping.visibility(angle:180,distance:2),0)
        XCTAssertEqual(SoundMapping.visibility(angle:180,distance:0.2),1)
        XCTAssertGreaterThan(SoundMapping.rate(0.5),SoundMapping.rate(4))
        XCTAssertEqual(SoundMapping.gain(0.5),1.5)
        XCTAssertEqual(Geometry.relative(-179,yaw:179),2)
    }
    func testCaptureYawInterpolationAcrossSeamAndStalledMotion() {
        var history = YawHistory()
        history.record(yaw:179,at:10); history.record(yaw:-179,at:10.02)
        XCTAssertEqual(abs(history.yaw(at:10.01)!),180,accuracy:1e-8)
        XCTAssertNil(history.yaw(at:11))
        history.record(yaw:0,at:11)
        XCTAssertNil(history.yaw(at:10.5))
        history.record(yaw:30,at:9) // Out-of-order motion cannot replace valid history.
        XCTAssertEqual(history.yaw(at:11),0)
    }
}
