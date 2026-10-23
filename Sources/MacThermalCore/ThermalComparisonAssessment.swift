import Foundation

public enum ComparisonTrend: Equatable, Sendable {
    case improved
    case regressed
    case unchanged
    case contextual
}

public enum ThermalComparisonResult: Equatable, Sendable {
    case improved
    case regressed
    case mixed
    case unchanged
}

/// How far a metric may move before the change is called real rather than noise.
///
/// Exposed because the incident detail view compares the same metrics as the
/// period comparison and must not disagree with it about what counts as a
/// change.
public enum ThermalComparisonTolerance {
    public static let averageHotspotCelsius = 1.0
    public static let peakHotspotCelsius = 2.0
    public static let pressureFraction = 0.01
    public static let fanUtilizationPercent = 3.0
}

public struct ThermalComparisonAssessment: Equatable, Sendable {
    public let averageHotspotTrend: ComparisonTrend
    public let peakHotspotTrend: ComparisonTrend
    public let fanTrend: ComparisonTrend
    public let pressureTrend: ComparisonTrend
    public let result: ThermalComparisonResult

    public init(comparison: ThermalComparison) {
        // With no samples on a side, every delta is measured against a zeroed
        // summary and would read as a huge spurious swing (e.g. "70°C → 0").
        // Report "unchanged" rather than a misleading verdict. (The GUI already
        // gates on coverage; this keeps the core honest for any other caller.)
        guard comparison.baseline.sampleCount > 0, comparison.current.sampleCount > 0 else {
            averageHotspotTrend = .unchanged
            peakHotspotTrend = .unchanged
            fanTrend = .contextual
            pressureTrend = .unchanged
            result = .unchanged
            return
        }

        let averageTrend = Self.lowerIsBetter(
            delta: comparison.hotspotDeltaCelsius,
            tolerance: ThermalComparisonTolerance.averageHotspotCelsius
        )
        let peakTrend = Self.lowerIsBetter(
            delta: comparison.peakDeltaCelsius,
            tolerance: ThermalComparisonTolerance.peakHotspotCelsius
        )
        let pressureTrend = Self.lowerIsBetter(
            delta: comparison.pressureFractionDelta,
            tolerance: ThermalComparisonTolerance.pressureFraction
        )
        let fanTrend: ComparisonTrend
        if !comparison.fanDataAvailable {
            fanTrend = .contextual
        } else if abs(comparison.fanDeltaPercent) <= ThermalComparisonTolerance.fanUtilizationPercent {
            fanTrend = .unchanged
        } else {
            // Fan effort is context, not a standalone success or regression:
            // more cooling can accompany a lower temperature and vice versa.
            fanTrend = .contextual
        }

        averageHotspotTrend = averageTrend
        peakHotspotTrend = peakTrend
        self.fanTrend = fanTrend
        self.pressureTrend = pressureTrend

        let directionalTrends = [averageTrend, peakTrend, pressureTrend]
        let hasImprovement = directionalTrends.contains(.improved)
        let hasRegression = directionalTrends.contains(.regressed)
        if hasImprovement && hasRegression {
            result = .mixed
        } else if hasRegression {
            result = .regressed
        } else if hasImprovement {
            result = .improved
        } else {
            result = .unchanged
        }
    }

    private static func lowerIsBetter(delta: Double, tolerance: Double) -> ComparisonTrend {
        if delta < -tolerance { return .improved }
        if delta > tolerance { return .regressed }
        return .unchanged
    }
}
