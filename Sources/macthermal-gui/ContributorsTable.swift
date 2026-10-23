import SwiftUI
#if canImport(MacThermalCore)
import MacThermalCore
#endif

struct ContributorsTable: View {
    let contributors: [HeatContributor]

    var body: some View {
        Table(contributors) {
            TableColumn("Process", value: \.processName)
            TableColumn("CPU while hot") { item in
                Text("\(item.hotAverageCPUPercent.formatted(.number.precision(.fractionLength(1))))%")
            }
            TableColumn("Peak CPU") { item in
                Text("\(item.peakCPUPercent.formatted(.number.precision(.fractionLength(1))))%")
            }
            TableColumn("Pattern") { item in
                // Deliberately not tinted: a pattern describes *how* a process
                // used CPU, not how bad it is. Borrowing the severity palette
                // made the whole column read as a wall of warnings, and the
                // symbol already tells the two apart.
                Label(item.pattern.label, systemImage: patternSymbol(item.pattern))
                    .foregroundStyle(.secondary)
                    .help(item.pattern.detail)
            }
            TableColumn("Samples") { item in
                Text(item.hotSampleCount, format: .number)
            }
        }
        .frame(minHeight: 220)
    }

    private func patternSymbol(_ pattern: ContributionPattern) -> String {
        switch pattern {
        case .steadyLoad:        "flame.fill"
        case .tracksTemperature: "chart.line.uptrend.xyaxis"
        }
    }
}
