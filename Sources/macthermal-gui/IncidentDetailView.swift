import SwiftUI
#if canImport(MacThermalCore)
import MacThermalCore
#endif

struct IncidentDetailView: View {
    let incident: ThermalIncident
    let monitor: ThermalMonitor
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var status: AppStatusState
    @State private var confirmsDeletion = false
    @State private var presentsRename = false
    @State private var proposedName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignMetrics.sectionSpacing) {
                IncidentTitleView(incident: incident)
                TemperatureHistoryChart(
                    samples: incident.samples,
                    unit: settings.unit,
                    alertThresholdCelsius: settings.alertThresholdCelsius,
                    scope: $settings.temperatureChartScope
                )
                    .equatable()
                    .frame(minHeight: 280)
                HistorySummaryGrid(samples: incident.samples, unit: settings.unit)
                IncidentChangeView(incident: incident, unit: settings.unit)
                IncidentContributorsView(samples: incident.samples)
            }
            .padding()
        }
        .toolbar {
            ToolbarItemGroup {
                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button("Diagnostic report…", systemImage: "doc.richtext", action: exportReport)
                    Button("CSV samples…", systemImage: "tablecells", action: exportCSV)
                }
                Button("Rename Incident", systemImage: "pencil") {
                    proposedName = incident.name
                    presentsRename = true
                }
                Button("Delete Incident", systemImage: "trash", role: .destructive) {
                    confirmsDeletion = true
                }
                .confirmationDialog(
                    "Delete this incident?",
                    isPresented: $confirmsDeletion,
                    titleVisibility: .visible
                ) {
                    Button("Delete Incident", role: .destructive) { monitor.deleteIncident(incident) }
                } message: {
                    Text("Its recorded samples will be removed from the incident list. General history is not affected.")
                }
            }
        }
        .alert("Rename Incident", isPresented: $presentsRename) {
            TextField("Incident name", text: $proposedName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { monitor.renameIncident(incident, to: proposedName) }
                .disabled(proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Use a workload or symptom name so the recording is easy to find later.")
        }
    }

    private func exportReport() {
        Task {
            do {
                try await ReportExporter.exportHTML(title: incident.name, samples: incident.samples)
            } catch is CancellationError {
                return
            } catch {
                status.presentedError = UserFacingError(message: "The incident report could not be exported: \(error.localizedDescription)")
            }
        }
    }

    private func exportCSV() {
        Task {
            do {
                try await ReportExporter.exportCSV(title: incident.name, samples: incident.samples)
            } catch is CancellationError {
                return
            } catch {
                status.presentedError = UserFacingError(message: "The incident samples could not be exported: \(error.localizedDescription)")
            }
        }
    }
}
