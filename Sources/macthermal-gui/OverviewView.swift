import SwiftUI
#if canImport(MacThermalCore)
import MacThermalCore
#endif

struct OverviewView: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var live: ThermalLiveState
    @EnvironmentObject private var archive: ThermalArchiveState

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: DesignMetrics.standardSpacing)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignMetrics.sectionSpacing) {
                if live.available {
                    ThrottleStatusView(assessment: live.throttleAssessment)
                    LiveMetricsGrid(settings: settings, columns: columns)
                    TemperatureBreakdownView(groups: live.temperatureGroups, unit: settings.unit)
                    FanOverviewView(fans: live.fans)
                    RecentActivityView(
                        unit: settings.unit,
                        scope: $settings.temperatureChartScope
                    )
                } else {
                    EmptyStateView(
                        title: "SMC unavailable",
                        message: "MacThermal could not open the System Management Controller on this Mac.",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Overview")
    }
}
