import SwiftUI
#if canImport(MacThermalCore)
import MacThermalCore
#endif

struct MenuBarLabelView: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var live: ThermalLiveState

    var body: some View {
        Image(systemName: symbol)
            .accessibilityHidden(true)
        // Monospaced digits keep the status item a fixed width. Without them it
        // resizes as the reading crosses 9 → 56 → 100, nudging every menu bar
        // icon to its left on each refresh — every few seconds, all day.
        Text(settings.unit.format(readingCelsius, decimals: 0))
            .monospacedDigit()
            .accessibilityLabel(accessibilityDescription)
    }

    /// The bare number says nothing on its own, and this is the only part of
    /// the app a VoiceOver user meets without opening anything.
    private var accessibilityDescription: String {
        guard let readingCelsius else { return "\(settings.menuBarMetric.title), no reading" }
        return "\(settings.menuBarMetric.title), \(settings.unit.format(readingCelsius, decimals: 0))"
    }

    private var readingCelsius: Double? {
        guard let category = settings.menuBarMetric.category else { return live.hottest?.celsius }
        return live.temperatureGroups.first { $0.category == category }?.hottest.celsius
    }

    // Icon severity follows the *displayed* reading, so selecting a cool metric
    // (e.g. CPU) never shows a hot icon driven by a different, hotter sensor.
    private var symbol: String {
        let severity = readingCelsius.map { tempLevel($0).severity } ?? .ok
        return severity == .critical ? "thermometer.high" : "thermometer.medium"
    }
}
