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
                // Deliberately NOT wrapped in a ScrollView, unlike the other
                // dashboard sections. They hold charts and grids; this one
                // holds a `Table`, which scrolls itself. Nesting the two clamps
                // the table to its minimum height and strands the rest of the
                // window empty below it, with two scrollbars to show for it.
                //
                // Instead the table is the flexible element: the explanation
                // and the chart take what they need, the table absorbs the
                // remaining height, and its own scrolling handles more rows
                // than fit.
                VStack(alignment: .leading, spacing: DesignMetrics.sectionSpacing) {
                    ContributorExplanationView()
                    ContributorsChart(contributors: Array(contributors.prefix(8)))
                        .frame(minHeight: 180, maxHeight: 260)
                    ContributorsTable(contributors: contributors)
                        .frame(maxHeight: .infinity)
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
