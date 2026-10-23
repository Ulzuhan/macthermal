import SwiftUI
#if canImport(MacThermalCore)
import MacThermalCore
#endif

struct FanRow: View {
    let fan: FanReading

    var body: some View {
        let level = fanLevel(fan.utilization)
        HStack(spacing: DesignMetrics.standardSpacing) {
            Label("Fan \(fan.index + 1)", systemImage: "fan")
            ProgressView(value: fan.utilization, total: 100)
                .tint(level.severity.color)
            Text(fan.rpm, format: .number.precision(.fractionLength(0)))
                .monospacedDigit()
            Text("rpm")
                .foregroundStyle(.secondary)
            Label(level.label.capitalized, systemImage: level.severity.symbol)
                .foregroundStyle(level.severity.color)
        }
        .accessibilityElement(children: .combine)
    }
}
