import CoreMotion
import Foundation
import SeearCore

final class HeadTracker {
    private let manager = CMHeadphoneMotionManager()
    private var retry: Timer?
    private(set) var rawYaw = 0.0, pitch = 0.0, sampled = 0.0
    private var neutral = 0.0, sign = -1.0, neutralPitch = 0.0
    private var history = YawHistory()
    private(set) var calibrationStep = 0
    private(set) var calibrated = false
    var yaw: Double { Geometry.wrap((rawYaw - neutral) * sign) }
    var pitchOffset: Double { pitch - neutralPitch }
    var fresh: Bool { sampled > 0 && ProcessInfo.processInfo.systemUptime - sampled < 0.5 }
    var usable: Bool { fresh && calibrated }
    func yaw(at timestamp: Double) -> Double? {
        guard calibrated, let raw = history.yaw(at:timestamp) else { return nil }
        return Geometry.wrap((raw-neutral)*sign)
    }
    var instruction: String {
        if !fresh { return "Connect and wear motion-capable AirPods" }
        if calibrated { return String(format: "Head tracking active · yaw %+.0f°", yaw) }
        return calibrationStep == 1 ? "Turn your head RIGHT about 30°, then press Calibrate" : "Face straight ahead, then press Calibrate"
    }
    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") != nil else { return }
        manager.startConnectionStatusUpdates()
        begin()
        retry = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.begin() }
    }
    private func begin() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.rawYaw = motion.attitude.yaw * 180 / .pi
            self.pitch = motion.attitude.pitch * 180 / .pi
            self.sampled = motion.timestamp
            self.history.record(yaw:self.rawYaw,at:motion.timestamp)
        }
    }
    @discardableResult func calibrate() -> String {
        guard fresh else { return "Head tracking is unavailable" }
        if calibrationStep == 1 {
            let turn = Geometry.wrap(rawYaw - neutral)
            guard abs(turn) >= 15 && abs(turn) <= 100 else { return "Turn right between 15 and 100 degrees" }
            sign = turn > 0 ? 1 : -1; calibrated = true; calibrationStep = 0
            return "Calibrated. Face your walking direction and press Set forward."
        }
        neutral = rawYaw; neutralPitch = pitch; calibrated = false; calibrationStep = 1
        return "Turn your head right about thirty degrees, then press Calibrate again."
    }
    func stop() { retry?.invalidate(); manager.stopDeviceMotionUpdates(); manager.stopConnectionStatusUpdates() }
}
