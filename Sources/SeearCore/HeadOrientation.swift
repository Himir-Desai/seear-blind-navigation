import Foundation

/// Gravity-aligned full attitude with an automatic yaw origin. Tilt never rebases
/// or invalidates tracking. Only a genuine motion gap starts a new generation.
public struct HeadOrientation {
    public private(set) var pose = HeadPose(rotation:.identity,yaw:0)
    public var yaw: Double { pose.yaw }
    public private(set) var sampled = 0.0
    public private(set) var generation = 0
    public private(set) var referenceStarted = 0.0
    private var referenceYaw = 0.0
    private var history: [(time: Double, pose: HeadPose)] = []
    public init() {}
    public mutating func ingest(rotation raw: Rotation3D, at time: Double) {
        guard raw.valid, time.isFinite, time > sampled else { return }
        let rawHeading = raw.heading(fallback:Geometry.wrap(yaw+referenceYaw))
        if generation == 0 || time-sampled > 0.5 {
            referenceYaw = rawHeading; referenceStarted = time
            history.removeAll(); generation += 1
        }
        sampled = time
        let rotation = raw.followed(by:.heading(-referenceYaw))
        pose = HeadPose(rotation:rotation,yaw:rotation.heading(fallback:pose.yaw))
        history.append((time,pose))
        if history.count > 180 { history.removeFirst(history.count-180) }
    }
    /// Legacy Euler input retained for yaw regression fixtures; production uses quaternion attitude.
    public mutating func ingest(rawYaw: Double, pitch: Double, at time: Double) {
        guard rawYaw.isFinite, pitch.isFinite else { return }
        ingest(rotation:Rotation3D.axis(SIMD3(1,0,0),degrees:pitch).followed(by:.heading(-rawYaw)),at:time)
    }
    public func pose(at time: Double) -> HeadPose? {
        guard time.isFinite, let first = history.first, let last = history.last,
              time >= first.time-0.08, time <= last.time+0.08 else { return nil }
        if time <= first.time { return first.pose }
        if time >= last.time { return last.pose }
        for i in 1..<history.count where history[i].time >= time {
            let a = history[i-1], b = history[i]
            guard b.time-a.time <= 0.15 else { return nil }
            let t = (time-a.time)/(b.time-a.time)
            let q = a.pose.rotation.interpolated(to:b.pose.rotation,fraction:t)
            let fallback = Geometry.wrap(a.pose.yaw+Geometry.wrap(b.pose.yaw-a.pose.yaw)*t)
            return HeadPose(rotation:q,yaw:q.heading(fallback:fallback))
        }
        return nil
    }
    public func yaw(at timestamp: Double) -> Double? { pose(at:timestamp)?.yaw }
    public func isFresh(at time: Double) -> Bool { generation > 0 && time >= sampled && time-sampled < 0.5 }
}
