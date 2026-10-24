import CoreMotion
import Foundation
import SeearCore

final class HeadTracker {
    private let manager = CMHeadphoneMotionManager()
    private var retry: Timer?
    private var orientation = HeadOrientation()
    var yaw: Double { orientation.yaw }
    var pose: HeadPose { orientation.pose }
    var generation: Int { orientation.generation }
    var referenceStarted: Double { orientation.referenceStarted }
    var usable: Bool { orientation.isFresh(at:ProcessInfo.processInfo.systemUptime) }
    func pose(at timestamp: Double) -> HeadPose? { orientation.pose(at:timestamp) }
    var instruction: String {
        if !usable { return "Waiting for AirPods motion · reference initializes automatically" }
        return String(format: "3D head tracking · yaw %+.0f° · tilt compensated", yaw)
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
            let q = motion.attitude.quaternion
            self.orientation.ingest(rotation:.headphone(x:q.x,y:q.y,z:q.z,w:q.w),at:motion.timestamp)
        }
    }
    func stop() { retry?.invalidate(); manager.stopDeviceMotionUpdates(); manager.stopConnectionStatusUpdates() }
}
