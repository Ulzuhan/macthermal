import Foundation
import UserNotifications

// Compiles the production monitor with simulated SMC/XPC/process boundaries.
// Each scenario runs in its own process, with isolated defaults and storage.
private let automatic = CommandLine.arguments.contains("--automatic")

actor StartupGate {
    static let shared = StartupGate()
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            entered = true
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

actor SMCReader {
    var available: Bool { true }
    func capture() -> Snapshot? {
        Snapshot(
            temps: [TempReading(key: "TC0P", label: "CPU", category: .cpu, celsius: 95)],
            fans: [],
            thermal: ThermalState(name: automatic ? "serious" : "nominal", note: "fixture",
                                  severity: automatic ? .warn : .ok)
        )
    }
}

actor ProcessSampler {
    func capture() -> [ProcessUsage]? { [] }
}

actor LoginItemManager {
    func isEnabled() async -> Bool {
        await StartupGate.shared.wait()
        return false
    }
    func setEnabled(_ enabled: Bool) -> (succeeded: Bool, isEnabled: Bool) { (true, enabled) }
}

actor LocalNotificationManager {
    func authorizationStatus() -> UNAuthorizationStatus { .denied }
    func requestAuthorization() throws -> Bool { false }
    func send(_ reason: ThermalAlertReason) {}
}

@main
@MainActor
struct IncidentStartupTests {
    static func main() async throws {
        // A deadlocked initialization barrier must fail CI rather than hang it.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            FileHandle.standardError.write(Data("incident startup test timed out\n".utf8))
            exit(1)
        }
        defer { watchdog.cancel() }

        let directory = FileManager.default.temporaryDirectory.appending(path: "macthermal-startup-\(UUID())")
        let suite = "macthermal-startup-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let now = Date.now
        let previousID = UUID()
        let previousSample = ThermalSample(
            timestamp: now.addingTimeInterval(-60), hottestCelsius: 91, averageCelsius: 80,
            categoryPeaks: ["CPU": 91], fanRPM: [], fanUtilization: [],
            thermalStateName: "serious", thermalSeverity: .warn, topProcesses: []
        )
        let previousStore = HistoryStore(directory: directory)
        try await previousStore.beginActiveIncident(
            id: previousID, name: "Previous session", startedAt: previousSample.timestamp,
            trigger: .manual, samples: [previousSample]
        )
        try await previousStore.flushActiveIncident()

        let store = HistoryStore(directory: directory)
        let settings = AppSettings(defaults: defaults)
        settings.autoRecordTemperatureIncidents = false
        let monitor = ThermalMonitor(settings: settings, historyStore: store)
        while !(await StartupGate.shared.entered) || monitor.liveState.hottest == nil {
            await Task.yield()
        }
        let manualStart = automatic ? nil : Task { await monitor.toggleIncidentRecording() }
        // Hold XPC long enough for the pending refresh/manual task to attempt a
        // start. Correctness assertions below inspect the recovered data, not
        // elapsed time. This intentionally reproduces a slow launch service.
        try await Task.sleep(for: .milliseconds(100))
        let startedBeforeRecovery = monitor.isRecordingIncident
        await StartupGate.shared.release()
        await manualStart?.value
        while monitor.incidentSampleCount == 0 { await Task.yield() }
        await monitor.toggleIncidentRecording()

        let saved = await store.load(
            retentionDays: 7, inMemoryDays: 7, incidentRetentionDays: 30, maximumStoredIncidents: 25
        )
        let previous = saved.incidents.first { $0.id == previousID }
        let current = saved.incidents.first { $0.id != previousID }
        let passed = !startedBeforeRecovery
            && previous?.samples == [previousSample]
            && saved.incidents.count == 2
            && current?.samples.isEmpty == false
            && current?.effectiveTrigger == (automatic ? .automaticThermalPressure : .manual)
            && monitor.presentedError == nil
        guard passed else {
            FileHandle.standardError.write(Data("incident startup failed (\(automatic ? "automatic" : "manual")): early=\(startedBeforeRecovery), previous=\(previous != nil), saved=\(saved.incidents.count), error=\(String(describing: monitor.presentedError))\n".utf8))
            exit(1)
        }
        print("incident startup (\(automatic ? "automatic" : "manual")): live sensors before recovery; both incidents preserved — ok")
    }
}
