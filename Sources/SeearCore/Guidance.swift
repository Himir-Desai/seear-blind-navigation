import Foundation

public enum Geometry {
    public static func wrap(_ angle: Double) -> Double {
        let a = angle.truncatingRemainder(dividingBy: 360)
        return a > 180 ? a - 360 : a <= -180 ? a + 360 : a
    }
    public static func relative(_ bearing: Double, yaw: Double) -> Double { wrap(bearing - yaw) }
}

public enum VoiceCommand: Equatable {
    case find(String), cancel, pauseGuidance, resumeGuidance
    public static func parse(_ phrase: String) -> VoiceCommand? {
        let cleaned = phrase.lowercased().replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        guard let wake = cleaned.range(of: #"\bhey (seear|seer|see ear|see her)\b"#, options: .regularExpression) else { return nil }
        var text = String(cleaned[wake.upperBound...]).trimmingCharacters(in: .whitespaces)
        if ["stop", "cancel", "stop finding", "cancel search"].contains(text) { return .cancel }
        if ["pause", "pause guidance", "stop guidance"].contains(text) { return .pauseGuidance }
        if ["resume", "resume guidance", "start guidance"].contains(text) { return .resumeGuidance }
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
    public var trackID: String?
    public var classificationCaptured: Double?
    public var trackingQuality: Double?
    public init(label: String, confidence: Double, bearing: Double, elevation: Double = 0,
                distance: Double, box: [Double] = [], trackID: String? = nil, classificationCaptured: Double? = nil, trackingQuality: Double? = nil) {
        self.label = label; self.confidence = confidence; self.bearing = bearing
        self.elevation = elevation; self.distance = distance; self.box = box
        self.trackID = trackID; self.classificationCaptured = classificationCaptured; self.trackingQuality = trackingQuality
    }
    public var valid: Bool {
        confidence.isFinite && (0...1).contains(confidence) && bearing.isFinite && elevation.isFinite &&
        distance.isFinite && distance > 0 && distance <= 30 &&
        (trackID.map { !$0.isEmpty && $0.count <= 64 && classificationCaptured != nil && trackingQuality != nil } ?? true) &&
        (classificationCaptured.map { $0.isFinite && $0 >= 0 } ?? true) &&
        (trackingQuality.map { $0.isFinite && (0.55...1).contains($0) } ?? true)
    }
}

public struct WearerFilter: Codable {
    public var status: String
    public var excludedPixels: Int
    public var shoes: Int
    public var legs: Int
    public var valid: Bool {
        ["filtered","no_match","not_applicable","mask_rejected"].contains(status) &&
        (0...1_638_400).contains(excludedPixels) && (0...8).contains(shoes) && (0...8).contains(legs)
    }
}

public struct PerceptionStats: Codable {
    public var depthMS: Double
    public var trackingMS: Double
    public var detectorMS: Double
    public var mode: String
    public var classified: Double?
    public var detectorBusy: Bool
    public var classifierError: String
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
    public var rotation: Rotation3D?
    public var searchID: String?
    public var perception: PerceptionStats?
    public var wearerFilter: WearerFilter?
    public init(feed: String, captured: Double, yaw: Double, target: String, objects: [Observation],
                obstacles: [Observation], coverage: Double = 1, inferenceMS: Double = 0, wearerFilter: WearerFilter? = nil, rotation: Rotation3D? = nil, searchID: String? = nil, perception: PerceptionStats? = nil) {
        self.feed = feed; self.captured = captured; self.yaw = yaw; self.target = target; self.rotation = rotation; self.searchID = searchID; self.perception = perception
        self.objects = objects; self.obstacles = obstacles; self.coverage = coverage; self.inferenceMS = inferenceMS; self.wearerFilter = wearerFilter
    }
}

public struct Cue: Equatable {
    public var bearing: Double
    public var elevation: Double
    public var distance: Double
    public var level: Double
    public var hazard: Bool
    public var feed: String?
    public init(_ o: Observation, yaw: Double, level: Double = 1, hazard: Bool = false, feed: String? = nil) {
        bearing = Geometry.wrap(o.bearing + yaw); elevation = o.elevation; distance = o.distance
        self.level = level; self.hazard = hazard; self.feed = feed
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
/// The current cap-camera/head direction defines the forward alert corridor.
/// This does not infer body heading, walking intent or a safe route.
public final class GuidanceEngine {
    public var target: String = ""
    public var maxAge: Double = 1.5
    public var itemConfidencePolicy = ItemConfidencePolicy.demo
    public private(set) var searchID = UUID().uuidString
    private var confirmedObstacles: [String:Set<Int>] = [:]
    public private(set) var isPaused = false
    public private(set) var frames: [String: SceneFrame] = [:]
    /// One accepted item for the debug overlay, including while an urgent hazard mutes its sound.
    public private(set) var selectedItem: (feed: String, observation: Observation)?
    private struct ItemLock {
        var feed: String
        var trackID: String?
        var bearing: Double
        var distance: Double
        var confidence: Double
        var box: [Double]
        var rotation: Rotation3D
        var captured: Double
    }
    private var lockedTarget: ItemLock?
    private var acquiredItem = false
    public var selectedTrackID: String? { lockedTarget?.trackID }
    public var needsItemReselection: Bool { acquiredItem && lockedTarget == nil && !target.isEmpty }
    public init() {}
    public func reset() { frames.removeAll(); confirmedObstacles.removeAll(); lockedTarget = nil; selectedItem = nil; searchID = UUID().uuidString }
    public func pause() { isPaused = true; frames.removeAll(); confirmedObstacles.removeAll(); selectedItem = nil }
    public func resume() { isPaused = false; frames.removeAll(); confirmedObstacles.removeAll(); selectedItem = nil }
    public func search(_ text: String) { target = VoiceCommand.canonicalTarget(text); searchID = UUID().uuidString; lockedTarget = nil; acquiredItem = false; selectedItem = nil }
    public func ingest(_ frame: SceneFrame) {
        guard ["front", "feet"].contains(frame.feed), frame.captured.isFinite, frame.yaw.isFinite,
              frame.coverage.isFinite, (0...1).contains(frame.coverage), frame.rotation?.valid ?? true,
              frames[frame.feed].map({ $0.captured <= frame.captured }) ?? true else { return }
        var confirmed = Set<Int>()
        if let previous = frames[frame.feed], frame.captured > previous.captured,
           frame.captured-previous.captured <= 0.6, previous.coverage >= 0.6 {
            for (index,o) in frame.obstacles.enumerated() where o.valid {
                if previous.obstacles.contains(where: { old in
                    old.valid && abs(Geometry.wrap(o.bearing+frame.yaw-old.bearing-previous.yaw))<15 &&
                    abs(o.distance-old.distance)<0.15
                }) { confirmed.insert(index) }
            }
        }
        confirmedObstacles[frame.feed] = confirmed
        frames[frame.feed] = frame
    }
    public func evaluate(now: Double, yaw: Double, tracking: Bool) -> Guidance {
        selectedItem = nil
        func unavailable(_ text: String) -> Guidance { Guidance(target: nil, obstacle: nil, status: text, fault: true) }
        if isPaused { return Guidance(target:nil,obstacle:nil,status:"Guidance paused",fault:false) }
        guard tracking, yaw.isFinite else { return unavailable("Head tracking unavailable. Guidance paused.") }
        let fresh = ["front", "feet"].compactMap { frames[$0] }.filter {
            now >= $0.captured && now - $0.captured <= maxAge && $0.coverage >= 0.6
        }
        guard fresh.count == 2 else { return unavailable("Camera or vision delayed. Guidance paused.") }
        var hazards: [(SceneFrame, Observation)] = []
        for frame in fresh {
            for (index,o) in frame.obstacles.enumerated() where o.valid && o.distance <= ObstacleSound.warningRange {
                // A turn changes the corridor immediately; a source already observed
                // stays at its capture bearing until a new image refreshes it.
                let angle = Geometry.relative(o.bearing + frame.yaw, yaw: yaw) * .pi / 180
                let lateral = sin(angle) * o.distance, forward = cos(angle) * o.distance
                if abs(lateral) <= 0.55 && forward > 1e-6 &&
                   (o.distance <= ObstacleSound.emergencyRange || confirmedObstacles[frame.feed]?.contains(index) == true) {
                    hazards.append((frame, o))
                }
            }
        }
        let hazard = hazards.min { $0.1.distance < $1.1.distance }
        var candidates: [(SceneFrame, Observation)] = []
        if !target.isEmpty {
            for f in fresh where f.target == target && (f.searchID == nil || f.searchID == searchID) {
                for o in f.objects where o.valid && o.label == target {
                    if let classified = o.classificationCaptured,
                       !(classified <= f.captured && now-classified <= 2.5) { continue }
                    candidates.append((f,o))
                }
            }
        }
        let eligible = candidates.filter { itemConfidencePolicy.accepts($0.1.confidence) }
        let best = eligible.max { $0.1.confidence < $1.1.confidence }
        let selected: (SceneFrame, Observation)?
        var associatedCurrent: (SceneFrame,Observation)?
        if let lock = lockedTarget {
            func overlap(_ a: [Double], _ b: [Double]) -> Double? {
                guard a.count == 4, b.count == 4, (a+b).allSatisfy(\.isFinite),
                      a[2] > a[0], a[3] > a[1], b[2] > b[0], b[3] > b[1] else { return nil }
                let intersection = max(0,min(a[2],b[2])-max(a[0],b[0])) * max(0,min(a[3],b[3])-max(a[1],b[1]))
                return intersection / ((a[2]-a[0])*(a[3]-a[1])+(b[2]-b[0])*(b[3]-b[1])-intersection)
            }
            let matches = candidates.compactMap { frame,observation -> (SceneFrame,Observation,Double)? in
                guard frame.feed == lock.feed, frame.captured >= lock.captured else { return nil }
                if let lockedID = lock.trackID, let observedID = observation.trackID {
                    return lockedID == observedID ? (frame,observation,0) : nil
                }
                // Legacy/nontracking backends retain approximate geometric association.
                let angle = abs(Geometry.wrap(observation.bearing+frame.yaw-lock.bearing))
                let range = abs(observation.distance-lock.distance), rangeGate = max(0.8,lock.distance*0.6)
                guard angle < 20, range < rangeGate else { return nil }
                let stableView = (frame.rotation ?? .heading(frame.yaw)).difference(from:lock.rotation) < 5
                let iou = stableView ? overlap(lock.box,observation.box) : nil
                if let iou, iou < 0.1 { return nil }
                return (frame,observation,angle/20+range/rangeGate+(iou.map { 1-$0 } ?? 0))
            }
            let match = matches.min { a,b in a.2 == b.2 ? a.1.confidence > b.1.confidence : a.2 < b.2 }
            associatedCurrent = match.map { ($0.0,$0.1) }
            let reference = associatedCurrent?.1.confidence ?? lock.confidence
            let referenceTime = associatedCurrent?.0.captured ?? lock.captured
            let challenger = eligible.filter { $0.0.captured >= referenceTime }.max { $0.1.confidence < $1.1.confidence }
            if let challenger, itemConfidencePolicy.permitsSwitch(to:challenger.1.confidence,from:reference) {
                selected = challenger
            } else {
                selected = associatedCurrent.flatMap { itemConfidencePolicy.accepts($0.1.confidence) ? $0 : nil }
            }
        } else if !acquiredItem {
            // The first fast depth replies can precede either background scan.
            // Compare both initial scans before establishing a persistent lock.
            let scannedBoth = fresh.allSatisfy { frame in
                frame.perception.map { $0.classified != nil && (frame.searchID == nil || frame.searchID == searchID) } ?? true
            }
            selected = scannedBoth ? best : nil
        } else {
            // A reference/backend reset invalidated the identity. Require Find again.
            selected = nil
        }
        // A weak current association can update the comparison score without
        // emitting an item cue or box below the floor.
        if let (frame,observation) = selected ?? associatedCurrent {
            lockedTarget = ItemLock(feed:frame.feed,trackID:observation.trackID,bearing:Geometry.wrap(observation.bearing+frame.yaw),distance:observation.distance,
                                    confidence:observation.confidence,box:observation.box,rotation:frame.rotation ?? .heading(frame.yaw),captured:frame.captured)
            acquiredItem = true
        }
        if let (frame,observation) = selected { selectedItem = (frame.feed,observation) }
        let urgent = hazard.map { $0.1.distance <= ObstacleSound.emergencyRange } ?? false
        return Guidance(target: urgent ? nil : selected.map { Cue($0.1, yaw: $0.0.yaw, level: 1) },
                        obstacle: hazard.map { Cue($0.1, yaw: $0.0.yaw, hazard: true, feed: $0.0.feed) },
                        status: urgent ? "Emergency obstacle nearby" : hazard != nil ? "Quiet nearby obstacle warning" : target.isEmpty ? "Monitoring forward view" : needsItemReselection ? "Find again to reselect \(target)" : selected == nil ? "Searching for \(target)" : "Guiding to \(target)", fault: false)
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
