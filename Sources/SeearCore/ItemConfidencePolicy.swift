import Foundation

/// Model scores, not calibrated probabilities. One floor and a relative switching margin.
public struct ItemConfidencePolicy: Equatable {
    public let minimum: Double
    public let switchMargin: Double
    public static let demo = ItemConfidencePolicy(minimum:0.50,switchMargin:0.10)!

    public init?(minimum: Double, switchMargin: Double) {
        guard minimum.isFinite, switchMargin.isFinite, minimum >= 0, minimum < 1,
              switchMargin >= 0, minimum+switchMargin < 1 else { return nil }
        self.minimum = minimum; self.switchMargin = switchMargin
    }
    public func accepts(_ score: Double) -> Bool {
        score.isFinite && score <= 1 && score > minimum
    }
    public func permitsSwitch(to score: Double, from reference: Double) -> Bool {
        // Small tolerance prevents decimal boundary roundoff from triggering a switch.
        accepts(score) && reference.isFinite && (0...1).contains(reference) &&
            score-reference-switchMargin > 1e-6
    }
}
