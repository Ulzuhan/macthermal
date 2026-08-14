import Foundation
#if canImport(MacThermalCore)
import MacThermalCore
#endif

enum TemperatureChartScope: String, CaseIterable, Identifiable, Sendable {
    case overall
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "Memory"
    case battery = "Battery"
    case ambient = "Ambient"
    case other = "Other"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overall: "Overall"
        default: rawValue
        }
    }

    var systemImage: String {
        switch self {
        case .overall: "thermometer.variable"
        case .cpu: "cpu"
        case .gpu: "rectangle.3.group"
        case .memory: "memorychip"
        case .battery: "battery.75percent"
        case .ambient: "thermometer.medium"
        case .other: "sensor"
        }
    }

    func hotspot(in sample: ThermalSample) -> Double? {
        switch self {
        case .overall: sample.hottestCelsius
        default: sample.categoryPeaks[rawValue]
        }
    }

    func average(in sample: ThermalSample) -> Double? {
        switch self {
        case .overall: sample.averageCelsius
        default: sample.categoryAverages?[rawValue]
        }
    }

    /// Which component scopes the chart can offer.
    ///
    /// The set of sensor categories a Mac reports does not change between
    /// samples, so this reads the most recent one instead of unioning the whole
    /// rendered window — which ran on the main actor over up to a thousand
    /// samples every time the history revision changed. Older samples are
    /// scanned only as a fallback, for the case where the newest sample happens
    /// to carry no category peaks at all.
    static func available(in samples: [ThermalSample]) -> [TemperatureChartScope] {
        guard let representative = samples.last(where: { !$0.categoryPeaks.isEmpty }) else {
            return [.overall]
        }
        let categories = Set(representative.categoryPeaks.categories.map(\.rawValue))
        return allCases.filter { scope in
            scope == .overall || categories.contains(scope.rawValue)
        }
    }
}
