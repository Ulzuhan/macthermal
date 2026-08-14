import Foundation

public struct ThermalAlertEvaluator: Sendable {
    private var hotSince: Date?
    private var lastNotificationAt: Date?
    private var pressureWasActive = false

    public init() {}

    public mutating func evaluate(
        sample: ThermalSample,
        configuration: AlertConfiguration,
        now: Date,
        recoveryMarginCelsius: Double = thermalRecoveryMarginCelsius
    ) -> ThermalAlertReason? {
        guard configuration.enabled else {
            hotSince = nil
            pressureWasActive = false
            return nil
        }

        let coolingDown = lastNotificationAt.map {
            now.timeIntervalSince($0) < configuration.cooldown
        } ?? false

        // Temperature bookkeeping runs on every sample (it is not skipped by the
        // pressure branch's early return). Entering the hot state needs a reading
        // at or above the threshold; leaving it needs one a full recovery margin
        // below — the same hysteresis `AutomaticIncidentDetector` and
        // `ThermalEventAnalyzer` apply. Without the margin, one noisy reading
        // 0.2 °C under the threshold restarts the "continuously hot" timer, and at
        // the 2-second cadence used under load the sustained alert never fires for
        // an episode that still gets recorded as an incident.
        if hotSince == nil {
            if sample.hottestCelsius >= configuration.thresholdCelsius { hotSince = now }
        } else if sample.hottestCelsius <= configuration.thresholdCelsius - max(0, recoveryMarginCelsius) {
            hotSince = nil
        }

        let pressureIsActive = sample.thermalSeverity == .warn || sample.thermalSeverity == .critical
        let pressureRisingEdge = pressureIsActive && !pressureWasActive

        if configuration.notifyOnThermalPressure, pressureRisingEdge, !coolingDown {
            pressureWasActive = true
            lastNotificationAt = now
            return .thermalPressure(state: sample.thermalStateName)
        }
        // Only consume the rising edge once we've actually alerted. If a cooldown
        // (from any alert) suppresses it, leave `pressureWasActive` false so the
        // alert still fires when the cooldown clears, rather than being dropped for
        // the whole throttling episode.
        if !pressureIsActive {
            pressureWasActive = false
        } else if !pressureRisingEdge {
            pressureWasActive = true
        }

        guard let hotSince,
              now.timeIntervalSince(hotSince) >= configuration.sustainedDuration,
              !coolingDown else { return nil }

        lastNotificationAt = now
        return .sustainedTemperature(celsius: sample.hottestCelsius)
    }
}
