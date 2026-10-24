import CoreMotion
import Foundation
import SeearCore

final class HeadTracker {
    private let manager = CMHeadphoneMotionManager()
    private var retry: Timer?
    private var orientation = HeadOrientation()
    var yaw: Double { orientation.yaw }
    var pitchOffset: Double { orientation.pitchOffset }
    var generation: Int { orientation.generation }
    var referenceStarted: Double { orientation.referenceStarted }
    var usable: Bool { orientation.isFresh(at:ProcessInfo.processInfo.systemUptime) }
    func yaw(at timestamp: Double) -> Double? {
        orientation.yaw(at:timestamp)
    }
    var instruction: String {
        if !usable { return "Waiting for AirPods motion · reference initializes automatically" }
        return String(format: "Head tracking active · yaw %+.0f° · camera defines forward", yaw)
    }
    func beginSession() { orientation = HeadOrientation() }
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
            self.orientation.ingest(rawYaw:motion.attitude.yaw * 180 / .pi,
                                    pitch:motion.attitude.pitch * 180 / .pi,at:motion.timestamp)
        }
    }
    func stop() { retry?.invalidate(); manager.stopDeviceMotionUpdates(); manager.stopConnectionStatusUpdates() }
}
