import Foundation

/// Time-align camera exposure timestamps with motion samples, including the ±180° seam.
public struct YawHistory {
    private var samples: [(time: Double, yaw: Double)] = []
    public init() {}
    public mutating func record(yaw: Double, at time: Double) {
        guard yaw.isFinite, time.isFinite, samples.last.map({ time > $0.time }) ?? true else { return }
        samples.append((time,yaw))
        if samples.count > 180 { samples.removeFirst(samples.count-180) }
    }
    public func yaw(at time: Double) -> Double? {
        guard time.isFinite, let first = samples.first, let last = samples.last,
              time >= first.time-0.08, time <= last.time+0.08 else { return nil }
        if time <= first.time { return first.yaw }
        if time >= last.time { return last.yaw }
        for index in 1..<samples.count where samples[index].time >= time {
            let a = samples[index-1], b = samples[index]
            guard b.time-a.time <= 0.15 else { return nil }
            return Geometry.wrap(a.yaw + Geometry.wrap(b.yaw-a.yaw)*(time-a.time)/(b.time-a.time))
        }
        return nil
    }
}
