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
    func testTrackingLossMutesWithoutImposingAHeadingLimit() {
        let e = ready(); e.search("backpack"); e.ingest(frame("front",objects:[bag]))
        XCTAssertTrue(e.evaluate(now:10,yaw:0,tracking:false).fault)
        XCTAssertFalse(e.evaluate(now:10,yaw:60,tracking:true).fault)
        XCTAssertFalse(e.evaluate(now:10,yaw:180,tracking:true).fault)
    }
    func testCameraForwardUsesCaptureYawAndNewHeadYawDoesNotMoveSource() {
        let e = ready(); e.search("backpack")
        let o = Observation(label:"obstacle",confidence:1,bearing:0,distance:0.4)
        e.ingest(frame("front",time:10.1,yaw:30,objects:[bag],obstacles:[o]))
        e.ingest(frame("front",time:10.2,yaw:30,objects:[bag],obstacles:[o]))
        let result = e.evaluate(now:10.2,yaw:30,tracking:true)
        XCTAssertEqual(result.obstacle!.bearing,30,accuracy:1e-8)
        XCTAssertEqual(result.target!.bearing,45,accuracy:1e-8)
        XCTAssertEqual(result.target!.level,1)
        XCTAssertEqual(e.evaluate(now:10.2,yaw:40,tracking:true).target!.bearing,45)
    }

    func testImminentObstaclePreemptsItemButSearchStaysActive() {
        let e = ready(); e.search("backpack")
        e.ingest(frame("feet",objects:[bag],obstacles:[Observation(label:"obstacle",confidence:1,bearing:0,distance:0.15)]))
        let result = e.evaluate(now:10,yaw:0,tracking:true)
        XCTAssertNotNil(result.obstacle); XCTAssertEqual(result.obstacle?.feed,"feet")
        XCTAssertNil(result.target); XCTAssertEqual(e.target,"backpack")
        XCTAssertEqual(e.selectedItem?.observation,bag)
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
    func testTargetLossDoesNotReplayOrSwitchWithinTheMargin() {
        let e = ready(); e.search("backpack"); e.ingest(frame("front",objects:[bag]))
        XCTAssertNotNil(e.evaluate(now:10,yaw:0,tracking:true).target)
        e.ingest(frame("front",objects:[Observation(label:"backpack",confidence:0.85,bearing:-30,distance:2)]))
        XCTAssertNil(e.evaluate(now:10,yaw:0,tracking:true).target)
        e.ingest(frame("front",objects:[bag])); XCTAssertNotNil(e.evaluate(now:10,yaw:0,tracking:true).target)
    }
    func testInitialAcquisitionChoosesHighestValidScoreAcrossBothFeeds() {
        let e = ready(); e.search("backpack")
        e.ingest(frame("front",objects:[bag,Observation(label:"backpack",confidence:.nan,bearing:0,distance:1),
            Observation(label:"backpack",confidence:1,bearing:0,distance:.nan),
            Observation(label:"white cane",confidence:1,bearing:0,distance:2)]))
        let best = Observation(label:"backpack",confidence:0.95,bearing:-25,distance:3)
        e.ingest(frame("feet",objects:[best]))
        let state = e.evaluate(now:10,yaw:0,tracking:true)
        XCTAssertEqual(state.target?.bearing,-25)
        XCTAssertEqual(e.selectedItem?.feed,"feet")
        XCTAssertEqual(e.selectedItem?.observation,best)
    }
    func testKeepsChosenItemUntilChallengerClearsTheMargin() {
        let e = ready(); e.search("backpack")
        let chosen = Observation(label:"backpack",confidence:0.9,bearing:0,distance:2,box:[0.25,0.2,0.45,0.8])
        let other = Observation(label:"backpack",confidence:0.7,bearing:3,distance:2,box:[0.6,0.2,0.8,0.8])
        e.ingest(frame("front",objects:[other,chosen]))
        XCTAssertNotNil(e.evaluate(now:10,yaw:0,tracking:true).target)
        var moved = chosen; moved.bearing = 2; moved.confidence = 0.7; moved.box = [0.27,0.2,0.47,0.8]
        var competitor = other; competitor.confidence = 0.8
        e.ingest(frame("front",time:10.2,objects:[competitor,moved]))
        e.ingest(frame("feet",time:10.2,objects:[competitor]))
        XCTAssertEqual(e.evaluate(now:10.2,yaw:0,tracking:true).target?.bearing,2)
        XCTAssertEqual(e.selectedItem?.observation,moved)
        e.ingest(frame("front",time:10.3,objects:[competitor]))
        XCTAssertNil(e.evaluate(now:10.3,yaw:0,tracking:true).target)
        XCTAssertNil(e.selectedItem)
        e.search("backpack") // Explicit Find can select a candidate without the switching margin.
        XCTAssertEqual(e.evaluate(now:10.3,yaw:0,tracking:true).target?.bearing,competitor.bearing)
    }
    func testStaleFramesAndTrackingFaultDoNotReleaseChosenItem() {
        let e = ready(); e.search("backpack"); e.ingest(frame("front",objects:[bag]))
        XCTAssertNotNil(e.evaluate(now:10,yaw:0,tracking:true).target)
        XCTAssertTrue(e.evaluate(now:12,yaw:0,tracking:true).fault)
        XCTAssertNil(e.selectedItem)
        XCTAssertTrue(e.evaluate(now:12,yaw:0,tracking:false).fault)
        let other = Observation(label:"backpack",confidence:0.85,bearing:-30,distance:2)
        e.ingest(frame("front",time:12,objects:[other])); e.ingest(frame("feet",time:12))
        XCTAssertNil(e.evaluate(now:12,yaw:0,tracking:true).target)
        e.ingest(frame("front",time:12.1,objects:[bag,other]))
        XCTAssertEqual(e.evaluate(now:12.1,yaw:0,tracking:true).target?.bearing,bag.bearing)
    }
    func testPauseResumeKeepsTheChosenItemAndResetRequiresFindAgain() {
        let e = ready(); e.search("backpack"); e.ingest(frame("front",objects:[bag]))
        XCTAssertNotNil(e.evaluate(now:10,yaw:0,tracking:true).target)
        e.pause(); XCTAssertNil(e.selectedItem); e.resume()
        let other = Observation(label:"backpack",confidence:0.85,bearing:-30,distance:2)
        e.ingest(frame("front",time:11,objects:[other,bag])); e.ingest(frame("feet",time:11))
        XCTAssertEqual(e.evaluate(now:11,yaw:0,tracking:true).target?.bearing,bag.bearing)
        e.reset() // New motion reference cannot reuse old absolute bearings.
        e.ingest(frame("front",time:12,objects:[other,bag])); e.ingest(frame("feet",time:12))
        XCTAssertNil(e.evaluate(now:12,yaw:0,tracking:true).target)
        XCTAssertTrue(e.needsItemReselection)
        e.search("backpack")
        XCTAssertEqual(e.evaluate(now:12,yaw:0,tracking:true).target?.bearing,other.bearing)
        e.search(""); XCTAssertNil(e.selectedItem); XCTAssertFalse(e.needsItemReselection)
    }
    func testPoorDepthCoveragePausesGuidance() {
        let e = ready(); e.ingest(frame("feet",coverage:0.2))
        XCTAssertTrue(e.evaluate(now:10,yaw:0,tracking:true).fault)
    }
    func testWakeGrammarAndTargetAliases() {
        XCTAssertEqual(VoiceCommand.parse("Hey Seear, where is my bag pack?"),.find("backpack"))
        XCTAssertEqual(VoiceCommand.parse("Hey seer find the white cane"),.find("white cane"))
        XCTAssertEqual(VoiceCommand.parse("hey see ear stop"),.cancel)
        XCTAssertEqual(VoiceCommand.parse("hey Seear pause guidance"),.pauseGuidance)
        XCTAssertEqual(VoiceCommand.parse("hey Seear resume guidance"),.resumeGuidance)
        XCTAssertEqual(VoiceCommand.parse("hey Seear stop guidance"),.pauseGuidance)
        XCTAssertEqual(VoiceCommand.parse("hey Seear start guidance"),.resumeGuidance)
        XCTAssertNil(VoiceCommand.parse("hey Seear set forward"))
        XCTAssertNil(VoiceCommand.parse("pause guidance"))
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
    func testFreshCameraForwardFollowsLeftRightAndAboutTurns() {
        for yaw in [-179.0, -90, 0, 90, 179, 180, 270, 360] {
            let e = GuidanceEngine()
            for feed in ["front","feet"] {
                e.ingest(frame(feed,yaw:yaw,obstacles:[Observation(label:"wall",confidence:1,bearing:0,distance:0.15)]))
            }
            let state = e.evaluate(now:10,yaw:yaw,tracking:true)
            XCTAssertFalse(state.fault,"Turn \(yaw) must not need a forward reset")
            XCTAssertEqual(Geometry.relative(state.obstacle!.bearing,yaw:yaw),0,accuracy:1e-8)
        }
    }
    func testOldForwardHazardIsNotMistakenForNewForwardAfterTurn() {
        let e = ready()
        e.ingest(frame("front",obstacles:[Observation(label:"wall",confidence:1,bearing:0,distance:0.15)]))
        XCTAssertNil(e.evaluate(now:10,yaw:90,tracking:true).obstacle)
        e.ingest(frame("feet",yaw:90,obstacles:[Observation(label:"chair",confidence:1,bearing:0,distance:0.15)]))
        XCTAssertEqual(e.evaluate(now:10,yaw:90,tracking:true).obstacle?.bearing,90)
    }
    func testTargetStaysAtCaptureDirectionDuringTurnThenRefreshes() {
        let e = ready(); e.search("backpack")
        e.ingest(frame("front",yaw:90,objects:[bag]))
        let state = e.evaluate(now:10,yaw:120,tracking:true)
        XCTAssertFalse(state.fault)
        XCTAssertEqual(Geometry.relative(state.target!.bearing,yaw:120),-15,accuracy:1e-8)
        var refreshed = bag; refreshed.bearing = -15
        e.ingest(frame("front",time:10.1,yaw:120,objects:[refreshed]))
        XCTAssertEqual(e.evaluate(now:10.1,yaw:120,tracking:true).target!.bearing,105,accuracy:1e-8)
    }
    func testVoicePauseResumeRetainsSearchAndRequiresFreshViews() {
        let e = ready(); e.search("backpack"); e.ingest(frame("front",objects:[bag]))
        if VoiceCommand.parse("Hey Seear pause guidance") == .pauseGuidance { e.pause() }
        XCTAssertTrue(e.isPaused)
        e.ingest(frame("front",objects:[bag],obstacles:[bag])) // In-flight response while paused.
        let paused = e.evaluate(now:10,yaw:0,tracking:true)
        XCTAssertNil(paused.target); XCTAssertNil(paused.obstacle)
        if VoiceCommand.parse("Hey Seear resume guidance") == .resumeGuidance { e.resume() }
        XCTAssertEqual(e.target,"backpack"); XCTAssertFalse(e.isPaused)
        XCTAssertTrue(e.evaluate(now:10,yaw:0,tracking:true).fault)
        e.ingest(frame("front",objects:[bag])); e.ingest(frame("feet"))
        XCTAssertNotNil(e.evaluate(now:10,yaw:0,tracking:true).target)
    }
    func testAutomaticMotionOriginAndFullTurnsRequireNoCalibration() {
        var orientation = HeadOrientation()
        XCTAssertFalse(orientation.isFresh(at:10))
        orientation.ingest(rawYaw:-137,pitch:5,at:10)
        XCTAssertTrue(orientation.isFresh(at:10.01))
        XCTAssertEqual(orientation.yaw,0,accuracy:1e-8)
        orientation.ingest(rawYaw:133,pitch:5,at:10.1) // Right turn 90°, wrapping raw yaw.
        XCTAssertEqual(orientation.yaw,90,accuracy:1e-8)
        orientation.ingest(rawYaw:43,pitch:5,at:10.2)
        XCTAssertEqual(abs(orientation.yaw),180,accuracy:1e-8)
        orientation.ingest(rawYaw:-47,pitch:5,at:10.3)
        XCTAssertEqual(orientation.yaw,-90,accuracy:1e-8)
        orientation.ingest(rawYaw:-137,pitch:5,at:10.4)
        XCTAssertEqual(orientation.yaw,0,accuracy:1e-8)
        XCTAssertEqual(orientation.generation,1) // Ordinary turns never rebase the reference.
    }
    func testReconnectionReinitializesReferenceAndRejectsOldCaptureYaw() {
        var orientation = HeadOrientation()
        orientation.ingest(rawYaw:-137,pitch:5,at:10)
        XCTAssertFalse(orientation.isFresh(at:10.6))
        orientation.ingest(rawYaw:42,pitch:8,at:11)
        XCTAssertEqual(orientation.generation,2)
        XCTAssertEqual(orientation.referenceStarted,11)
        XCTAssertEqual(orientation.yaw,0,accuracy:1e-8)
        XCTAssertNil(orientation.yaw(at:10))
        orientation.ingest(rawYaw:10,pitch:5,at:9) // Reject out-of-order motion.
        XCTAssertEqual(orientation.referenceStarted,11)
    }
}
