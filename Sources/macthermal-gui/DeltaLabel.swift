import SwiftUI
#if canImport(MacThermalCore)
import MacThermalCore
#endif

/// How a metric's change should be judged.
enum DeltaSemantics {
    /// Lower is better, so a drop reads as an improvement (temperature).
    case lowerIsBetter
    /// Neither direction is good or bad on its own, so the direction is shown
    /// without a verdict.
    ///
    /// Fan effort works this way: more cooling can accompany a lower
    /// temperature and vice versa. `ThermalComparisonAssessment` already reports
    /// it as `.contextual` and `ComparisonMetricCard` renders it neutrally —
    /// this keeps the incident detail from calling the same number "better" or
    /// "worse" over the same data.
    case contextual
}

struct DeltaLabel: View {
    let value: Double
    let suffix: String
    let semantics: DeltaSemantics
    /// Movement at or below this is noise, not a change. Callers pass the same
    /// tolerance the core uses for that metric so the two comparison screens
    /// cannot disagree about what counts as unchanged.
    let tolerance: Double

    var body: some View {
        Label(neutral ? "Unchanged" : formattedValue, systemImage: symbol)
            .foregroundStyle(tint)
    }

    private var neutral: Bool { abs(value) <= tolerance }

    private var symbol: String {
        if neutral { return "equal" }
        return value < 0 ? "arrow.down.right" : "arrow.up.right"
    }

    private var tint: Color {
        guard !neutral else { return .secondary }
        switch semantics {
        case .contextual: return .secondary
        case .lowerIsBetter: return value < 0 ? .green : .orange
        }
    }

    private var formattedValue: String {
        let prefix = value >= 0 ? "+" : ""
        return "\(prefix)\(value.formatted(.number.precision(.fractionLength(1))))\(suffix)"
    }
}
