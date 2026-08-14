import Combine
import Foundation
#if canImport(MacThermalCore)
import MacThermalCore
#endif

@MainActor
final class AppSettings: ObservableObject {
    @Published var unit: TempUnit { didSet { save(unit.rawValue, for: "temperatureUnit") } }
    @Published var menuBarMetric: MenuBarMetric { didSet { save(menuBarMetric.rawValue, for: "menuBarMetric") } }
    @Published var temperatureChartScope: TemperatureChartScope { didSet { save(temperatureChartScope.rawValue, for: "temperatureChartScope") } }
    @Published var historyInterval: TimeInterval { didSet { save(historyInterval, for: "historyInterval") } }
    @Published var retentionDays: Int { didSet { save(retentionDays, for: "retentionDays") } }
    @Published var alertsEnabled: Bool { didSet { save(alertsEnabled, for: "alertsEnabled") } }
    @Published var alertThresholdCelsius: Double { didSet { save(alertThresholdCelsius, for: "alertThresholdCelsius") } }
    @Published var sustainedAlertSeconds: TimeInterval { didSet { save(sustainedAlertSeconds, for: "sustainedAlertSeconds") } }
    @Published var alertCooldownMinutes: Double { didSet { save(alertCooldownMinutes, for: "alertCooldownMinutes") } }
    @Published var notifyOnThermalPressure: Bool { didSet { save(notifyOnThermalPressure, for: "notifyOnThermalPressure") } }
    @Published var automaticIncidentCaptureEnabled: Bool { didSet { save(automaticIncidentCaptureEnabled, for: "automaticIncidentCaptureEnabled") } }
    @Published var autoRecordPressureIncidents: Bool { didSet { save(autoRecordPressureIncidents, for: "autoRecordPressureIncidents") } }
    @Published var autoRecordTemperatureIncidents: Bool { didSet { save(autoRecordTemperatureIncidents, for: "autoRecordTemperatureIncidents") } }
    @Published var automaticIncidentRecoverySeconds: TimeInterval { didSet { save(automaticIncidentRecoverySeconds, for: "automaticIncidentRecoverySeconds") } }
    @Published var maximumIncidentDurationMinutes: Double { didSet { save(maximumIncidentDurationMinutes, for: "maximumIncidentDurationMinutes") } }
    @Published var incidentRetentionDays: Int { didSet { save(incidentRetentionDays, for: "incidentRetentionDays") } }
    @Published var maximumStoredIncidents: Int { didSet { save(maximumStoredIncidents, for: "maximumStoredIncidents") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        unit = TempUnit(rawValue: defaults.string(forKey: "temperatureUnit") ?? "") ?? .celsius
        menuBarMetric = MenuBarMetric(rawValue: defaults.string(forKey: "menuBarMetric") ?? "") ?? .hotspot
        temperatureChartScope = TemperatureChartScope(
            rawValue: defaults.string(forKey: "temperatureChartScope") ?? ""
        ) ?? .overall
        historyInterval = defaults.object(forKey: "historyInterval") as? TimeInterval ?? 30
        retentionDays = defaults.object(forKey: "retentionDays") as? Int ?? 7
        alertsEnabled = defaults.object(forKey: "alertsEnabled") as? Bool ?? true
        alertThresholdCelsius = defaults.object(forKey: "alertThresholdCelsius") as? Double ?? 90
        sustainedAlertSeconds = defaults.object(forKey: "sustainedAlertSeconds") as? TimeInterval ?? 60
        alertCooldownMinutes = defaults.object(forKey: "alertCooldownMinutes") as? Double ?? 15
        notifyOnThermalPressure = defaults.object(forKey: "notifyOnThermalPressure") as? Bool ?? true
        let pressureCaptureEnabled = defaults.object(forKey: "autoRecordPressureIncidents") as? Bool ?? true
        let temperatureCaptureEnabled = defaults.object(forKey: "autoRecordTemperatureIncidents") as? Bool ?? true
        autoRecordPressureIncidents = pressureCaptureEnabled
        autoRecordTemperatureIncidents = temperatureCaptureEnabled
        automaticIncidentCaptureEnabled = defaults.object(forKey: "automaticIncidentCaptureEnabled") as? Bool
            ?? (pressureCaptureEnabled || temperatureCaptureEnabled)
        automaticIncidentRecoverySeconds = defaults.object(forKey: "automaticIncidentRecoverySeconds") as? TimeInterval ?? 60
        maximumIncidentDurationMinutes = defaults.object(forKey: "maximumIncidentDurationMinutes") as? Double ?? 60
        incidentRetentionDays = defaults.object(forKey: "incidentRetentionDays") as? Int ?? 30
        maximumStoredIncidents = defaults.object(forKey: "maximumStoredIncidents") as? Int ?? 25
    }

    /// The alert rules, disabled unless a notification can actually be delivered.
    ///
    /// `ThermalAlertEvaluator.evaluate` mutates state as it decides — it starts
    /// the cooldown and consumes the pressure rising edge. Evaluating while the
    /// app has no notification permission would therefore burn a cooldown nobody
    /// saw, silencing the first real alert after the user grants permission.
    func alertConfiguration(notificationsAuthorized: Bool) -> AlertConfiguration {
        AlertConfiguration(
            enabled: alertsEnabled && notificationsAuthorized,
            thresholdCelsius: alertThresholdCelsius,
            sustainedDuration: sustainedAlertSeconds,
            cooldown: alertCooldownMinutes * 60,
            notifyOnThermalPressure: notifyOnThermalPressure
        )
    }

    var maximumIncidentDuration: TimeInterval {
        max(5, maximumIncidentDurationMinutes) * 60
    }

    private func save(_ value: Any, for key: String) {
        defaults.set(value, forKey: key)
    }
}
