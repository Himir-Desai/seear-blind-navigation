import Foundation

/// User-selected sparse warning policy. Estimated ranges, not measured clearance.
public enum ObstacleSound {
    public static let warningRange = 0.50
    public static let emergencyRange = 0.20
    public static func gain(_ distance: Double) -> Double {
        guard distance.isFinite, distance > 0, distance <= warningRange else { return 0 }
        if distance <= emergencyRange { return 0.35 + 0.35*min(1,(emergencyRange-distance)/0.10) }
        return 0.015 + 0.045*pow((warningRange-distance)/(warningRange-emergencyRange),2)
    }
    public static func rate(_ distance: Double) -> Double {
        guard distance.isFinite, distance > 0, distance <= warningRange else { return 0 }
        return distance <= emergencyRange ? 2+2*min(1,(emergencyRange-distance)/0.10) : 1.0/3
    }
}
