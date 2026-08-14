import Foundation
#if canImport(MacThermalCore)
import MacThermalCore
#endif

/// Keeps history scans and correlation math off the main actor. The value
/// models crossing this boundary are immutable and Sendable.
actor AnalyticsEngine {
    static let shared = AnalyticsEngine()

    func recentSamples(
        _ samples: [ThermalSample],
        since cutoff: Date,
        chronological: Bool = true
    ) throws -> [ThermalSample] {
        try Task.checkCancellation()
        let result = ThermalSampleWindow.recent(
            samples,
            since: cutoff,
            chronological: chronological,
            isCancelled: { Task.isCancelled }
        )
        try Task.checkCancellation()
        return result
    }

    func temperatureChartSamples(
        _ samples: [ThermalSample],
        maximumCount: Int
    ) throws -> [ThermalSample] {
        try Task.checkCancellation()
        let result = ThermalSampleDownsampler.samples(
            from: samples,
            maximumCount: maximumCount,
            isCancelled: { Task.isCancelled }
        )
        try Task.checkCancellation()
        return result
    }

    func heatContributors(_ samples: [ThermalSample]) throws -> [HeatContributor] {
        try Task.checkCancellation()
        let result = ThermalAnalytics.heatContributors(
            samples: samples,
            isCancelled: { Task.isCancelled }
        )
        try Task.checkCancellation()
        return result
    }

    func events(_ samples: [ThermalSample], thresholdCelsius: Double) throws -> [ThermalEvent] {
        try Task.checkCancellation()
        let result = ThermalEventAnalyzer.events(
            samples: samples,
            thresholdCelsius: thresholdCelsius,
            isCancelled: { Task.isCancelled }
        )
        try Task.checkCancellation()
        return result
    }

    func comparison(
        samples: [ThermalSample],
        currentEnd: Date,
        duration: TimeInterval,
        expectedInterval: TimeInterval
    ) throws -> ComparisonAnalysis {
        try Task.checkCancellation()
        let currentStart = currentEnd.addingTimeInterval(-duration)
        let baselineStart = currentStart.addingTimeInterval(-duration)
        var baseline: [ThermalSample] = []
        var current: [ThermalSample] = []
        for (index, sample) in samples.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if sample.timestamp >= baselineStart && sample.timestamp < currentStart {
                baseline.append(sample)
            } else if sample.timestamp >= currentStart && sample.timestamp <= currentEnd {
                current.append(sample)
            }
        }
        return ComparisonAnalysis(
            comparison: ThermalComparison(baselineSamples: baseline, currentSamples: current),
            baselineStart: baselineStart,
            baselineEnd: currentStart,
            currentStart: currentStart,
            currentEnd: currentEnd,
            baselineCoverage: ThermalPeriodCoverage(
                samples: baseline,
                expectedStart: baselineStart,
                expectedEnd: currentStart,
                expectedInterval: expectedInterval
            ),
            currentCoverage: ThermalPeriodCoverage(
                samples: current,
                expectedStart: currentStart,
                expectedEnd: currentEnd,
                expectedInterval: expectedInterval
            )
        )
    }
}

struct ComparisonAnalysis: Sendable {
    let comparison: ThermalComparison
    let baselineStart: Date
    let baselineEnd: Date
    let currentStart: Date
    let currentEnd: Date
    let baselineCoverage: ThermalPeriodCoverage
    let currentCoverage: ThermalPeriodCoverage

    var isReliable: Bool {
        baselineCoverage.fraction >= 0.8 && currentCoverage.fraction >= 0.8
    }

    /// Both periods have enough samples to compute a meaningful average, even if
    /// coverage is imperfect. The view shows the comparison (with a "limited
    /// coverage" caveat) when this holds, instead of hiding usable data behind the
    /// stricter `isReliable` gate — which left short ranges blank whenever the Mac
    /// idled or slept and sampled sparsely.
    var hasComparableData: Bool {
        comparison.baseline.sampleCount >= 3 && comparison.current.sampleCount >= 3
    }
}
