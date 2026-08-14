import Foundation
#if canImport(MacThermalCore)
import MacThermalCore
#endif

/// Samples per-process CPU using macOS' built-in `ps`.
///
/// NOTE: `ps` `%cpu` is **not** the instantaneous figure Activity Monitor shows.
/// Per `ps(1)` it is "a decaying average over up to a minute of previous (real)
/// time", so a reading trails the load that produced it by up to a minute. That
/// is fine for the sustained heat this app attributes — a process pegged for
/// minutes reads high throughout — but it does smear short spikes across
/// neighbouring samples, which is one more reason `HeatContributor` is framed as
/// evidence rather than proof.
///
/// Running it inside an actor keeps the synchronous process and pipe APIs away
/// from the main actor. ThermalMonitor only invokes it for persisted history or
/// an active incident, with a 15-second minimum between process launches.
actor ProcessSampler {
    /// Returns `nil` when `ps` could not be run or its output was unusable, so
    /// callers can keep the previous snapshot instead of recording a phantom
    /// "every process idle" observation that would dilute contributor averages.
    func capture(limit: Int = 8) -> [ProcessUsage]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pcpu=,comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let usages = parse(text)
            // An empty parse means the output was there but unreadable (a format
            // change, a truncated pipe): treat it as a failure, not as idleness.
            guard !usages.isEmpty else { return nil }
            return Array(usages.prefix(limit))
        } catch {
            return nil
        }
    }

    private func parse(_ output: String) -> [ProcessUsage] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3,
                  let pid = Int(fields[0]),
                  let cpu = Double(fields[1]) else { return nil }

            let command = String(fields[2])
            let name = URL(fileURLWithPath: command).lastPathComponent
            guard name != "ps", name != "macthermal-gui" else { return nil }
            return ProcessUsage(pid: pid, name: name, cpuPercent: cpu)
        }
        .sorted { $0.cpuPercent > $1.cpuPercent }
    }
}
