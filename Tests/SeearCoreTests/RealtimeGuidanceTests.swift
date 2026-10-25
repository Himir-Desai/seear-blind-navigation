import XCTest
@testable import SeearCore

final class RealtimeGuidanceTests: XCTestCase {
    func item(_ id: String = "chosen", score: Double = 0.75, bearing: Double = 0, classified: Double = 10) -> Observation {
        Observation(label:"backpack",confidence:score,bearing:bearing,distance:2,box:[0.2,0.2,0.5,0.7],
                    trackID:id,classificationCaptured:classified,trackingQuality:0.9)
    }
    func scene(_ feed: String = "front", time: Double = 10, objects: [Observation] = [], range: Double? = nil, searchID: String? = nil) -> SceneFrame {
        SceneFrame(feed:feed,captured:time,yaw:0,target:"backpack",objects:objects,
                   obstacles:range.map { [Observation(label:"obstacle",confidence:1,bearing:0,distance:$0)] } ?? [],searchID:searchID)
    }
    func engine() -> GuidanceEngine {
        let engine = GuidanceEngine(); engine.search("backpack")
        engine.ingest(scene("feet")); return engine
    }
    func testInitialAcquisitionWaitsForBothScansAndSelectsTheHigherScore() {
        let e = engine()
        func stats(_ classified: Double?) -> PerceptionStats {
            PerceptionStats(depthMS:100,trackingMS:5,detectorMS:300,mode:"tracking",classified:classified,detectorBusy:true,classifierError:"")
        }
        var front = scene(objects:[item(score:0.75)],searchID:e.searchID)
        front.perception = stats(10)
        var feet = scene("feet",searchID:e.searchID); feet.perception = stats(nil)
        e.ingest(front); e.ingest(feet)
        XCTAssertNil(e.evaluate(now:10,yaw:0,tracking:true).target)
        XCTAssertFalse(e.evaluate(now:10,yaw:0,tracking:true).fault)
        feet = scene("feet",time:10.1,objects:[item("higher",score:0.8,classified:10.1)],searchID:e.searchID)
        feet.perception = stats(10.1); e.ingest(feet)
        XCTAssertNotNil(e.evaluate(now:10.1,yaw:0,tracking:true).target)
        XCTAssertEqual(e.selectedTrackID,"higher")
    }
    func testStableTrackIdentitySurvivesLargeImageAndBearingMotion() {
        let e = engine(); e.ingest(scene(objects:[item()]))
        XCTAssertNotNil(e.evaluate(now:10,yaw:0,tracking:true).target)
        var moved = item(bearing:60); moved.distance = 0.8; moved.box = [0.7,0.1,0.9,0.3]
        e.ingest(scene(time:10.2,objects:[moved,item("other",score:0.8)]))
        XCTAssertEqual(e.evaluate(now:10.2,yaw:0,tracking:true).target?.bearing,60)
        XCTAssertEqual(e.selectedTrackID,"chosen")
    }
    func testNearbyDifferentTrackCannotStealTheLockWithinScoreMargin() {
        let e = engine(); e.ingest(scene(objects:[item()]))
        _ = e.evaluate(now:10,yaw:0,tracking:true)
        e.ingest(scene(time:10.1,objects:[item("distractor",score:0.8)]))
        XCTAssertNil(e.evaluate(now:10.1,yaw:0,tracking:true).target)
        XCTAssertEqual(e.selectedTrackID,"chosen")
        e.ingest(scene(time:10.2,objects:[item("distractor",score:0.9)]))
        XCTAssertNotNil(e.evaluate(now:10.2,yaw:0,tracking:true).target)
        XCTAssertEqual(e.selectedTrackID,"distractor")
    }
    func testFreshTrackingImagesCannotExtendAnExpiredClassification() {
        let e = engine(); e.ingest(scene(objects:[item()]))
        XCTAssertNotNil(e.evaluate(now:10,yaw:0,tracking:true).target)
        e.ingest(scene("feet",time:12.6)); e.ingest(scene(time:12.6,objects:[item()],range:0.15))
        let state = e.evaluate(now:12.6,yaw:0,tracking:true)
        XCTAssertFalse(state.fault); XCTAssertNil(state.target); XCTAssertNotNil(state.obstacle)
    }
    func testReclassificationStillAppliesTheConfidenceFloor() {
        let e = engine(); e.ingest(scene(objects:[item()]))
        _ = e.evaluate(now:10,yaw:0,tracking:true)
        e.ingest(scene(time:10.2,objects:[item(score:0.5,classified:10.2)]))
        XCTAssertNil(e.evaluate(now:10.2,yaw:0,tracking:true).target)
        e.ingest(scene(time:10.3,objects:[item(score:0.7,classified:10.2)]))
        XCTAssertNotNil(e.evaluate(now:10.3,yaw:0,tracking:true).target)
    }
    func testRepeatedFindRejectsAnInflightResultFromTheOldSearch() {
        let e = engine(); let old = e.searchID; e.search("backpack")
        e.ingest(scene(objects:[item()],searchID:old))
        XCTAssertNil(e.evaluate(now:10,yaw:0,tracking:true).target)
        e.ingest(scene(time:10.1,objects:[item()],searchID:e.searchID))
        XCTAssertNotNil(e.evaluate(now:10.1,yaw:0,tracking:true).target)
    }
    func testDistantObstacleIsSilentAndNeverDucksTheItem() {
        for range in [0.5001,0.8,1.2,2,3] {
            let e = engine(); e.ingest(scene(objects:[item()],range:range))
            let state = e.evaluate(now:10,yaw:0,tracking:true)
            XCTAssertNil(state.obstacle); XCTAssertEqual(state.target?.level,1)
            XCTAssertEqual(ObstacleSound.gain(range),0)
        }
    }
    func testSoftWarningNeedsTwoDistinctFramesAndLeavesItemAtFullLevel() {
        let e = engine(); e.ingest(scene(objects:[item()],range:0.4))
        XCTAssertNil(e.evaluate(now:10,yaw:0,tracking:true).obstacle)
        // Repeated ticks and duplicate captures are not independent confirmation.
        e.ingest(scene(objects:[item()],range:0.4))
        XCTAssertNil(e.evaluate(now:10.01,yaw:0,tracking:true).obstacle)
        e.ingest(scene(time:10.1,objects:[item()],range:0.4))
        let state = e.evaluate(now:10.1,yaw:0,tracking:true)
        XCTAssertNotNil(state.obstacle); XCTAssertEqual(state.target?.level,1)
        e.ingest(scene(time:10.2,objects:[item()]))
        XCTAssertNil(e.evaluate(now:10.2,yaw:0,tracking:true).obstacle)
    }
    func testEmergencyIsImmediateAndSuppressesAudioWhileKeepingTheItemTrack() {
        let e = engine(); e.ingest(scene(objects:[item()],range:0.2))
        let state = e.evaluate(now:10,yaw:0,tracking:true)
        XCTAssertNotNil(state.obstacle); XCTAssertNil(state.target)
        XCTAssertEqual(e.selectedTrackID,"chosen"); XCTAssertNotNil(e.selectedItem)
        e.ingest(scene(time:10.1,objects:[item()]))
        XCTAssertEqual(e.evaluate(now:10.1,yaw:0,tracking:true).target?.level,1)
    }
    func testWarningConfirmationDoesNotSurviveADataGap() {
        let e = engine(); e.ingest(scene(range:0.4))
        e.ingest(scene(time:10.7,range:0.4))
        XCTAssertNil(e.evaluate(now:10.7,yaw:0,tracking:true).obstacle)
    }
    func testSoundGainAndDutyStayLowUntilEmergencyRange() {
        XCTAssertEqual(ObstacleSound.rate(0.4),1.0/3)
        XCTAssertLessThan(ObstacleSound.gain(0.4),0.03)
        XCTAssertGreaterThan(ObstacleSound.gain(0.2),5*ObstacleSound.gain(0.20001))
        XCTAssertGreaterThan(ObstacleSound.gain(0.1),ObstacleSound.gain(0.2))
        XCTAssertEqual(ObstacleSound.gain(.nan),0)
        XCTAssertEqual(ObstacleSound.gain(0),0)
    }
    func testVisualTrackingDoesNotBypassFreshDepthOrMotion() {
        let e = engine(); e.ingest(scene(objects:[item()]))
        XCTAssertTrue(e.evaluate(now:11.6,yaw:0,tracking:true).fault)
        XCTAssertTrue(e.evaluate(now:10,yaw:0,tracking:false).fault)
    }
}
