import Foundation

/// Debug context only. Nothing in GuidanceEngine depends on a room map or saved scan.
public struct RoomMapSnapshot: Codable {
    public struct Wall: Codable {
        public var start: [Double]
        public var end: [Double]
        public var observations: Int
    }
    public var status: String
    public var updated: Double
    public var mapID: String?
    public var landmarks: Int
    public var confirmed: Int
    public var savedMaps: Int
    public var keyframes: Int
    public var position: [Double]?
    public var heading: [Double]?
    public var points: [[Double]]
    public var path: [[Double]]
    public var inliers: Int
    public var errorPX: Double?
    public var units: String
    public var detail: String
    public var resolution: Double
    public var floor: [[Int]]
    public var occupied: [[Int]]
    public var walls: [Wall]
    public var valid: Bool {
        func vector(_ v: [Double], _ count: Int) -> Bool { v.count == count && v.allSatisfy { $0.isFinite && abs($0) <= 1000 } }
        func cells(_ values: [[Int]]) -> Bool {
            values.count <= 6000 && values.allSatisfy { $0.count == 3 && (-2047...2047).contains($0[0]) && (-2047...2047).contains($0[1]) && (1...65535).contains($0[2]) }
        }
        return updated.isFinite && units == "estimated_meters" && (0...3000).contains(landmarks) &&
            (0...landmarks).contains(confirmed) && (0...32).contains(savedMaps) && (0...64).contains(keyframes) &&
            points.count <= 500 && points.allSatisfy { vector($0,3) } && path.count <= 160 && path.allSatisfy { vector($0,3) } &&
            (position.map { vector($0,3) } ?? true) && (heading.map { vector($0,3) } ?? true) &&
            (errorPX.map { $0.isFinite && $0 >= 0 } ?? true) && resolution == 0.15 && cells(floor) && cells(occupied) &&
            walls.count <= 32 && walls.allSatisfy { vector($0.start,2) && vector($0.end,2) && (1...65535).contains($0.observations) }
    }
    public func poseIsFresh(at time: Double) -> Bool {
        valid && ["tracking","relocalized"].contains(status) && time >= updated && time-updated < 2.5 && position != nil
    }
}
