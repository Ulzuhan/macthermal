import Charts
import SwiftUI
#if canImport(MacThermalCore)
import MacThermalCore
#endif

struct ContributorsChart: View {
    let contributors: [HeatContributor]

    var body: some View {
        Chart(contributors) { item in
            BarMark(
                x: .value("CPU while hot", item.hotAverageCPUPercent),
                y: .value("Process", item.processName)
            )
            // One accent instead of a colour per process: the process name is
            // already the Y axis and the legend is hidden, so a categorical
            // scale encoded nothing while pulling in whatever contrast the
            // automatic palette happened to pick.
            .foregroundStyle(Color.accentColor)
            .annotation(position: .trailing) {
                Text("\(item.hotAverageCPUPercent.formatted(.number.precision(.fractionLength(0))))%")
                    .font(.callout)
            }
        }
        .chartLegend(.hidden)
        .accessibilityLabel("CPU used by each process while the Mac was hot")
    }
}
