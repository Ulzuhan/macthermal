import Foundation
#if canImport(MacThermalCore)
import MacThermalCore
#endif

/// Owns the non-Sendable IOKit connection so sensor access never crosses an
/// isolation boundary or blocks the main actor.
///
/// The connection can die while the app runs — and when it does, each key read
/// fails individually while the capture itself still succeeds with nothing in
/// it. Treating an empty capture as a failure is what lets the UI fall back to
/// its "SMC unavailable" state instead of showing a live-looking panel with no
/// sensors, and what triggers a replacement connection.
actor SMCReader {
    private var smc: SMC?
    private var health = SensorConnectionHealth()

    init() {
        smc = try? SMC()
    }

    var available: Bool { smc != nil && health.isHealthy }

    func capture(now: Date = .now) -> Snapshot? {
        if let smc, let snapshot = readableSnapshot(from: smc) {
            health.recordSuccess()
            return snapshot
        }

        // No connection, or one that reads nothing. Both are the same problem
        // from here; `recordFailure` decides when it is worth paying for a
        // fresh `IOServiceOpen` rather than retrying every few seconds.
        guard health.recordFailure(now: now) else { return nil }
        smc = try? SMC()
        guard let smc, let snapshot = readableSnapshot(from: smc) else { return nil }
        health.recordSuccess()
        return snapshot
    }

    /// A capture is only real if it carries at least one plausible temperature.
    /// Every Mac exposes some, so an empty set means the reads failed rather
    /// than that the machine has nothing to report.
    private func readableSnapshot(from smc: SMC) -> Snapshot? {
        let snapshot = Snapshot.capture(smc)
        return snapshot.temps.isEmpty ? nil : snapshot
    }
}
