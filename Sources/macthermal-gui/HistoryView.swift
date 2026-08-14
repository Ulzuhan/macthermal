import SwiftUI
#if canImport(MacThermalCore)
import MacThermalCore
#endif

struct HistoryView: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var archive: ThermalArchiveState
    @State private var range: HistoryRange = .oneHour
    @State private var displayedSamples: [ThermalSample] = []

    var body: some View {
        VStack(spacing: 0) {
            HistoryControls(range: $range, samples: displayedSamples)
                .padding()
            Divider()

            if displayedSamples.isEmpty {
                EmptyStateView(
                    title: "No samples in this range",
                    message: "MacThermal records locally while it is running. Choose a longer range or leave it open to collect history.",
                    systemImage: "chart.xyaxis.line"
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignMetrics.sectionSpacing) {
                        TemperatureHistoryChart(
                            samples: displayedSamples,
                            unit: settings.unit,
                            alertThresholdCelsius: settings.alertsEnabled ? settings.alertThresholdCelsius : nil,
                            scope: $settings.temperatureChartScope
                        )
                        .equatable()
                        .frame(minHeight: 320)

                        HistorySummaryGrid(samples: displayedSamples, unit: settings.unit)
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("History")
        .task(id: analysisRevision) { await updateSamples() }
    }

    private func updateSamples() async {
        do {
            let cutoff = Date.now.addingTimeInterval(-range.duration)
            displayedSamples = try await AnalyticsEngine.shared.recentSamples(
                archive.history,
                since: cutoff,
                chronological: archive.historyIsChronological
            )
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private var analysisRevision: RangedHistoryRevision {
        RangedHistoryRevision(range: range, samples: SampleRevision(archive.history))
    }
}
