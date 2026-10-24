import Foundation

/// An arbitrary automatic reference is sufficient: only capture-to-playback
/// rotation matters. It never defines a walking direction or limits turns.
public struct HeadOrientation {
    public private(set) var yaw = 0.0
    public private(set) var pitchOffset = 0.0
    public private(set) var sampled = 0.0
    public private(set) var generation = 0
    public private(set) var referenceStarted = 0.0
    private var referenceYaw = 0.0, referencePitch = 0.0
    private var history = YawHistory()
    // The established AirPods convention: P4's recorded calibration also reports -1.
    private let yawSign = -1.0
    public init() {}
    public mutating func ingest(rawYaw: Double, pitch: Double, at time: Double) {
        guard rawYaw.isFinite, pitch.isFinite, time.isFinite, time > sampled else { return }
        if generation == 0 || time-sampled > 0.5 {
            referenceYaw = rawYaw; referencePitch = pitch; referenceStarted = time
            history = YawHistory(); generation += 1
        }
        sampled = time
        yaw = Geometry.wrap((rawYaw-referenceYaw)*yawSign)
        pitchOffset = pitch-referencePitch
        history.record(yaw:rawYaw,at:time)
    }
    public func yaw(at timestamp: Double) -> Double? {
        guard generation > 0, let raw = history.yaw(at:timestamp) else { return nil }
        return Geometry.wrap((raw-referenceYaw)*yawSign)
    }
    public func isFresh(at time: Double) -> Bool {
        generation > 0 && time >= sampled && time-sampled < 0.5
    }
}
