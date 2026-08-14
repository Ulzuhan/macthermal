import Foundation

// MARK: - Severity
//
// A UI-agnostic health level. The CLI maps it to ANSI colors; the GUI maps it
// to SwiftUI colors. Neither concern leaks into the sensor layer.

public enum Severity: String, Codable, Sendable {
    case ok, normal, warn, hot, critical
}

// MARK: - Sensor labelling
//
// Friendly names for well-known keys. Unknown keys fall back to a
// prefix-based category so the readout stays meaningful across Mac models.

let knownLabels: [String: String] = [
    "TC0P": "CPU proximity", "TC0D": "CPU die", "TC0E": "CPU", "TC0F": "CPU",
    "TG0P": "GPU proximity", "TG0D": "GPU die",
    "TA0P": "Ambient", "TA1P": "Ambient",
    "Th0H": "Heatsink", "TH0P": "Drive",
    "TB0T": "Battery", "TB1T": "Battery", "TB2T": "Battery",
    "Ts0P": "Skin", "Ts1P": "Skin",
    "Tm0P": "Memory", "TPCD": "PCH",
]

public enum Category: String, CaseIterable, Codable, Hashable, Sendable {
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "Memory"
    case battery = "Battery"
    case ambient = "Ambient"
    case other = "Other"
}

public func categorize(_ key: String) -> Category {
    let p = key.prefix(2)
    switch p {
    case "Tp", "Te", "TC", "Tc": return .cpu      // performance / efficiency cores, CPU
    case "Tg", "TG": return .gpu
    case "TB": return .battery
    case "TA", "Ts": return .ambient
    case "Tm", "TM": return .memory
    default:
        if knownLabels[key]?.contains("CPU") == true { return .cpu }
        return .other
    }
}

func label(for key: String) -> String { knownLabels[key] ?? key }

// MARK: - Data model

public struct TempReading: Equatable, Sendable {
    public let key: String
    public let label: String
    public let category: Category
    public let celsius: Double
    public init(key: String, label: String, category: Category, celsius: Double) {
        self.key = key; self.label = label; self.category = category; self.celsius = celsius
    }
}

extension Array where Element == TempReading {
    /// Mean temperature across the readings (0 when empty). Shared so the CLI,
    /// GUI, and JSON report can't drift on how the average is computed.
    public var averageCelsius: Double { isEmpty ? 0 : map { $0.celsius }.reduce(0, +) / Double(count) }
}

public struct FanReading: Equatable, Sendable {
    public let index: Int
    public let rpm: Double
    public let min: Double
    public let max: Double
    public let target: Double
    public var utilization: Double { max > min ? Swift.max(0, Swift.min(100, (rpm - min) / (max - min) * 100)) : 0 }
    public init(index: Int, rpm: Double, min: Double, max: Double, target: Double) {
        self.index = index; self.rpm = rpm; self.min = min; self.max = max; self.target = target
    }
}

// MARK: - Levels (thresholds, shared by CLI + GUI)

public func tempLevel(_ c: Double) -> (label: String, severity: Severity) {
    switch c {
    case ..<60:  return ("cool", .ok)
    case ..<78:  return ("normal", .normal)
    case ..<90:  return ("warm", .warn)
    case ..<100: return ("hot", .hot)
    default:     return ("critical", .critical)
    }
}

public func fanLevel(_ u: Double) -> (label: String, severity: Severity) {
    switch u {
    case ..<5:  return ("idle", .ok)
    case ..<50: return ("low", .ok)
    case ..<85: return ("elevated", .warn)
    default:    return ("maxing", .hot)
    }
}

/// Hysteresis below the user's hotspot threshold: once a hot period has begun
/// it only ends when the hotspot drops this far under the threshold.
///
/// Shared by all three consumers of the threshold — notifications
/// (`ThermalAlertEvaluator`), automatic capture (`AutomaticIncidentDetector`),
/// and the timeline (`ThermalEventAnalyzer`) — so they cannot disagree about
/// when an episode ended. Without it the notification path restarts its
/// "continuously hot" timer on any single sub-threshold reading, and at the
/// 2-second cadence the app polls under load, ordinary SMC noise then silences
/// the alert for an episode the other two still record.
public let thermalRecoveryMarginCelsius = 3.0

// MARK: - OS thermal pressure
//
// The Apple Silicon-supported equivalent of the legacy Intel `pmset -g therm`
// thermal levels (which report "unsupported on this machine" on M-series).

public struct ThermalState: Equatable, Sendable {
    public let name: String
    public let note: String
    public let severity: Severity

    public init(name: String, note: String, severity: Severity) {
        self.name = name
        self.note = note
        self.severity = severity
    }

    public init(processInfoState: ProcessInfo.ThermalState) {
        switch processInfoState {
        case .nominal:  self.init(name: "nominal",  note: "no thermal pressure", severity: .ok)
        case .fair:     self.init(name: "fair",     note: "macOS reports mildly elevated thermal pressure", severity: .normal)
        case .serious:  self.init(name: "serious",  note: "OS is throttling to shed heat", severity: .warn)
        case .critical: self.init(name: "critical", note: "aggressive throttling to prevent shutdown", severity: .critical)
        @unknown default: self.init(name: "unknown", note: "", severity: .ok)
        }
    }

    public static func current() -> ThermalState {
        ThermalState(processInfoState: ProcessInfo.processInfo.thermalState)
    }
}

// MARK: - Helpers

/// Clamps a raw count read from the SMC to a sane, non-negative integer range.
/// Guards against NaN / ∞ / negative / absurdly-large values that would
/// otherwise crash an `Int(_:)` conversion or blow up an allocation. Clamps as
/// a Double *before* converting, since `Int(raw)` itself traps for finite
/// values larger than Int.max.
public func clampedCount(_ raw: Double, upperBound: Int) -> Int {
    guard raw.isFinite, raw >= 0 else { return 0 }
    return Int(min(raw, Double(upperBound)))
}

// MARK: - Collection

// Plausibility bounds (°C) for a temperature reading: a disconnected sensor
// reads ~0, and no real on-die sensor sits at or above 130 °C, so anything
// outside this open range is treated as spurious and dropped.
private let minPlausibleCelsius = 1.0
private let maxPlausibleCelsius = 130.0

public func collectTemps(_ smc: SMC) -> [TempReading] {
    var out: [TempReading] = []
    // `temperatureKeys()` has already filtered to `T…` keys of a temperature
    // type (and caches that set), so here we only read each one's live value
    // and apply a plausibility range to drop spurious readings.
    let keys = (try? smc.temperatureKeys()) ?? []
    for key in keys {
        guard let v = try? smc.read(key), let c = v.double,
              c > minPlausibleCelsius, c < maxPlausibleCelsius else { continue }
        out.append(TempReading(key: key, label: label(for: key), category: categorize(key), celsius: c))
    }
    return out.sorted { $0.celsius > $1.celsius }
}

public func collectFans(_ smc: SMC) -> [FanReading] {
    var fans: [FanReading] = []
    // Fan count and min/max RPM are cached (hardware-fixed); only the live RPM
    // and target are re-read each capture.
    for i in 0..<smc.fanCount() {
        let rpm = (try? smc.read("F\(i)Ac"))?.double ?? 0
        let tg = (try? smc.read("F\(i)Tg"))?.double ?? 0
        let limits = smc.fanLimits(i)
        fans.append(FanReading(index: i, rpm: rpm, min: limits.min, max: limits.max, target: tg))
    }
    return fans
}

// MARK: - Snapshot (aggregate convenience for UIs)

public struct Snapshot: Sendable {
    public let temps: [TempReading]
    public let fans: [FanReading]
    public let thermal: ThermalState

    public var hottest: TempReading? { temps.first }   // collectTemps returns hottest-first
    public var averageC: Double { temps.averageCelsius }
    public func group(_ c: Category) -> [TempReading] { temps.filter { $0.category == c } }

    public static func capture(_ smc: SMC) -> Snapshot {
        Snapshot(temps: collectTemps(smc), fans: collectFans(smc), thermal: .current())
    }
}
