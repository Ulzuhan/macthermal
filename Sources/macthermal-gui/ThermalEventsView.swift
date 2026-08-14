import SwiftUI
#if canImport(MacThermalCore)
import MacThermalCore
#endif

struct ThermalEventsView: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var archive: ThermalArchiveState
    @State private var range: HistoryRange = .twentyFourHours
    @State private var events: [ThermalEvent] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Text("\(events.count) event\(events.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()

            if events.isEmpty {
                EmptyStateView(
                    title: "No thermal events in this range",
                    message: "Threshold crossings and macOS thermal-pressure transitions will appear here automatically.",
                    systemImage: "waveform.path.ecg"
                )
            } else {
                List(events) { event in
                    ThermalEventRow(event: event, unit: settings.unit)
                }
            }
        }
        .navigationTitle("Thermal Timeline")
        .task(id: analysisRevision) { await updateEvents() }
    }

    private func updateEvents() async {
        do {
            let cutoff = Date.now.addingTimeInterval(-range.duration)
            let samples = try await AnalyticsEngine.shared.recentSamples(
                archive.history,
                since: cutoff,
                chronological: archive.historyIsChronological
            )
            events = try await AnalyticsEngine.shared.events(
                samples,
                thresholdCelsius: settings.alertThresholdCelsius
            )
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private var analysisRevision: EventAnalysisRevision {
        EventAnalysisRevision(
            range: range,
            samples: SampleRevision(archive.history),
            thresholdCelsius: settings.alertThresholdCelsius
        )
    }
}
