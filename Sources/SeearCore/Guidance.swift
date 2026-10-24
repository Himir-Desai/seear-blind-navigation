import Foundation

public enum Geometry {
    public static func wrap(_ angle: Double) -> Double {
        let a = angle.truncatingRemainder(dividingBy: 360)
        return a > 180 ? a - 360 : a <= -180 ? a + 360 : a
    }
    public static func relative(_ bearing: Double, yaw: Double) -> Double { wrap(bearing - yaw) }
}

public enum VoiceCommand: Equatable {
    case find(String), cancel, forward
    public static func parse(_ phrase: String) -> VoiceCommand? {
        let cleaned = phrase.lowercased().replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        guard let wake = cleaned.range(of: #"\bhey (seear|seer|see ear|see her)\b"#, options: .regularExpression) else { return nil }
        var text = String(cleaned[wake.upperBound...]).trimmingCharacters(in: .whitespaces)
        if ["stop", "cancel", "stop finding", "cancel search"].contains(text) { return .cancel }
        if text == "set forward" { return .forward }
        let prefixes = ["where is ", "where s ", "find "]
        guard let prefix = prefixes.first(where: { text.hasPrefix($0) }) else { return nil }
        text.removeFirst(prefix.count)
        for article in ["my ", "the ", "a ", "an "] where text.hasPrefix(article) {
            text.removeFirst(article.count); break
        }
        text = canonicalTarget(text)
        guard !text.isEmpty, text.count <= 64 else { return nil }
        return .find(text)
    }
    public static func canonicalTarget(_ text: String) -> String {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["bag pack": "backpack", "bagpack": "backpack", "back pack": "backpack" ][t] ?? t
    }
}

public struct Observation: Codable, Equatable {
    public var label: String
    public var confidence: Double
    public var bearing: Double
    public var elevation: Double
    public var distance: Double
    public var box: [Double]
    public init(label: String, confidence: Double, bearing: Double, elevation: Double = 0,
                distance: Double, box: [Double] = []) {
        self.label = label; self.confidence = confidence; self.bearing = bearing
        self.elevation = elevation; self.distance = distance; self.box = box
    }
    public var valid: Bool {
        confidence.isFinite && (0...1).contains(confidence) && bearing.isFinite && elevation.isFinite &&
        distance.isFinite && distance > 0 && distance <= 30
    }
}

public struct SceneFrame: Codable {
    public var feed: String
    public var captured: Double
    public var yaw: Double
    public var target: String
    public var objects: [Observation]
    public var obstacles: [Observation]
    public var coverage: Double
    public var inferenceMS: Double
    public init(feed: String, captured: Double, yaw: Double, target: String, objects: [Observation],
                obstacles: [Observation], coverage: Double = 1, inferenceMS: Double = 0) {
        self.feed = feed; self.captured = captured; self.yaw = yaw; self.target = target
        self.objects = objects; self.obstacles = obstacles; self.coverage = coverage; self.inferenceMS = inferenceMS
    }
}

public struct Cue: Equatable {
    public var bearing: Double
    public var elevation: Double
    public var distance: Double
    public var level: Double
    public var hazard: Bool
    public init(_ o: Observation, yaw: Double, level: Double = 1, hazard: Bool = false) {
        bearing = Geometry.wrap(o.bearing + yaw); elevation = o.elevation; distance = o.distance
        self.level = level; self.hazard = hazard
    }
}

public struct Guidance {
    public var target: Cue?
    public var obstacle: Cue?
    public var status: String
    public var fault: Bool
    public init(target: Cue?, obstacle: Cue?, status: String, fault: Bool) {
        self.target = target; self.obstacle = obstacle; self.status = status; self.fault = fault
    }
}

/// Latest observations only. AirPods supply rotation, never listener translation.
/// A manually set heading defines a straight walking segment; no route planning is implied.
public final class GuidanceEngine {
    public var target: String = ""
    public var walkingYaw: Double = 0
    public var maxAge: Double = 1.5
    public private(set) var frames: [String: SceneFrame] = [:]
    private var lockedTarget: (feed: String, bearing: Double, distance: Double)?
    public init() {}
    public func reset() { frames.removeAll(); lockedTarget = nil }
    public func search(_ text: String) { target = VoiceCommand.canonicalTarget(text); lockedTarget = nil }
    public func ingest(_ frame: SceneFrame) {
        guard ["front", "feet"].contains(frame.feed), frame.captured.isFinite, frame.yaw.isFinite,
              frame.coverage.isFinite, (0...1).contains(frame.coverage),
              frames[frame.feed].map({ $0.captured <= frame.captured }) ?? true else { return }
        frames[frame.feed] = frame
    }
    public func evaluate(now: Double, yaw: Double, tracking: Bool) -> Guidance {
        func unavailable(_ text: String) -> Guidance { Guidance(target: nil, obstacle: nil, status: text, fault: true) }
        guard tracking, yaw.isFinite else { lockedTarget = nil; return unavailable("Head tracking unavailable. Guidance paused.") }
        guard abs(Geometry.relative(yaw, yaw: walkingYaw)) <= 50 else {
            return unavailable("Walking direction outside view. Face forward or set forward.")
        }
        let fresh = ["front", "feet"].compactMap { frames[$0] }.filter {
            now >= $0.captured && now - $0.captured <= maxAge && $0.coverage >= 0.6
        }
        guard fresh.count == 2 else { lockedTarget = nil; return unavailable("Camera or vision delayed. Guidance paused.") }
        var hazards: [(SceneFrame, Observation)] = []
        for frame in fresh {
            for o in frame.obstacles where o.valid {
                let angle = Geometry.relative(o.bearing + frame.yaw, yaw: walkingYaw) * .pi / 180
                let lateral = sin(angle) * o.distance, forward = cos(angle) * o.distance
                if abs(lateral) <= 0.55 && forward > 0 && forward <= 3 {
                    hazards.append((frame, o))
                }
            }
        }
        let hazard = hazards.min { $0.1.distance < $1.1.distance }
        var candidates: [(SceneFrame, Observation)] = []
        if !target.isEmpty {
            for f in fresh where f.target == target {
                for o in f.objects where o.valid && o.confidence >= 0.15 && o.label == target { candidates.append((f, o)) }
            }
        }
        let selected: (SceneFrame, Observation)?
        if let lock = lockedTarget {
            selected = candidates.filter {
                $0.0.feed == lock.feed && abs(Geometry.wrap($0.1.bearing + $0.0.yaw - lock.bearing)) < 20 &&
                abs($0.1.distance - lock.distance) < max(0.8, lock.distance * 0.6)
            }.min { abs($0.1.bearing + $0.0.yaw - lock.bearing) < abs($1.1.bearing + $1.0.yaw - lock.bearing) }
            // Do not silently switch to a different instance after losing the chosen object.
        } else {
            selected = candidates.max { $0.1.confidence < $1.1.confidence }
        }
        if let (f, o) = selected { lockedTarget = (f.feed, Geometry.wrap(o.bearing + f.yaw), o.distance) }
        let urgent = hazard.map { $0.1.distance <= 1.2 } ?? false
        return Guidance(target: urgent ? nil : selected.map { Cue($0.1, yaw: $0.0.yaw, level: hazard == nil ? 1 : 0.2) },
                        obstacle: hazard.map { Cue($0.1, yaw: $0.0.yaw, hazard: true) },
                        status: hazard != nil ? "Obstacle in walking corridor" : target.isEmpty ? "Monitoring obstacles" : selected == nil ? "Searching for \(target)" : "Guiding to \(target)", fault: false)
    }
}

public enum SoundMapping {
    public static func rate(_ distance: Double) -> Double { 0.65 + 5.35 / (1 + max(0, distance) / 1.5) }
    public static func gain(_ distance: Double) -> Double { distance >= 1 ? 1 / distance : 2 - max(0, distance) }
    public static func visibility(angle: Double, distance: Double) -> Double {
        let a = abs(Geometry.wrap(angle)), side = pow(10.0, -3.0 / 20)
        let fov: Double
        if a <= 45 { fov = 1 }
        else if a <= 90 { fov = side + (1 - side) * 0.5 * (1 + cos(.pi * (a - 45) / 45)) }
        else if a < 170 { fov = side * 0.5 * (1 + cos(.pi * (a - 90) / 80)) }
        else { fov = 0 }
        let t = min(1, max(0, (0.4 - distance) / 0.2)), proximity = t * t * (3 - 2 * t)
        return proximity + (1 - proximity) * fov
    }
    public static func sharpness(_ angle: Double) -> Double {
        let a = abs(Geometry.wrap(angle)), focus = a >= 90 ? 0 : 0.5 * (1 + cos(.pi * a / 90))
        return pow(10, focus / 20)
    }
}
