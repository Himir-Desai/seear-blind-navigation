import Foundation
import simd

/// Gravity-level inertial direction, independent of current head attitude.
/// Range stays live; distinct, coherent visual observations can correct parallax.
public struct ItemDirectionAnchor {
    private var direction: SIMD3<Double>
    private var pending: (direction: SIMD3<Double>, captured: Double)?
    public private(set) var captured: Double
    public var bearing: Double { atan2(direction.x,-direction.z)*180 / .pi }
    public var elevation: Double { atan2(direction.y,hypot(direction.x,direction.z))*180 / .pi }
    private static func vector(bearing: Double, elevation: Double) -> SIMD3<Double> {
        let b = bearing * .pi/180, e = elevation * .pi/180
        return SIMD3(sin(b)*cos(e),sin(e),-cos(b)*cos(e))
    }
    private static func separation(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        atan2(simd_length(simd_cross(a,b)),simd_dot(a,b))*180 / .pi
    }
    public init?(bearing: Double, elevation: Double, captured: Double) {
        guard bearing.isFinite, elevation.isFinite, captured.isFinite else { return nil }
        direction = Self.vector(bearing:bearing,elevation:elevation); self.captured = captured
    }
    public mutating func observe(bearing: Double, elevation: Double, captured time: Double) {
        guard bearing.isFinite, elevation.isFinite, time.isFinite, time > captured else { return }
        captured = time
        let measured = Self.vector(bearing:bearing,elevation:elevation)
        guard Self.separation(direction,measured) >= 3 else { pending = nil; return }
        if let pending, time-pending.captured <= 1.0 {
            let step = Self.separation(pending.direction,measured)
            let a = pending.direction-direction*simd_dot(pending.direction,direction)
            let b = measured-direction*simd_dot(measured,direction)
            let support = simd_length(a)*simd_length(b)
            let coherent = support > 1e-8 && simd_dot(a,b)/support >= 0.8
            if step <= 5 || (step <= 25 && coherent) {
                direction = simd_normalize(pending.direction+measured)
                self.pending = nil; return
            }
        }
        pending = (measured,time)
    }
}
