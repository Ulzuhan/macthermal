import Foundation
#if canImport(MacThermalCore)
import MacThermalCore
#endif

/// Owns the whole life of a thermal incident: when one starts, what goes into
/// it, how it is journaled while it runs, and how it is finalized and pruned.
///
/// Split out of `ThermalMonitor`, which had grown to 53 stored properties doing
/// this alongside polling, history, alerts and system integration. Both
/// concurrency bugs found in recent audits lived in the seam between the two —
/// a recording flag read across an `await`, and a journal opened before the
/// previous session's incidents had been restored — because the reentrancy of
/// one concern was hard to see among the others.
///
/// Everything here is `@MainActor`, like the state it publishes; the actual I/O
/// hops to the `HistoryStore` actor.
@MainActor
final class IncidentRecorder {
    let state = IncidentRecordingState()

    /// Awaited before any journal is opened. Live readings start before the
    /// previous session's incidents have been restored, so a recording that
    /// begins in that window must wait or it will overwrite the journal that
    /// recovery is still reading.
    var waitUntilArchiveIsReady: @MainActor () async -> Void = {}

    private let store: HistoryStore
    private let archive: ThermalArchiveState
    private let status: AppStatusState
    private let settings: AppSettings

    private var detector = AutomaticIncidentDetector()
    private var samples: [ThermalSample] = []
    private var activeID: UUID?
    private var activeName: String?
    private var journalAvailable = false
    private var revision = 0
    private var persistenceTask: Task<Void, Never>?

    private let preRollDuration: TimeInterval = 2 * 60

    init(
        store: HistoryStore,
        archive: ThermalArchiveState,
        status: AppStatusState,
        settings: AppSettings
    ) {
        self.store = store
        self.archive = archive
        self.status = status
        self.settings = settings
    }

    var isRecording: Bool { state.isRecording }
    var trigger: ThermalIncidentTrigger? { state.trigger }

    /// Whether a recording is both active and already past its start instant —
    /// an automatic incident back-dates its start to the beginning of its
    /// pre-roll, so `startedAt` can be earlier than the sample being handled.
    func isActive(at date: Date) -> Bool {
        state.isRecording && (state.startedAt ?? .distantFuture) <= date
    }

    // MARK: - Lifecycle

    func start(
        trigger: ThermalIncidentTrigger,
        at date: Date,
        includesPreRoll: Bool = true
    ) async {
        await waitUntilArchiveIsReady()
        // Re-checked after the wait: a manual and an automatic start can both be
        // pending while initialization is suspended.
        guard !state.isRecording else { return }

        let preRoll = trigger.isAutomatic && includesPreRoll
            ? ThermalIncidentPreRoll.samples(
                from: archive.history,
                endingAt: date,
                duration: preRollDuration
            )
            : []
        let startedAt = preRoll.first?.timestamp ?? date
        let id = UUID()
        let name = Self.name(trigger: trigger, startedAt: startedAt)

        state.startedAt = startedAt
        state.sampleCount = preRoll.count
        state.trigger = trigger
        state.isRecording = true
        samples = preRoll
        activeID = id
        activeName = name

        do {
            try await store.beginActiveIncident(
                id: id,
                name: name,
                startedAt: startedAt,
                trigger: trigger,
                samples: preRoll
            )
            journalAvailable = true
        } catch {
            journalAvailable = false
            report("The incident journal could not be started: \(error.localizedDescription)")
        }
    }

    func stop(endedAt: Date = .now) async {
        state.isRecording = false
        guard let startedAt = state.startedAt, !samples.isEmpty else {
            resetActiveState()
            await store.discardActiveIncident()
            return
        }

        let trigger = state.trigger ?? .manual
        let incident = ThermalIncident(
            id: activeID ?? UUID(),
            name: activeName ?? Self.name(trigger: trigger, startedAt: startedAt),
            startedAt: startedAt,
            endedAt: endedAt,
            samples: samples,
            trigger: trigger
        )
        archive.insertIncident(incident)
        pruneStored(now: endedAt)
        resetActiveState()
        await persistNow(clearActiveIncident: true)
    }

    // MARK: - Sampling

    /// Lets automatic capture see a sample and act on what it decides.
    func evaluateAutomaticCapture(
        sample: ThermalSample,
        now: Date,
        maximumSampleGap: TimeInterval
    ) async {
        let transition = detector.evaluate(
            sample: sample,
            automaticCaptureEnabled: settings.automaticIncidentCaptureEnabled,
            pressureEnabled: settings.autoRecordPressureIncidents,
            temperatureEnabled: settings.autoRecordTemperatureIncidents,
            thresholdCelsius: settings.alertThresholdCelsius,
            sustainedDuration: settings.sustainedAlertSeconds,
            recoveryDuration: settings.automaticIncidentRecoverySeconds,
            now: now,
            maximumSampleGap: maximumSampleGap
        )
        switch transition {
        case .start(let trigger, _, _):
            await start(trigger: trigger, at: now)
        case .stop:
            // A manual recording outlives automatic capture's opinion of it.
            if state.trigger?.isAutomatic == true { await stop(endedAt: now) }
        case nil:
            break
        }
    }

    /// Adds a sample to the running recording, if there is one.
    func record(_ sample: ThermalSample, now: Date) async {
        guard isActive(at: now) else { return }
        samples.append(sample)
        state.sampleCount = samples.count

        if journalAvailable {
            do {
                try await store.appendActiveIncident(sample)
            } catch {
                journalAvailable = false
                report("The active incident journal could not be saved: \(error.localizedDescription)")
            }
        }

        // Long recordings are split rather than grown without bound. The state
        // is re-read after the await above, because "Stop" can land in it.
        guard let startedAt = state.startedAt, state.isRecording,
              now.timeIntervalSince(startedAt) >= settings.maximumIncidentDuration else { return }
        let trigger = state.trigger ?? .manual
        await stop(endedAt: now)
        await start(trigger: trigger, at: now, includesPreRoll: false)
    }

    // MARK: - Stored incidents

    func rename(_ incident: ThermalIncident, to proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              archive.incidents.contains(where: { $0.id == incident.id }) else { return }
        archive.renameIncident(id: incident.id, to: name)
        schedulePersistence()
    }

    func delete(_ incident: ThermalIncident) {
        archive.removeIncident(id: incident.id)
        schedulePersistence()
    }

    func prepareForTermination() async {
        do {
            try await store.flushActiveIncident()
        } catch {
            NSLog("macthermal: could not flush active incident: \(error.localizedDescription)")
        }
        await persistenceTask?.value
    }

    // MARK: - Persistence

    private func schedulePersistence() {
        revision += 1
        let revision = revision
        let value = archive.incidents
        persistenceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.store.saveIncidents(value, revision: revision)
            } catch {
                self.report("Incidents could not be saved: \(error.localizedDescription)")
            }
        }
    }

    private func persistNow(clearActiveIncident: Bool) async {
        revision += 1
        let revision = revision
        do {
            try await store.saveIncidents(
                archive.incidents,
                revision: revision,
                clearActiveIncident: clearActiveIncident
            )
        } catch {
            report("Incidents could not be saved: \(error.localizedDescription)")
        }
    }

    private func pruneStored(now: Date) {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -settings.incidentRetentionDays,
            to: now
        ) ?? .distantPast
        archive.pruneIncidents(
            cutoff: cutoff,
            maximumCount: max(1, settings.maximumStoredIncidents)
        )
    }

    private func resetActiveState() {
        state.startedAt = nil
        state.sampleCount = 0
        state.trigger = nil
        samples.removeAll(keepingCapacity: false)
        activeID = nil
        activeName = nil
        journalAvailable = false
    }

    private func report(_ message: String) {
        status.presentedError = UserFacingError(message: message)
    }

    private static func name(trigger: ThermalIncidentTrigger, startedAt: Date) -> String {
        let prefix: String
        switch trigger {
        case .automaticThermalPressure: prefix = "Automatic pressure incident"
        case .automaticHighTemperature: prefix = "Automatic temperature incident"
        case .manual: prefix = "Thermal incident"
        }
        return "\(prefix) \(startedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
