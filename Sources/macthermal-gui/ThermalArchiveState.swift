import Combine
import Foundation
#if canImport(MacThermalCore)
import MacThermalCore
#endif

/// Stored history and incident state, updated far less often than live sensors.
@MainActor
final class ThermalArchiveState: ObservableObject {
    @Published var history: [ThermalSample] = []
    @Published var incidents: [ThermalIncident] = []

    /// Whether `history` is in non-decreasing timestamp order.
    ///
    /// It normally is — samples are appended as they are taken — which lets
    /// `AnalyticsEngine.recentSamples` binary-search the window instead of
    /// scanning tens of thousands of rows. A backwards clock jump (NTP, DST, a
    /// manual change) breaks the invariant, so it is tracked here where every
    /// mutation goes through, and checked in O(1) on append.
    private(set) var historyIsChronological = true

    /// Installs a freshly decoded on-disk window without losing samples this
    /// session recorded while the decode was in flight.
    ///
    /// Two callers need that: the launch path deliberately starts sampling before
    /// the NDJSON decode finishes, and a retention change reloads a wider window
    /// while sampling continues. Anything newer than the newest decoded sample
    /// has not made it into the loaded set, so it is carried over; anything older
    /// is already represented there.
    func installLoadedHistory(_ loaded: [ThermalSample]) {
        guard let newestLoaded = loaded.last?.timestamp else { return }
        let pending = history.filter { $0.timestamp > newestLoaded }
        history = pending.isEmpty ? loaded : loaded + pending
        // One pass over freshly decoded data, right after the decode already
        // walked it — cheap here, and it keeps every later query on the fast path.
        historyIsChronological = history.indices.dropFirst().allSatisfy {
            history[$0 - 1].timestamp <= history[$0].timestamp
        }
    }

    func appendHistory(_ sample: ThermalSample) {
        if let last = history.last, sample.timestamp < last.timestamp {
            historyIsChronological = false
        }
        history.append(sample)
    }

    func clearHistory() {
        history.removeAll(keepingCapacity: false)
        historyIsChronological = true
    }

    /// Array removal is linear, so pruning is deliberately called in batches
    /// instead of shifting the complete retained history for every new sample.
    func trimHistory(before cutoff: Date) {
        guard let firstRetained = history.firstIndex(where: { $0.timestamp >= cutoff }) else {
            history.removeAll(keepingCapacity: true)
            return
        }
        guard firstRetained > 0 else { return }
        history.removeFirst(firstRetained)
    }

    func replaceIncidents(with value: [ThermalIncident]) {
        incidents = value
    }

    func insertIncident(_ incident: ThermalIncident) {
        incidents.insert(incident, at: 0)
    }

    func renameIncident(id: UUID, to name: String) {
        guard let index = incidents.firstIndex(where: { $0.id == id }) else { return }
        incidents[index] = incidents[index].renamed(to: name)
    }

    func removeIncident(id: UUID) {
        incidents.removeAll { $0.id == id }
    }

    func pruneIncidents(cutoff: Date, maximumCount: Int) {
        incidents.removeAll { $0.endedAt < cutoff }
        if incidents.count > maximumCount {
            incidents.removeLast(incidents.count - maximumCount)
        }
    }
}
