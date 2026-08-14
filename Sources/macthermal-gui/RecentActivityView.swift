import SwiftUI
#if canImport(MacThermalCore)
import MacThermalCore
#endif

/// The Overview's history chart.
///
/// It windows `archive.history` itself instead of taking a slice from its
/// parent: `OverviewView` also renders live metrics, so its body runs on every
/// sensor refresh (every 2–3 seconds with the dashboard open) and a
/// `suffix(120)` computed there handed the chart a brand-new array each time.
/// Holding the window in `@State`, refreshed only when the history revision
/// changes, keeps the chart's inputs stable between sensor ticks so
/// `.equatable()` can skip the redraw.
struct RecentActivityView: View {
    let unit: TempUnit
    @Binding var scope: TemperatureChartScope
    @EnvironmentObject private var archive: ThermalArchiveState
    @State private var samples: [ThermalSample] = []

    private static let windowSize = 120

    var body: some View {
        GroupBox("Recent activity") {
            if samples.count < 2 {
                Text("History will appear after the next samples are recorded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                TemperatureHistoryChart(
                    samples: samples,
                    unit: unit,
                    alertThresholdCelsius: nil,
                    scope: $scope
                )
                    .equatable()
                    .frame(minHeight: 220)
            }
        }
        .task(id: SampleRevision(archive.history)) {
            samples = Array(archive.history.suffix(Self.windowSize))
        }
    }
}
