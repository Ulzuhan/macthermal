import SwiftUI
#if canImport(MacThermalCore)
import MacThermalCore
#endif

struct IncidentChangeView: View {
    let incident: ThermalIncident
    let unit: TempUnit

    var body: some View {
        GroupBox("Start vs end") {
            if let comparison {
                Grid(alignment: .leading, horizontalSpacing: DesignMetrics.sectionSpacing, verticalSpacing: DesignMetrics.standardSpacing) {
                    GridRow {
                        Text("Metric").foregroundStyle(.secondary)
                        Text("First 20%").foregroundStyle(.secondary)
                        Text("Last 20%").foregroundStyle(.secondary)
                        Text("Change").foregroundStyle(.secondary)
                    }
                    Divider()
                    GridRow {
                        Text("Average hotspot")
                        Text(unit.format(comparison.baseline.averageHotspotCelsius))
                        Text(unit.format(comparison.current.averageHotspotCelsius))
                        DeltaLabel(
                            value: converted(comparison.hotspotDeltaCelsius),
                            suffix: unit.symbol,
                            semantics: .lowerIsBetter,
                            // Converted too: in Fahrenheit the core's 1 °C
                            // tolerance is 1.8 °F, and comparing a converted
                            // delta against a Celsius tolerance would call
                            // ordinary noise a regression.
                            tolerance: converted(ThermalComparisonTolerance.averageHotspotCelsius)
                        )
                    }
                    GridRow {
                        Text("Fan load")
                        Text(comparison.baseline.hasFanData ? percent(comparison.baseline.averageFanUtilization) : "Not available")
                        Text(comparison.current.hasFanData ? percent(comparison.current.averageFanUtilization) : "Not available")
                        if comparison.fanDataAvailable {
                            DeltaLabel(
                                value: comparison.fanDeltaPercent,
                                suffix: "%",
                                semantics: .contextual,
                                tolerance: ThermalComparisonTolerance.fanUtilizationPercent
                            )
                        } else {
                            Text("No comparison")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, DesignMetrics.compactSpacing)
            } else {
                Text("More samples are required to compare the start and end of this incident.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var comparison: ThermalComparison? {
        guard incident.samples.count >= 5 else { return nil }
        let segmentCount = max(1, incident.samples.count / 5)
        return ThermalComparison(
            baselineSamples: Array(incident.samples.prefix(segmentCount)),
            currentSamples: Array(incident.samples.suffix(segmentCount))
        )
    }

    private func converted(_ celsius: Double) -> Double {
        unit == .celsius ? celsius : celsius * 9 / 5
    }

    private func percent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0))))%"
    }
}
