import AppKit
import SwiftUI

struct PanelView: View {
    let monitor: ThermalMonitor
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var live: ThermalLiveState
    @EnvironmentObject private var status: AppStatusState

    var body: some View {
        AdaptivePanel {
            VStack(alignment: .leading, spacing: DesignMetrics.standardSpacing) {
                PanelHeader()
                Divider()

                if live.available {
                    PanelTemperatureSection(groups: live.temperatureGroups, unit: settings.unit)
                    PanelFanSection(fans: live.fans)
                    Divider()
                    PanelThrottleRow(assessment: live.throttleAssessment)
                } else {
                    Label("SMC unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                PanelFooter(monitor: monitor, settings: settings)
            }
            .padding()
        }
        .alert(item: $status.presentedError) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
        .onAppear { monitor.setPanelPresented(true) }
        .onDisappear { monitor.setPanelPresented(false) }
    }
}

/// Sizes the menu bar panel to its content, within the screen.
///
/// The width used to be pinned at 360 pt, which truncates as soon as the system
/// text size goes up — every font in the panel is a semantic style, so the text
/// scales even though the box did not. `minWidth` keeps the familiar size as a
/// floor and lets the panel widen instead.
///
/// Height is capped rather than scrolled by default, because this is a
/// glanceable readout: making someone scroll to see their fan state is exactly
/// what separates it from the dashboard, which is one button away and scrolls
/// properly. The cap exists because a `MenuBarExtra` window taller than the
/// screen is clipped by the system, not scrolled — so past that point scrolling
/// is the only honest option. Reaching it takes an accessibility text size.
private struct AdaptivePanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
        }
        // Adopt the content's ideal height instead of the greedy height a
        // ScrollView takes by default, so a short panel stays short. Verified:
        // 6 rows render at their natural 188 pt, 40 rows clamp to the cap.
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: DesignMetrics.panelWidth, maxHeight: Self.maximumHeight)
    }

    private static var maximumHeight: CGFloat {
        guard let visible = NSScreen.main?.visibleFrame.height else { return 720 }
        return visible - 40
    }
}
