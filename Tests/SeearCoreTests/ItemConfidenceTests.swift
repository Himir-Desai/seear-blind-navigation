import XCTest
@testable import SeearCore

final class ItemConfidenceTests: XCTestCase {
    func item(_ score: Double, bearing: Double = 0) -> Observation {
        Observation(label:"backpack",confidence:score,bearing:bearing,distance:2)
    }
    func frame(_ feed: String, _ score: Double?, at time: Double = 10, bearing: Double = 0) -> SceneFrame {
        SceneFrame(feed:feed,captured:time,yaw:0,target:"backpack",objects:score.map { [item($0,bearing:bearing)] } ?? [],obstacles:[])
    }
    func engine(score: Double?) -> GuidanceEngine {
        let e = GuidanceEngine(); e.search("backpack")
        e.ingest(frame("front",score)); e.ingest(frame("feet",nil))
        return e
    }
    func testStrictAcquisitionFloorAndNoItemInView() {
        let e = engine(score:0.49)
        XCTAssertNil(e.evaluate(now:10,yaw:0,tracking:true).target); XCTAssertNil(e.selectedItem)
        e.ingest(frame("front",0.50,at:10.1))
        XCTAssertNil(e.evaluate(now:10.1,yaw:0,tracking:true).target)
        e.ingest(frame("front",0.5001,at:10.2))
        XCTAssertNotNil(e.evaluate(now:10.2,yaw:0,tracking:true).target)
        e.ingest(frame("front",nil,at:10.3))
        XCTAssertNil(e.evaluate(now:10.3,yaw:0,tracking:true).target); XCTAssertNil(e.selectedItem)
    }
    func testDropToFloorRemovesCueAndBoxWithoutMutingHazards() {
        let e = engine(score:0.75)
        XCTAssertNotNil(e.evaluate(now:10,yaw:0,tracking:true).target)
        var feet = frame("feet",nil,at:10.2)
        feet.obstacles = [Observation(label:"obstacle",confidence:1,bearing:0,distance:2)]
        e.ingest(feet); e.ingest(frame("front",0.50,at:10.2))
        let state = e.evaluate(now:10.2,yaw:0,tracking:true)
        XCTAssertFalse(state.fault); XCTAssertNotNil(state.obstacle)
        XCTAssertNil(state.target); XCTAssertNil(e.selectedItem)
        e.ingest(frame("front",0.65,at:10.3))
        XCTAssertNotNil(e.evaluate(now:10.3,yaw:0,tracking:true).target)
    }
    func testSwitchUsesCurrentScoreNotFixedMinimumPlusMargin() {
        let e = engine(score:0.70)
        _ = e.evaluate(now:10,yaw:0,tracking:true)
        e.ingest(frame("feet",0.75,at:10.1,bearing:40))
        XCTAssertEqual(e.evaluate(now:10.1,yaw:0,tracking:true).target?.bearing,0)
        e.ingest(frame("feet",0.80,at:10.2,bearing:40))
        XCTAssertEqual(e.evaluate(now:10.2,yaw:0,tracking:true).target?.bearing,0) // Equal margin is insufficient.
        e.ingest(frame("feet",0.8001,at:10.3,bearing:40))
        XCTAssertEqual(e.evaluate(now:10.3,yaw:0,tracking:true).target?.bearing,40)
        XCTAssertEqual(e.selectedItem?.feed,"feet")
        e.ingest(frame("front",0.90,at:10.4))
        XCTAssertEqual(e.evaluate(now:10.4,yaw:0,tracking:true).target?.bearing,40)
        e.ingest(frame("front",0.901,at:10.5))
        XCTAssertEqual(e.evaluate(now:10.5,yaw:0,tracking:true).target?.bearing,0)
    }
    func testWeakCurrentScoreUpdatesComparisonButCannotProduceCue() {
        let e = engine(score:0.90)
        _ = e.evaluate(now:10,yaw:0,tracking:true)
        e.ingest(frame("front",0.40,at:10.2))
        XCTAssertNil(e.evaluate(now:10.2,yaw:0,tracking:true).target)
        e.ingest(frame("feet",0.49,at:10.3,bearing:40))
        XCTAssertNil(e.evaluate(now:10.3,yaw:0,tracking:true).target)
        e.ingest(frame("feet",0.51,at:10.4,bearing:40))
        XCTAssertEqual(e.evaluate(now:10.4,yaw:0,tracking:true).target?.bearing,40)
    }
    func testMissingCurrentUsesLastObservedScoreAndDoesNotReplay() {
        let e = engine(score:0.70)
        _ = e.evaluate(now:10,yaw:0,tracking:true)
        e.ingest(frame("front",nil,at:10.2)); e.ingest(frame("feet",0.75,at:10.2,bearing:40))
        XCTAssertNil(e.evaluate(now:10.2,yaw:0,tracking:true).target); XCTAssertNil(e.selectedItem)
        e.ingest(frame("feet",0.81,at:10.3,bearing:40))
        XCTAssertEqual(e.evaluate(now:10.3,yaw:0,tracking:true).target?.bearing,40)
    }
    func testOlderChallengerCannotReplaceANewerCurrentObservation() {
        let e = engine(score:0.65)
        _ = e.evaluate(now:10,yaw:0,tracking:true)
        e.ingest(frame("feet",0.99,at:10.1,bearing:40)); e.ingest(frame("front",0.60,at:10.2))
        XCTAssertEqual(e.evaluate(now:10.2,yaw:0,tracking:true).target?.bearing,0)
        e.ingest(frame("feet",0.80,at:10.3,bearing:40))
        XCTAssertEqual(e.evaluate(now:10.3,yaw:0,tracking:true).target?.bearing,40)
    }
    func testConfiguredFloorAndMarginAreAppliedByGuidance() {
        let e = engine(score:0.75)
        e.itemConfidencePolicy = ItemConfidencePolicy(minimum:0.80,switchMargin:0.05)!
        XCTAssertNil(e.evaluate(now:10,yaw:0,tracking:true).target)
        e.ingest(frame("front",0.85,at:10.1))
        XCTAssertNotNil(e.evaluate(now:10.1,yaw:0,tracking:true).target)
        e.ingest(frame("feet",0.89,at:10.2,bearing:40))
        XCTAssertEqual(e.evaluate(now:10.2,yaw:0,tracking:true).target?.bearing,0)
        e.ingest(frame("feet",0.91,at:10.3,bearing:40))
        XCTAssertEqual(e.evaluate(now:10.3,yaw:0,tracking:true).target?.bearing,40)
    }
    func testPolicyRejectsInvalidValuesAndHandlesDecimalBoundaries() {
        for values in [(Double.nan,0.1),(0.5,Double.infinity),(-0.1,0.1),(1,0),(0.5,-0.1),(0.9,0.1)] {
            XCTAssertNil(ItemConfidencePolicy(minimum:values.0,switchMargin:values.1))
        }
        let policy = ItemConfidencePolicy.demo
        XCTAssertFalse(policy.accepts(0.5)); XCTAssertFalse(policy.accepts(.nan)); XCTAssertFalse(policy.accepts(1.01))
        XCTAssertFalse(policy.permitsSwitch(to:0.8,from:0.7))
        XCTAssertFalse(policy.permitsSwitch(to:0.80000001,from:0.7))
        XCTAssertTrue(policy.permitsSwitch(to:0.80001,from:0.7))
        XCTAssertFalse(policy.permitsSwitch(to:1,from:0.95)) // No silent clipping of the margin.
        let strict = ItemConfidencePolicy(minimum:0.85,switchMargin:0.05)!
        XCTAssertFalse(strict.permitsSwitch(to:0.84,from:0.70))
    }
}
