import Foundation
import simd

/// Right-handed audio/map coordinates: +X right, +Y up, -Z forward.
public struct Rotation3D: Codable, Equatable {
    public var x: Double, y: Double, z: Double, w: Double
    public init(x: Double = 0, y: Double = 0, z: Double = 0, w: Double = 1) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }
    public var valid: Bool { [x,y,z,w].allSatisfy(\.isFinite) && abs(x*x+y*y+z*z+w*w-1) < 0.001 }
    private var quaternion: simd_quatd { simd_normalize(simd_quatd(ix:x,iy:y,iz:z,r:w)) }
    private init(_ q: simd_quatd) { let q = simd_normalize(q); self.init(x:q.imag.x,y:q.imag.y,z:q.imag.z,w:q.real) }
    public static let identity = Rotation3D()
    public static func axis(_ axis: SIMD3<Double>, degrees: Double) -> Self {
        Self(simd_quatd(angle:degrees * .pi/180,axis:simd_normalize(axis)))
    }
    public static func heading(_ degrees: Double) -> Self { axis(SIMD3(0,1,0),degrees:-degrees) }
    /// Core Motion headphone +X right/+Y forward/+Z up -> audio axes.
    public static func headphone(x: Double, y: Double, z: Double, w: Double) -> Self {
        Self(x:x,y:z,z:-y,w:w)
    }
    public func applied(to vector: SIMD3<Double>) -> SIMD3<Double> { quaternion.act(vector) }
    public func followed(by outer: Self) -> Self { Self(outer.quaternion * quaternion) }
    public var inverse: Self { Self(quaternion.inverse) }
    public func interpolated(to other: Self, fraction: Double) -> Self { Self(simd_slerp(quaternion,other.quaternion,fraction)) }
    public func difference(from other: Self) -> Double {
        let dot = min(1,abs(simd_dot(quaternion.vector,other.quaternion.vector)))
        return 2 * acos(dot) * 180 / .pi
    }
    public func heading(fallback: Double) -> Double {
        let forward = applied(to:SIMD3(0,0,-1))
        return hypot(forward.x,forward.z) > 0.05 ? atan2(forward.x,-forward.z)*180 / .pi : fallback
    }
    public var matrix: [Double] {
        let m = simd_double3x3(quaternion)
        return (0..<3).flatMap { row in (0..<3).map { col in m[col][row] } }
    }
}

public struct HeadPose {
    public var rotation: Rotation3D
    public var yaw: Double
    public init(rotation: Rotation3D, yaw: Double) { self.rotation = rotation; self.yaw = yaw }
    /// Remove capture heading so the worker's bearings still add capture yaw exactly once.
    public var tilt: Rotation3D { rotation.followed(by:.heading(-yaw)) }
}
