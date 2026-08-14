import Foundation

/// A compact, persistable snapshot used by charts, reports, comparisons, and
/// incident recordings. Raw per-key readings remain available in the live UI;
/// history stores category aggregates to keep its on-disk footprint bounded.
public struct ThermalSample: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let hottestCelsius: Double
    public let averageCelsius: Double
    public let categoryPeaks: CategoryTemperatures
    /// Optional for backward compatibility with history recorded before
    /// per-category averages were introduced.
    public let categoryAverages: CategoryTemperatures?
    public let fanRPM: [Double]
    public let fanUtilization: [Double]
    public let thermalStateName: String
    public let thermalSeverity: Severity
    public let topProcesses: [ProcessUsage]
    /// Identifies one real process-list capture. Several high-resolution
    /// temperature samples may share it, but analytics must count it once.
    public let processSnapshotID: UUID?
    public let processSampledAt: Date?

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        hottestCelsius: Double,
        averageCelsius: Double,
        categoryPeaks: CategoryTemperatures,
        categoryAverages: CategoryTemperatures? = nil,
        fanRPM: [Double],
        fanUtilization: [Double],
        thermalStateName: String,
        thermalSeverity: Severity,
        topProcesses: [ProcessUsage],
        processSnapshotID: UUID? = nil,
        processSampledAt: Date? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.hottestCelsius = hottestCelsius
        self.averageCelsius = averageCelsius
        self.categoryPeaks = categoryPeaks
        self.categoryAverages = categoryAverages
        self.fanRPM = fanRPM
        self.fanUtilization = fanUtilization
        self.thermalStateName = thermalStateName
        self.thermalSeverity = thermalSeverity
        self.topProcesses = topProcesses
        self.processSnapshotID = processSnapshotID
        self.processSampledAt = processSampledAt
    }

    public init(
        snapshot: Snapshot,
        processes: [ProcessUsage],
        processSnapshotID: UUID? = nil,
        processSampledAt: Date? = nil,
        timestamp: Date = .now
    ) {
        var peaks = CategoryTemperatures()
        var averages = CategoryTemperatures()
        for category in Category.allCases {
            let readings = snapshot.group(category)
            if let hottest = readings.first?.celsius {
                peaks[category] = hottest
                averages[category] = readings.averageCelsius
            }
        }

        self.init(
            timestamp: timestamp,
            hottestCelsius: snapshot.hottest?.celsius ?? 0,
            averageCelsius: snapshot.averageC,
            categoryPeaks: peaks,
            categoryAverages: averages,
            fanRPM: snapshot.fans.map(\.rpm),
            fanUtilization: snapshot.fans.map(\.utilization),
            thermalStateName: snapshot.thermal.name,
            thermalSeverity: snapshot.thermal.severity,
            topProcesses: processes,
            processSnapshotID: processSnapshotID,
            processSampledAt: processSampledAt
        )
    }

    public var averageFanUtilization: Double {
        fanUtilization.isEmpty ? 0 : fanUtilization.reduce(0, +) / Double(fanUtilization.count)
    }
}
