import Foundation

public enum DiagnosticReportRenderer {
    public static func csv(samples: [ThermalSample]) -> String {
        var lines = [
            "timestamp,hotspot_c,average_c,cpu_peak_c,gpu_peak_c,memory_peak_c,battery_peak_c,fan_utilization_percent,thermal_state,top_process,top_process_cpu_percent"
        ]
        let formatter = ISO8601DateFormatter()
        for sample in samples {
            let topProcess = sample.topProcesses.first
            lines.append([
                formatter.string(from: sample.timestamp),
                String(sample.hottestCelsius),
                String(sample.averageCelsius),
                optionalDecimal(sample.categoryPeaks["CPU"]),
                optionalDecimal(sample.categoryPeaks["GPU"]),
                optionalDecimal(sample.categoryPeaks["Memory"]),
                optionalDecimal(sample.categoryPeaks["Battery"]),
                String(sample.averageFanUtilization),
                csvEscape(sample.thermalStateName),
                csvEscape(topProcess?.name ?? ""),
                optionalDecimal(topProcess?.cpuPercent),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func html(
        title: String,
        samples: [ThermalSample],
        context: DiagnosticContext? = nil
    ) -> String {
        let summary = ThermalSummary(samples: samples)
        let contributors = ThermalAnalytics.heatContributors(samples: samples).prefix(10)
        let generated = Date.now.formatted(date: .abbreviated, time: .standard)

        let contributorRows = contributors.map { item in
            "<tr><td>\(htmlEscape(item.processName))</td><td>\(decimal(item.hotAverageCPUPercent, digits: 1))%</td><td>\(decimal(item.peakCPUPercent, digits: 1))%</td><td>\(htmlEscape(item.pattern.label))</td><td>\(item.hotSampleCount)</td></tr>"
        }.joined().nonEmpty ?? "<tr><td colspan=\"5\" class=\"note\">Not enough process samples during hot periods to attribute the heat.</td></tr>"

        let sampleRows = samples.suffix(500).map { sample in
            let process = sample.topProcesses.first
            let processText = process.map { "\($0.name) (\(decimal($0.cpuPercent, digits: 1))%)" } ?? "—"
            return "<tr><td>\(htmlEscape(sample.timestamp.formatted(date: .numeric, time: .standard)))</td><td>\(decimal(sample.hottestCelsius, digits: 1))°C</td><td>\(decimal(sample.averageCelsius, digits: 1))°C</td><td>\(decimal(sample.averageFanUtilization, digits: 0))%</td><td>\(htmlEscape(sample.thermalStateName))</td><td>\(htmlEscape(processText))</td></tr>"
        }.joined()

        let systemContext = context.map { context in
            """
            <h2>System context</h2><table><tbody>
            <tr><th>Mac</th><td>\(htmlEscape(context.hardwareModel))</td><th>Architecture</th><td>\(htmlEscape(context.architecture))</td></tr>
            <tr><th>macOS</th><td>\(htmlEscape(context.operatingSystem))</td><th>CPU</th><td>\(context.processorCount) logical cores</td></tr>
            <tr><th>Memory</th><td>\(byteCount(context.physicalMemoryBytes))</td><th>MacThermal</th><td>\(htmlEscape(context.appVersion))</td></tr>
            </tbody></table>
            """
        } ?? ""

        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(htmlEscape(title))</title>
        <style>:root{color-scheme:light dark}body{font:14px -apple-system,BlinkMacSystemFont,sans-serif;color:#1d1d1f;background:#fff;max-width:1100px;margin:40px auto;padding:0 24px}h1{font-size:28px}h2{margin-top:32px}section{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}.metric{background:#f5f5f7;border-radius:12px;padding:16px}.metric strong{display:block;font-size:24px;margin-top:6px}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px;border-bottom:1px solid #ddd}th{background:#f5f5f7}.note{color:#6e6e73}@media(prefers-color-scheme:dark){body{color:#f5f5f7;background:#1d1d1f}.metric,th{background:#2c2c2e}th,td{border-color:#48484a}.note{color:#aeaeb2}}@media(max-width:700px){section{grid-template-columns:repeat(2,1fr)}body{margin:20px auto;padding:0 12px;overflow-wrap:anywhere}}@media print{body{color:#000;background:#fff;margin:0;max-width:none}.metric,th{background:#f5f5f7}}</style></head>
        <body><h1>\(htmlEscape(title))</h1><p class="note">Generated \(htmlEscape(generated)) by MacThermal Pro. CPU load while hot is diagnostic evidence, not proof of causation.</p>
        <section><div class="metric">Samples<strong>\(summary.sampleCount)</strong></div><div class="metric">Average hotspot<strong>\(decimal(summary.averageHotspotCelsius, digits: 1))°C</strong></div><div class="metric">Peak hotspot<strong>\(decimal(summary.peakHotspotCelsius, digits: 1))°C</strong></div><div class="metric">Pressure samples<strong>\(summary.pressureSampleCount)</strong></div></section>
        \(systemContext)
        <h2>Likely contributors</h2><table><thead><tr><th>Process</th><th>CPU while hot</th><th>Peak CPU</th><th>Pattern</th><th>Hot samples</th></tr></thead><tbody>\(contributorRows)</tbody></table>
        <h2>Recent samples</h2><table><thead><tr><th>Time</th><th>Hotspot</th><th>Average</th><th>Fan</th><th>Pressure</th><th>Top process</th></tr></thead><tbody>\(sampleRows)</tbody></table></body></html>
        """
    }

    private static func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    private static func optionalDecimal(_ value: Double?) -> String {
        value.map { String($0) } ?? ""
    }

    private static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    /// Quotes a CSV field, and defuses spreadsheet formula injection.
    ///
    /// Process names come from `ps comm=`, i.e. real executable basenames, which
    /// an attacker controls by naming a binary `=HYPERLINK(...)`. Excel, Numbers,
    /// and Sheets evaluate a cell starting with `= + - @` (or a tab/CR before
    /// one), so the leading character is escaped with a single quote — the
    /// convention those apps understand — before the field is quoted. `\r` is
    /// treated as a line break too: alone it is a classic-Mac newline that splits
    /// the record in several parsers.
    private static func csvEscape(_ value: String) -> String {
        let neutralized = value.first.map { "=+-@\t\r".contains($0) ? "'" + value : value } ?? value
        let needsQuoting = neutralized.contains(",")
            || neutralized.contains("\"")
            || neutralized.contains("\n")
            || neutralized.contains("\r")
        guard needsQuoting else { return neutralized }
        return "\"\(neutralized.replacing("\"", with: "\"\""))\""
    }

    private static func htmlEscape(_ value: String) -> String {
        value
            .replacing("&", with: "&amp;")
            .replacing("<", with: "&lt;")
            .replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
