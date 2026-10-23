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
    private var lastSampleAt: Date?

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
        recoveryMarginCelsius: Double = thermalRecoveryMarginCelsius,
        maximumSampleGap: TimeInterval = maximumPlausibleSampleGap
    ) -> AutomaticIncidentTransition? {
        // Sampling stopped and resumed (sleep, suspension, a stalled refresh).
        // Nothing was recorded across the gap, so the sustained timer restarts —
        // otherwise waking a hot Mac opens an incident immediately, with a
        // pre-roll pulled from before it went to sleep. An incident that was
        // already recording ends here too: its episode stopped being observed
        // when sampling did, and a recording with an hours-long hole in it is
        // not the evidence the user thinks they captured.
        let sampledAfterGap = lastSampleAt.map {
            now.timeIntervalSince($0) > max(0, maximumSampleGap)
        } ?? false
        lastSampleAt = now
        if sampledAfterGap {
            let wasRecording = activeTrigger != nil
            reset()
            if wasRecording { return .stop }
        }

        guard automaticCaptureEnabled && (pressureEnabled || temperatureEnabled) else {
            let shouldStop = activeTrigger != nil
            reset()
            return shouldStop ? .stop : nil
        }

        let pressureIsActive = sample.thermalSeverity == .warn || sample.thermalSeverity == .critical
        let recoveryThreshold = thresholdCelsius - max(0, recoveryMarginCelsius)
        // Keep the sustained timer through ordinary sub-threshold noise, just
        // like notifications and the event timeline. Hysteresis also applies
        // before recording starts, not only while keeping an incident open.
        if !temperatureEnabled {
            hotSince = nil
        } else if hotSince == nil {
            if sample.hottestCelsius >= thresholdCelsius { hotSince = now }
        } else if sample.hottestCelsius <= recoveryThreshold {
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
