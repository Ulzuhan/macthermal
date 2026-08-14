import Foundation

public enum AutomaticIncidentTransition: Equatable, Sendable {
    case start(trigger: ThermalIncidentTrigger, state: String, severity: Severity)
    case stop
}

/// Turns macOS thermal-pressure changes into a stable incident lifecycle.
/// Recovery is deliberately delayed so a brief nominal sample does not split
/// one throttling episode into several recordings.
public struct AutomaticIncidentDetector: Sendable {
    private var activeTrigger: ThermalIncidentTrigger?
    private var hotSince: Date?
    private var recoveryStartedAt: Date?

    public init() {}

    public mutating func evaluate(
        sample: ThermalSample,
        automaticCaptureEnabled: Bool = true,
        pressureEnabled: Bool,
        temperatureEnabled: Bool,
        thresholdCelsius: Double,
        sustainedDuration: TimeInterval,
        recoveryDuration: TimeInterval,
        now: Date,
        recoveryMarginCelsius: Double = thermalRecoveryMarginCelsius
    ) -> AutomaticIncidentTransition? {
        guard automaticCaptureEnabled && (pressureEnabled || temperatureEnabled) else {
            let shouldStop = activeTrigger != nil
            reset()
            return shouldStop ? .stop : nil
        }

        let pressureIsActive = sample.thermalSeverity == .warn || sample.thermalSeverity == .critical
        if temperatureEnabled, sample.hottestCelsius >= thresholdCelsius {
            if hotSince == nil { hotSince = now }
        } else {
            hotSince = nil
        }
        let temperatureIsSustained = hotSince.map {
            now.timeIntervalSince($0) >= max(0, sustainedDuration)
        } ?? false

        if activeTrigger == nil, pressureEnabled, pressureIsActive {
            recoveryStartedAt = nil
            activeTrigger = .automaticThermalPressure
            return .start(
                trigger: .automaticThermalPressure,
                state: sample.thermalStateName,
                severity: sample.thermalSeverity
            )
        }
        if activeTrigger == nil, temperatureEnabled, temperatureIsSustained {
            recoveryStartedAt = nil
            activeTrigger = .automaticHighTemperature
            return .start(
                trigger: .automaticHighTemperature,
                state: sample.thermalStateName,
                severity: sample.thermalSeverity
            )
        }

        guard activeTrigger != nil else { return nil }
        let pressureKeepsRecording = pressureEnabled && pressureIsActive
        let recoveryThreshold = thresholdCelsius - max(0, recoveryMarginCelsius)
        // Temperature hysteresis only holds a *temperature*-triggered incident
        // open. A pressure-triggered one recovers on pressure clearing, so a warm
        // reading below the start threshold can't stretch it indefinitely.
        let temperatureKeepsRecording = activeTrigger == .automaticHighTemperature
            && temperatureEnabled
            && sample.hottestCelsius > recoveryThreshold
        if pressureKeepsRecording || temperatureKeepsRecording {
            recoveryStartedAt = nil
            return nil
        }

        if recoveryStartedAt == nil { recoveryStartedAt = now }
        guard let recoveryStartedAt,
              now.timeIntervalSince(recoveryStartedAt) >= max(0, recoveryDuration) else { return nil }

        reset()
        return .stop
    }

    private mutating func reset() {
        activeTrigger = nil
        hotSince = nil
        recoveryStartedAt = nil
    }
}
