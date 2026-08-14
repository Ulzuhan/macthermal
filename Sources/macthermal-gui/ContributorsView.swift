import SwiftUI
#if canImport(MacThermalCore)
import MacThermalCore
#endif

struct ContributorsView: View {
    @EnvironmentObject private var archive: ThermalArchiveState
    @State private var range: HistoryRange = .oneHour
    @State private var contributors: [HeatContributor] = []

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
            }
            .padding()
            Divider()

            if contributors.isEmpty {
                EmptyStateView(
                    title: "No heat to attribute yet",
                    message: "Keep MacThermal running while the Mac heats up. Once there are hot samples with process data, the processes using the most CPU during them appear here.",
                    systemImage: "bolt.horizontal.circle"
                )
            } else {
                VStack(alignment: .leading, spacing: DesignMetrics.sectionSpacing) {
                    ContributorExplanationView()
                    ContributorsChart(contributors: Array(contributors.prefix(8)))
                        .frame(minHeight: 230)
                    ContributorsTable(contributors: contributors)
                }
                .padding()
            }
        }
        .navigationTitle("Likely Contributors")
        .task(id: analysisRevision) { await updateContributors() }
    }

    private func updateContributors() async {
        do {
            let cutoff = Date.now.addingTimeInterval(-range.duration)
            let samples = try await AnalyticsEngine.shared.recentSamples(
                archive.history,
                since: cutoff,
                chronological: archive.historyIsChronological
            )
            contributors = try await AnalyticsEngine.shared.heatContributors(samples)
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
