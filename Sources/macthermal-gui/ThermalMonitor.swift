import Combine
import Foundation
#if canImport(MacThermalCore)
import MacThermalCore
#endif

@MainActor
final class ThermalMonitor: ObservableObject {
    let liveState = ThermalLiveState()
    let archiveState: ThermalArchiveState
    let statusState: AppStatusState
    let incidentRecorder: IncidentRecorder
    var recordingState: IncidentRecordingState { incidentRecorder.state }

    private(set) var launchAtLogin: Bool {
        get { statusState.launchAtLogin }
        set { statusState.launchAtLogin = newValue }
    }
    private var history: [ThermalSample] { archiveState.history }
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
    private let historyStore: HistoryStore
    private let notificationManager = LocalNotificationManager()
    private let loginItemManager = LoginItemManager()
    private var alertEvaluator = ThermalAlertEvaluator()
    private var timer: Timer?
    private var refreshing = false
    private var lastHistoryAt: Date?
    private var lastProcessAt: Date?
    private var cachedProcesses: [ProcessUsage] = []
    private var cachedProcessSnapshotID: UUID?
    private var cachedProcessSampledAt: Date?
    private var initializationTask: Task<Void, Never>?
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
    private let maximumInMemoryHistoryDays = 14
    private let memoryTrimInterval: TimeInterval = 60 * 60
    private var lastMemoryTrimAt: Date?

    init(settings: AppSettings, historyStore: HistoryStore = HistoryStore()) {
        self.settings = settings
        self.historyStore = historyStore
        let archive = ThermalArchiveState()
        let status = AppStatusState()
        archiveState = archive
        statusState = status
        incidentRecorder = IncidentRecorder(
            store: historyStore,
            archive: archive,
            status: status,
            settings: settings
        )

        initializationTask = Task(priority: .utility) { [weak self] in
            await self?.initialize()
        }
        // Set after init so the recorder can wait on the task without the two
        // holding each other alive.
        incidentRecorder.waitUntilArchiveIsReady = { [weak self] in
            await self?.initializationTask?.value
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
        Task { await toggleIncidentRecording() }
    }

    func toggleIncidentRecording() async {
        if incidentRecorder.isRecording {
            await incidentRecorder.stop()
            // Recording raises the sampling rate, so stopping has to re-pick an
            // interval; starting just refreshes now, which reschedules anyway.
            if !refreshing { scheduleNextRefresh() }
        } else {
            await incidentRecorder.start(trigger: .manual, at: .now)
            beginRefresh(priority: .userInitiated)
        }
    }

    func renameIncident(_ incident: ThermalIncident, to proposedName: String) {
        incidentRecorder.rename(incident, to: proposedName)
    }

    func deleteIncident(_ incident: ThermalIncident) {
        incidentRecorder.delete(incident)
    }

    func clearHistory() {
        Task {
            do {
                try await historyStore.clearHistory()
                archiveState.clearHistory()
                // Otherwise the next persisted sample waits out a whole interval
                // (up to a minute) while the user stares at an empty history.
                lastHistoryAt = nil
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
        let incidentWasActive = incidentRecorder.isActive(at: now)
        // An active recording keeps the normal cadence even in Low Power Mode:
        // process attribution is the point of the recording.
        let dueProcessInterval = isLowPowerModeEnabled && !incidentRecorder.isRecording
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
            now: now,
            maximumSampleGap: maximumSampleGap
        ) {
            await notificationManager.send(reason)
        }

        await incidentRecorder.evaluateAutomaticCapture(
            sample: sample,
            now: now,
            maximumSampleGap: maximumSampleGap
        )

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

        await incidentRecorder.record(sample, now: now)
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
        if incidentRecorder.isRecording || isElevated(liveState.menuBarSeverity) || isElevated(liveState.thermal.severity) {
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
    /// Derived from this monitor's own slowest cadence instead of the core's
    /// default, so raising `lowPowerBackgroundRefreshInterval` cannot silently
    /// turn ordinary idle polling into a "sampling stopped" verdict.
    private var maximumSampleGap: TimeInterval {
        lowPowerBackgroundRefreshInterval * 3
    }

    private var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func isElevated(_ severity: Severity) -> Bool {
        switch severity {
        case .warn, .hot, .critical: true
        case .ok, .normal: false
        }
    }

    private func trimInMemoryHistoryIfNeeded(now: Date) {
        guard lastMemoryTrimAt.map({ now.timeIntervalSince($0) >= memoryTrimInterval }) ?? true else { return }
        lastMemoryTrimAt = now
        let retainedDays = min(settings.retentionDays, maximumInMemoryHistoryDays)
        let cutoff = Calendar.current.date(byAdding: .day, value: -retainedDays, to: now) ?? .distantPast
        archiveState.trimHistory(before: cutoff)
    }

    func prepareForTermination() async {
        await incidentRecorder.prepareForTermination()
    }
}
