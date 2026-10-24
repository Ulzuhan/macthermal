import AppKit
import SwiftUI

struct SettingsView: View {
    let monitor: ThermalMonitor
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var archive: ThermalArchiveState
    @EnvironmentObject private var status: AppStatusState
    @State private var confirmsHistoryClear = false

    var body: some View {
        Form {
            Section("General") {
                Picker("Temperature unit", selection: $settings.unit) {
                    ForEach(TempUnit.allCases) { unit in
                        Text(unit.name).tag(unit)
                    }
                }
                Picker("Menu bar temperature", selection: $settings.menuBarMetric) {
                    ForEach(MenuBarMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                LaunchAtLoginToggle(monitor: monitor)
            }

            Section("History") {
                Picker("Record a sample every", selection: $settings.historyInterval) {
                    Text("15 seconds").tag(TimeInterval(15))
                    Text("30 seconds").tag(TimeInterval(30))
                    Text("1 minute").tag(TimeInterval(60))
                }
                Picker("Keep history for", selection: $settings.retentionDays) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
            }

            Section("Thermal detection") {
                LabeledContent("Hotspot threshold") {
                    HStack {
                        Slider(value: $settings.alertThresholdCelsius, in: 70...110, step: 1)
                        Text(settings.unit.format(settings.alertThresholdCelsius, decimals: 0))
                            .monospacedDigit()
                    }
                }
                Picker("Sustained for", selection: $settings.sustainedAlertSeconds) {
                    Text("15 seconds").tag(TimeInterval(15))
                    Text("1 minute").tag(TimeInterval(60))
                    Text("5 minutes").tag(TimeInterval(300))
                }
                Text("These detection rules are shared by high-temperature notifications and automatic incident recording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Temperature and pressure notifications", isOn: $settings.alertsEnabled)
                Picker("Notification cooldown", selection: $settings.alertCooldownMinutes) {
                    Text("5 minutes").tag(5.0)
                    Text("15 minutes").tag(15.0)
                    Text("1 hour").tag(60.0)
                }
                .disabled(!settings.alertsEnabled)
                Toggle("Notify when macOS reports thermal throttling", isOn: $settings.notifyOnThermalPressure)
                    .disabled(!settings.alertsEnabled)
                LabeledContent("Permission") {
                    if status.notificationsAuthorized {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Allow Notifications", action: monitor.requestNotificationAuthorization)
                    }
                }
            }

            Section("Automatic incident recording") {
                Toggle("Record thermal incidents automatically", isOn: $settings.automaticIncidentCaptureEnabled)
                Toggle("Serious or critical macOS pressure", isOn: $settings.autoRecordPressureIncidents)
                    .disabled(!settings.automaticIncidentCaptureEnabled)
                Toggle("Sustained temperature above the alert threshold", isOn: $settings.autoRecordTemperatureIncidents)
                    .disabled(!settings.automaticIncidentCaptureEnabled)
                Picker("Stop after recovery", selection: $settings.automaticIncidentRecoverySeconds) {
                    Text("30 seconds").tag(TimeInterval(30))
                    Text("1 minute").tag(TimeInterval(60))
                    Text("2 minutes").tag(TimeInterval(120))
                }
                .disabled(
                    !settings.automaticIncidentCaptureEnabled
                        || (!settings.autoRecordPressureIncidents && !settings.autoRecordTemperatureIncidents)
                )
                Text("Turning this off stops an active automatic recording after the next sample. Manual recording remains available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Incident storage") {
                Picker("Split long recordings every", selection: $settings.maximumIncidentDurationMinutes) {
                    Text("30 minutes").tag(30.0)
                    Text("1 hour").tag(60.0)
                    Text("2 hours").tag(120.0)
                }
                Picker("Keep recorded incidents for", selection: $settings.incidentRetentionDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Picker("Maximum recordings", selection: $settings.maximumStoredIncidents) {
                    Text("10 incidents").tag(10)
                    Text("25 incidents").tag(25)
                    Text("50 incidents").tag(50)
                }
                Text("Automatic recordings include up to two minutes before the trigger. Storage limits apply to both automatic and manual incidents.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                LabeledContent("Stored samples", value: archive.history.count.formatted())
                LabeledContent("Recorded incidents", value: archive.incidents.count.formatted())
                HStack {
                    Button("Open Data Folder", systemImage: "folder", action: openDataFolder)
                    Spacer()
                    Button("Clear History", systemImage: "trash", role: .destructive) {
                        confirmsHistoryClear = true
                    }
                    .confirmationDialog(
                        "Clear all thermal history?",
                        isPresented: $confirmsHistoryClear,
                        titleVisibility: .visible
                    ) {
                        Button("Clear History", role: .destructive, action: monitor.clearHistory)
                    } message: {
                        Text("Recorded incidents are preserved. This action cannot be undone.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        // Was a hard 600x720, which could not be resized. Making height fully
        // flexible went too far the other way: the Settings scene ignored
        // `idealHeight` and opened the window at 900x452, showing two and a half
        // of six sections — wider than before and far shorter, so it fit *less*.
        //
        // Width is pinned again (Settings windows are conventionally fixed
        // width, and letting it float produced the 900 pt sprawl) while height
        // stays resizable with a floor high enough that even a collapsed window
        // is usable.
        .frame(
            minWidth: 600, idealWidth: 600, maxWidth: 600,
            minHeight: 600, idealHeight: 720, maxHeight: .infinity
        )
        .onAppear { monitor.refreshNotificationAuthorization() }
    }

    private func openDataFolder() {
        let directory = URL.applicationSupportDirectory.appending(path: "MacThermal", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard NSWorkspace.shared.open(directory) else {
                throw CocoaError(.fileNoSuchFile)
            }
        } catch {
            status.presentedError = UserFacingError(message: "The data folder could not be opened: \(error.localizedDescription)")
        }
    }
}
