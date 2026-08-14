import Foundation

public enum ThermalEventKind: String, Sendable {
    case temperatureExceeded
    case temperatureRecovered
    case pressureBegan
    case pressureEscalated
    case pressureRecovered
}

public struct ThermalEvent: Equatable, Identifiable, Sendable {
    public let timestamp: Date
    public let kind: ThermalEventKind
    public let severity: Severity
    public let hottestCelsius: Double
    public let thresholdCelsius: Double?
    public let thermalStateName: String

    public init(
        timestamp: Date,
        kind: ThermalEventKind,
        severity: Severity,
        hottestCelsius: Double,
        thresholdCelsius: Double? = nil,
        thermalStateName: String
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.severity = severity
        self.hottestCelsius = hottestCelsius
        self.thresholdCelsius = thresholdCelsius
        self.thermalStateName = thermalStateName
    }

    public var id: String {
        "\(timestamp.timeIntervalSinceReferenceDate)-\(kind.rawValue)"
    }
}

public enum ThermalEventAnalyzer {
    public static func events(
        samples: [ThermalSample],
        thresholdCelsius: Double,
        recoveryMarginCelsius: Double = thermalRecoveryMarginCelsius,
        isCancelled: () -> Bool = { false }
    ) -> [ThermalEvent] {
        guard !isCancelled() else { return [] }
        let ordered: [ThermalSample]
        if samples.indices.dropFirst().allSatisfy({
            samples[$0 - 1].timestamp <= samples[$0].timestamp
        }) {
            ordered = samples
        } else {
            ordered = samples.sorted { $0.timestamp < $1.timestamp }
        }
        guard let first = ordered.first else { return [] }

        var result: [ThermalEvent] = []
        var temperatureIsActive = first.hottestCelsius >= thresholdCelsius
        var previousPressureSeverity = pressureSeverity(first.thermalSeverity)

        if temperatureIsActive {
            result.append(event(from: first, kind: .temperatureExceeded, threshold: thresholdCelsius))
        }
        if previousPressureSeverity != nil {
            result.append(event(from: first, kind: .pressureBegan))
        }

        for (offset, sample) in ordered.dropFirst().enumerated() {
            if offset.isMultiple(of: 256), isCancelled() { return [] }
            if !temperatureIsActive, sample.hottestCelsius >= thresholdCelsius {
                temperatureIsActive = true
                result.append(event(from: sample, kind: .temperatureExceeded, threshold: thresholdCelsius))
            } else if temperatureIsActive,
                      sample.hottestCelsius <= thresholdCelsius - max(0, recoveryMarginCelsius) {
                temperatureIsActive = false
                result.append(event(from: sample, kind: .temperatureRecovered, threshold: thresholdCelsius))
            }

            let pressureSeverity = pressureSeverity(sample.thermalSeverity)
            switch (previousPressureSeverity, pressureSeverity) {
            case (nil, .some):
                result.append(event(from: sample, kind: .pressureBegan))
            case (.some(.warn), .some(.critical)):
                result.append(event(from: sample, kind: .pressureEscalated))
            case (.some, nil):
                result.append(event(from: sample, kind: .pressureRecovered))
            default:
                break
            }
            previousPressureSeverity = pressureSeverity
        }

        return Array(result.reversed())
    }

    private static func pressureSeverity(_ severity: Severity) -> Severity? {
        severity == .warn || severity == .critical ? severity : nil
    }

    private static func event(
        from sample: ThermalSample,
        kind: ThermalEventKind,
        threshold: Double? = nil
    ) -> ThermalEvent {
        ThermalEvent(
            timestamp: sample.timestamp,
            kind: kind,
            severity: sample.thermalSeverity,
            hottestCelsius: sample.hottestCelsius,
            thresholdCelsius: threshold,
            thermalStateName: sample.thermalStateName
        )
    }
}
