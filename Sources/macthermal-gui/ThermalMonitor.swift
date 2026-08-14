import Combine
import Foundation
#if canImport(MacThermalCore)
import MacThermalCore
#endif

@MainActor
final class ThermalMonitor: ObservableObject {
    let liveState = ThermalLiveState()
    let archiveState = ThermalArchiveState()
    let recordingState = IncidentRecordingState()
    let statusState = AppStatusState()

    private(set) var launchAtLogin: Bool {
        get { statusState.launchAtLogin }
        set { statusState.launchAtLogin = newValue }
    }
    private var history: [ThermalSample] { archiveState.history }
    private var incidents: [ThermalIncident] { archiveState.incidents }
    private(set) var isRecordingIncident: Bool {
        get { recordingState.isRecording }
        set { recordingState.isRecording = newValue }
    }
    private(set) var incidentStartedAt: Date? {
        get { recordingState.startedAt }
        set { recordingState.startedAt = newValue }
    }
    private(set) var incidentSampleCount: Int {
        get { recordingState.sampleCount }
        set { recordingState.sampleCount = newValue }
    }
    private(set) var recordingTrigger: ThermalIncidentTrigger? {
        get { recordingState.trigger }
        set { recordingState.trigger = newValue }
    }
    private(set) var notificationsAuthorized: Bool {
        get { statusState.notificationsAuthorized }
        set { statusState.notificationsAuthorized = newValue }
    }
    var presentedError: UserFacingError? {
        get { statusState.presentedError }
        set { statusState.presentedError = newValue }
    }

    let settings: AppSettings

    private let reader = SMCReader()
    private let processSampler = ProcessSampler()
    private let historyStore = HistoryStore()
    private let notificationManager = LocalNotificationManager()
    private let loginItemManager = LoginItemManager()
    private var alertEvaluator = ThermalAlertEvaluator()
    private var automaticIncidentDetector = AutomaticIncidentDetector()
    private var timer: Timer?
    private var refreshing = false
    private var lastHistoryAt: Date?
    private var lastProcessAt: Date?
    private var cachedProcesses: [ProcessUsage] = []
    private var cachedProcessSnapshotID: UUID?
    private var cachedProcessSampledAt: Date?
    private var incidentSamples: [ThermalSample] = []
    private var activeIncidentID: UUID?
    private var activeIncidentName: String?
    private var activeIncidentJournalAvailable = false
    private var incidentRevision = 0
    private var incidentPersistenceTask: Task<Void, Never>?
    private var historyReloadTask: Task<Void, Never>?
    private var loadedRetentionDays: Int?
    private var cancellables: Set<AnyCancellable> = []
    private var loginItemRequestID = UUID()
    private var userChangedLoginItem = false
    private var panelPresented = false
    private var dashboardPresented = false
    private let processInterval: TimeInterval = 15
    private let backgroundRefreshInterval: TimeInterval = 9
    private let interactiveRefreshInterval: TimeInterval = 3
    private let elevatedRefreshInterval: TimeInterval = 2
    // Low Power Mode is an explicit request to stop doing background work. Only
    // the idle path is stretched: an open panel still feels live, and elevated
    // heat or an active recording keeps full resolution, because that is when
    // the samples are worth the most. The `ps` spawn is stretched hardest — it
    // forks a process, which costs far more than reading the SMC.
    private let lowPowerBackgroundRefreshInterval: TimeInterval = 30
    private let lowPowerProcessInterval: TimeInterval = 60
    private let automaticIncidentPreRoll: TimeInterval = 2 * 60
    private let maximumInMemoryHistoryDays = 14
    private let memoryTrimInterval: TimeInterval = 60 * 60
    private var lastMemoryTrimAt: Date?

    init(settings: AppSettings) {
        self.settings = settings

        Task(priority: .utility) { [weak self] in
            await self?.initialize()
        }
    }

    var hottest: TempReading? { liveState.hottest }
    var averageCelsius: Double { liveState.averageCelsius }
    var menuBarSeverity: Severity { liveState.menuBarSeverity }
    var menuBarSymbol: String { liveState.menuBarSymbol }
    var throttleAssessment: ThrottleAssessment { liveState.throttleAssessment }

    func refresh() {
        beginRefresh(priority: .userInitiated)
    }

    func setPanelPresented(_ presented: Bool) {
        guard panelPresented != presented else { return }
        panelPresented = presented
        presentationDidChange(presented: presented)
    }

    func setDashboardPresented(_ presented: Bool) {
        guard dashboardPresented != presented else { return }
        dashboardPresented = presented
        presentationDidChange(presented: presented)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        userChangedLoginItem = true
        let requestID = UUID()
        loginItemRequestID = requestID
        launchAtLogin = enabled
        Task {
            let result = await loginItemManager.setEnabled(enabled)
            guard loginItemRequestID == requestID else { return }
            launchAtLogin = result.isEnabled
            if !result.succeeded {
                presentedError = UserFacingError(
                    message: "Open at Login couldn't be turned \(enabled ? "on" : "off"). You can add or remove MacThermal manually in System Settings ▸ General ▸ Login Items."
                )
            }
        }
    }

    func toggleIncidentRecording() {
        Task {
            if isRecordingIncident {
                await stopIncidentRecording()
                if !refreshing { scheduleNextRefresh() }
            } else {
                await startIncidentRecording(trigger: .manual, at: .now)
                beginRefresh(priority: .userInitiated)
            }
        }
    }

    func renameIncident(_ incident: ThermalIncident, to proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              incidents.contains(where: { $0.id == incident.id }) else { return }
        archiveState.renameIncident(id: incident.id, to: name)
        scheduleIncidentPersistence()
    }

    func deleteIncident(_ incident: ThermalIncident) {
        archiveState.removeIncident(id: incident.id)
        scheduleIncidentPersistence()
    }

    func clearHistory() {
        Task {
            do {
                try await historyStore.clearHistory()
                archiveState.clearHistory()
            } catch {
                presentedError = UserFacingError(message: "History could not be cleared: \(error.localizedDescription)")
            }
        }
    }

    func requestNotificationAuthorization() {
        Task {
            do {
                notificationsAuthorized = try await notificationManager.requestAuthorization()
            } catch {
                presentedError = UserFacingError(message: "Notification permission failed: \(error.localizedDescription)")
            }
        }
    }

    /// Re-reads notification authorization, which can change at runtime if the
    /// user grants or revokes it in System Settings while the app is running.
    func refreshNotificationAuthorization() {
        Task {
            notificationsAuthorized = await notificationManager.authorizationStatus() == .authorized
        }
    }

    private func initialize() async {
        liveState.setAvailable(await reader.available)
        // Get a temperature on screen first. Everything below is slow: the
        // login-item and notification queries are XPC round-trips, and the
        // history load decodes the whole NDJSON file — ~0.7 s for 14 days at a
        // 30-second interval, and twice that at 15 seconds. Sampling used to wait
        // behind all of it, so the menu bar showed "––" for that long on every
        // launch. The two now race deliberately: `installLoadedHistory` keeps
        // whatever was recorded before the decode finished, whichever order the
        // store's actor serializes them in.
        beginRefresh(priority: .userInitiated)

        let storedLaunchAtLogin = await loginItemManager.isEnabled()
        if !userChangedLoginItem { launchAtLogin = storedLaunchAtLogin }
        notificationsAuthorized = await notificationManager.authorizationStatus() == .authorized

        let retentionDays = settings.retentionDays
        let stored = await historyStore.load(
            retentionDays: retentionDays,
            inMemoryDays: min(retentionDays, maximumInMemoryHistoryDays),
            incidentRetentionDays: settings.incidentRetentionDays,
            maximumStoredIncidents: settings.maximumStoredIncidents
        )
        archiveState.installLoadedHistory(stored.samples)
        archiveState.replaceIncidents(with: stored.incidents)
        loadedRetentionDays = retentionDays
        observeRetentionChanges()
    }

    /// Retention is read once, when history is loaded. Raising it has to re-read
    /// the file or the extra days stay on disk, invisible: the longer comparison
    /// ranges unlock in the UI and then report "not enough data" over history
    /// that is sitting right there. Lowering it re-prunes immediately instead of
    /// waiting up to a day for the next scheduled compaction.
    private func observeRetentionChanges() {
        settings.$retentionDays
            .removeDuplicates()
            .sink { [weak self] days in
                guard let self, days != self.loadedRetentionDays else { return }
                self.reloadStoredHistory(retentionDays: days)
            }
            .store(in: &cancellables)
    }

    private func reloadStoredHistory(retentionDays: Int) {
        loadedRetentionDays = retentionDays
        historyReloadTask?.cancel()
        historyReloadTask = Task { [weak self] in
            guard let self else { return }
            let samples = await self.historyStore.reloadHistoryWindow(
                retentionDays: retentionDays,
                inMemoryDays: min(retentionDays, self.maximumInMemoryHistoryDays)
            )
            guard !Task.isCancelled else { return }
            self.archiveState.installLoadedHistory(samples)
        }
    }

    private func performRefresh() async {
        guard let snapshot = await reader.capture() else {
            liveState.setAvailable(false)
            return
        }
        liveState.apply(snapshot)

        let now = Date.now
        let historyDue = lastHistoryAt.map {
            now.timeIntervalSince($0) >= settings.historyInterval
        } ?? true
        let incidentWasActive = isRecordingIncident && (incidentStartedAt ?? .distantFuture) <= now
        // An active recording keeps the normal cadence even in Low Power Mode:
        // process attribution is the point of the recording.
        let dueProcessInterval = isLowPowerModeEnabled && !isRecordingIncident
            ? lowPowerProcessInterval
            : processInterval
        let processDue = lastProcessAt.map {
            now.timeIntervalSince($0) >= dueProcessInterval
        } ?? true

        if processDue && (historyDue || incidentWasActive) {
            // Only mint a new snapshot identity when `ps` actually produced one.
            // A failed run used to be stored as an empty process list under a
            // fresh ID, which analytics then counted as a genuine observation of
            // "every process idle" and averaged into the contributor ranking.
            // Keeping the previous snapshot instead lets `uniqueByProcessSnapshot`
            // collapse the affected samples into the one real reading they share.
            if let processes = await processSampler.capture() {
                cachedProcesses = processes
                cachedProcessSnapshotID = UUID()
                cachedProcessSampledAt = now
            }
            // Recorded either way, so a persistently failing `ps` is retried on
            // its usual cadence rather than on every refresh.
            lastProcessAt = now
        }

        let sample = ThermalSample(
            snapshot: snapshot,
            processes: cachedProcesses,
            processSnapshotID: cachedProcessSnapshotID,
            processSampledAt: cachedProcessSampledAt,
            timestamp: now
        )
        // Authorization is folded into the configuration rather than checked on
        // the result: `evaluate` starts the cooldown as it decides, so evaluating
        // without permission would burn one on an alert nobody could receive.
        if let reason = alertEvaluator.evaluate(
            sample: sample,
            configuration: settings.alertConfiguration(notificationsAuthorized: notificationsAuthorized),
            now: now
        ) {
            await notificationManager.send(reason)
        }

        let automaticTransition = automaticIncidentDetector.evaluate(
            sample: sample,
            automaticCaptureEnabled: settings.automaticIncidentCaptureEnabled,
            pressureEnabled: settings.autoRecordPressureIncidents,
            temperatureEnabled: settings.autoRecordTemperatureIncidents,
            thresholdCelsius: settings.alertThresholdCelsius,
            sustainedDuration: settings.sustainedAlertSeconds,
            recoveryDuration: settings.automaticIncidentRecoverySeconds,
            now: now
        )
        await handleAutomaticIncidentTransition(automaticTransition, now: now)

        if historyDue {
            archiveState.appendHistory(sample)
            trimInMemoryHistoryIfNeeded(now: now)
            lastHistoryAt = now
            do {
                try await historyStore.append(sample, retentionDays: settings.retentionDays)
            } catch {
                presentedError = UserFacingError(message: "History could not be saved: \(error.localizedDescription)")
            }
        }

        // Re-read the recording state instead of a value captured before the
        // awaits above: this method suspends, and "Stop" can land in that window.
        // Acting on the stale flag appended a sample to the already-reset buffer
        // and left the UI reporting a sample count for a recording that ended.
        guard isRecordingIncident, (incidentStartedAt ?? .distantFuture) <= now else { return }
        incidentSamples.append(sample)
        incidentSampleCount = incidentSamples.count
        if activeIncidentJournalAvailable {
            do {
                try await historyStore.appendActiveIncident(sample)
            } catch {
                activeIncidentJournalAvailable = false
                presentedError = UserFacingError(message: "The active incident journal could not be saved: \(error.localizedDescription)")
            }
        }

        if let startedAt = incidentStartedAt,
           now.timeIntervalSince(startedAt) >= settings.maximumIncidentDuration {
            let trigger = recordingTrigger ?? .manual
            await stopIncidentRecording(endedAt: now)
            await startIncidentRecording(trigger: trigger, at: now, includesPreRoll: false)
        }
    }

    private func beginRefresh(priority: TaskPriority) {
        guard !refreshing else { return }
        timer?.invalidate()
        timer = nil
        refreshing = true

        Task(priority: priority) { [weak self] in
            guard let self else { return }
            await self.performRefresh()
            self.refreshing = false
            self.scheduleNextRefresh()
        }
    }

    private func scheduleNextRefresh() {
        timer?.invalidate()
        let interval = currentRefreshInterval
        let nextTimer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.beginRefresh(priority: .utility)
            }
        }
        nextTimer.tolerance = min(1.5, interval * 0.25)
        RunLoop.main.add(nextTimer, forMode: .common)
        timer = nextTimer
    }

    private func presentationDidChange(presented: Bool) {
        if presented {
            beginRefresh(priority: .utility)
        } else if !refreshing {
            scheduleNextRefresh()
        }
    }

    private var currentRefreshInterval: TimeInterval {
        let activityInterval: TimeInterval
        if isRecordingIncident || isElevated(liveState.menuBarSeverity) || isElevated(liveState.thermal.severity) {
            activityInterval = elevatedRefreshInterval
        } else if panelPresented || dashboardPresented {
            activityInterval = interactiveRefreshInterval
        } else if isLowPowerModeEnabled {
            activityInterval = lowPowerBackgroundRefreshInterval
        } else {
            activityInterval = backgroundRefreshInterval
        }

        guard let lastHistoryAt else { return activityInterval }
        let historyRemaining = settings.historyInterval - Date.now.timeIntervalSince(lastHistoryAt)
        return min(activityInterval, max(0.5, historyRemaining))
    }

    /// Read fresh on each reschedule rather than cached: the user can toggle Low
    /// Power Mode at any time, and the next timer picks the change up within one
    /// interval without needing a notification observer.
    private var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func isElevated(_ severity: Severity) -> Bool {
        switch severity {
        case .warn, .hot, .critical: true
        case .ok, .normal: false
        }
    }

    private func startIncidentRecording(
        trigger: ThermalIncidentTrigger,
        at date: Date,
        includesPreRoll: Bool = true
    ) async {
        guard !isRecordingIncident else { return }
        let preRoll = trigger.isAutomatic && includesPreRoll
            ? ThermalIncidentPreRoll.samples(
                from: history,
                endingAt: date,
                duration: automaticIncidentPreRoll
            )
            : []
        let startedAt = preRoll.first?.timestamp ?? date
        let id = UUID()
        let name = incidentName(trigger: trigger, startedAt: startedAt)
        incidentStartedAt = startedAt
        incidentSamples = preRoll
        incidentSampleCount = preRoll.count
        recordingTrigger = trigger
        activeIncidentID = id
        activeIncidentName = name
        isRecordingIncident = true
        do {
            try await historyStore.beginActiveIncident(
                id: id,
                name: name,
                startedAt: startedAt,
                trigger: trigger,
                samples: preRoll
            )
            activeIncidentJournalAvailable = true
        } catch {
            activeIncidentJournalAvailable = false
            presentedError = UserFacingError(message: "The incident journal could not be started: \(error.localizedDescription)")
        }
    }

    private func stopIncidentRecording(endedAt: Date = .now) async {
        isRecordingIncident = false
        guard let startedAt = incidentStartedAt, !incidentSamples.isEmpty else {
            resetActiveIncidentState()
            await historyStore.discardActiveIncident()
            return
        }

        let trigger = recordingTrigger ?? .manual
        let incident = ThermalIncident(
            id: activeIncidentID ?? UUID(),
            name: activeIncidentName ?? incidentName(trigger: trigger, startedAt: startedAt),
            startedAt: startedAt,
            endedAt: endedAt,
            samples: incidentSamples,
            trigger: trigger
        )
        archiveState.insertIncident(incident)
        pruneStoredIncidents(now: endedAt)
        resetActiveIncidentState()
        await persistIncidentsNow(clearActiveIncident: true)
    }

    private func handleAutomaticIncidentTransition(
        _ transition: AutomaticIncidentTransition?,
        now: Date
    ) async {
        switch transition {
        case .start(let trigger, _, _):
            await startIncidentRecording(trigger: trigger, at: now)
        case .stop:
            if recordingTrigger?.isAutomatic == true {
                await stopIncidentRecording(endedAt: now)
            }
        case nil:
            break
        }
    }

    private func scheduleIncidentPersistence() {
        incidentRevision += 1
        let revision = incidentRevision
        let value = incidents
        incidentPersistenceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await historyStore.saveIncidents(value, revision: revision)
            } catch {
                presentedError = UserFacingError(message: "Incidents could not be saved: \(error.localizedDescription)")
            }
        }
    }

    private func persistIncidentsNow(clearActiveIncident: Bool) async {
        incidentRevision += 1
        let revision = incidentRevision
        do {
            try await historyStore.saveIncidents(
                incidents,
                revision: revision,
                clearActiveIncident: clearActiveIncident
            )
        } catch {
            presentedError = UserFacingError(message: "Incidents could not be saved: \(error.localizedDescription)")
        }
    }

    private func trimInMemoryHistoryIfNeeded(now: Date) {
        guard lastMemoryTrimAt.map({ now.timeIntervalSince($0) >= memoryTrimInterval }) ?? true else { return }
        lastMemoryTrimAt = now
        let retainedDays = min(settings.retentionDays, maximumInMemoryHistoryDays)
        let cutoff = Calendar.current.date(byAdding: .day, value: -retainedDays, to: now) ?? .distantPast
        archiveState.trimHistory(before: cutoff)
    }

    private func pruneStoredIncidents(now: Date) {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -settings.incidentRetentionDays,
            to: now
        ) ?? .distantPast
        archiveState.pruneIncidents(
            cutoff: cutoff,
            maximumCount: max(1, settings.maximumStoredIncidents)
        )
    }

    private func incidentName(trigger: ThermalIncidentTrigger, startedAt: Date) -> String {
        let prefix: String
        switch trigger {
        case .automaticThermalPressure: prefix = "Automatic pressure incident"
        case .automaticHighTemperature: prefix = "Automatic temperature incident"
        case .manual: prefix = "Thermal incident"
        }
        return "\(prefix) \(startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func resetActiveIncidentState() {
        incidentStartedAt = nil
        incidentSamples.removeAll(keepingCapacity: false)
        incidentSampleCount = 0
        recordingTrigger = nil
        activeIncidentID = nil
        activeIncidentName = nil
        activeIncidentJournalAvailable = false
    }

    func prepareForTermination() async {
        do {
            try await historyStore.flushActiveIncident()
        } catch {
            NSLog("macthermal: could not flush active incident: \(error.localizedDescription)")
        }
        await incidentPersistenceTask?.value
    }
}
