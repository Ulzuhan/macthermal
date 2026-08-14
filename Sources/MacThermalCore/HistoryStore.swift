import Foundation

/// Local persistence for thermal history and incident recordings.
///
/// Lives in the core rather than beside the UI: it touches only Foundation and
/// the sample/incident models, and it holds the most failure-prone logic in the
/// project — append-only NDJSON, tolerance for a last line truncated by a crash,
/// daily compaction through a temporary file, and recovery of an incident whose
/// recording never got to finish. All of that is testable without hardware, and
/// `init(directory:)` exists so tests can point it at a scratch folder.
public actor HistoryStore {
    private let directory: URL
    private let historyURL: URL
    private let incidentsURL: URL
    private let activeIncidentURL: URL
    private let activeIncidentMetadataURL: URL
    private let pruneStampURL: URL
    private var lastPruneAt: Date?
    private var latestIncidentRevision = 0
    private var activeIncidentHandle: FileHandle?
    private var activeWritesSinceSync = 0
    private let pruneInterval: TimeInterval = 24 * 60 * 60
    private let activeSyncInterval = 5

    public init(directory: URL? = nil) {
        let directory = directory
            ?? URL.applicationSupportDirectory.appending(path: "MacThermal", directoryHint: .isDirectory)
        let pruneStampURL = directory.appending(path: ".last-history-prune")
        self.directory = directory
        historyURL = directory.appending(path: "history.ndjson")
        incidentsURL = directory.appending(path: "incidents.json")
        activeIncidentURL = directory.appending(path: "active-incident.ndjson")
        activeIncidentMetadataURL = directory.appending(path: "active-incident.json")
        self.pruneStampURL = pruneStampURL
        lastPruneAt = Self.loadPruneDate(from: pruneStampURL)
    }

    public func load(
        retentionDays: Int,
        inMemoryDays: Int,
        incidentRetentionDays: Int,
        maximumStoredIncidents: Int
    ) -> (samples: [ThermalSample], incidents: [ThermalIncident]) {
        createDirectoryIfNeeded()
        removeOrphanedPruneTemporaries()
        let historyCutoff = Calendar.current.date(byAdding: .day, value: -inMemoryDays, to: .now) ?? .distantPast
        let decoder = JSONDecoder()
        let samples = (try? loadSamples(from: historyURL, since: historyCutoff, decoder: decoder)) ?? []

        var incidents = (try? Data(contentsOf: incidentsURL))
            .flatMap { try? decoder.decode([ThermalIncident].self, from: $0) } ?? []
        incidents.sort { $0.startedAt > $1.startedAt }

        if let recovered = recoverActiveIncident(decoder: decoder) {
            if !incidents.contains(where: { $0.id == recovered.id }) {
                incidents.insert(recovered, at: 0)
            }
            if (try? writeIncidents(incidents)) != nil {
                clearActiveIncidentFiles()
            }
        }

        let countBeforeRetention = incidents.count
        let incidentCutoff = Calendar.current.date(
            byAdding: .day,
            value: -incidentRetentionDays,
            to: .now
        ) ?? .distantPast
        incidents.removeAll { $0.endedAt < incidentCutoff }
        let incidentLimit = max(1, maximumStoredIncidents)
        if incidents.count > incidentLimit {
            incidents.removeLast(incidents.count - incidentLimit)
        }
        if incidents.count != countBeforeRetention {
            try? writeIncidents(incidents)
        }

        // Disk retention remains independent from the smaller in-memory window.
        // Stamping the run here matters: without it the very next `append` sees
        // no recorded prune and rewrites the whole file a second time.
        if lastPruneAt == nil {
            try? prune(retentionDays: retentionDays)
            let now = Date.now
            lastPruneAt = now
            try? persistPruneDate(now)
        }
        return (samples, incidents)
    }

    /// Re-reads only the in-memory sample window, for a retention change.
    ///
    /// Deliberately narrower than `load`: it must not re-run active-incident
    /// recovery, and it must not return an incident list that could clobber one
    /// this session recorded but has not finished persisting. Disk retention is
    /// applied immediately instead of waiting for the next daily prune, so
    /// lowering retention frees space when the user asks for it.
    public func reloadHistoryWindow(retentionDays: Int, inMemoryDays: Int) -> [ThermalSample] {
        createDirectoryIfNeeded()
        let now = Date.now
        try? prune(retentionDays: retentionDays)
        lastPruneAt = now
        try? persistPruneDate(now)

        let cutoff = Calendar.current.date(byAdding: .day, value: -inMemoryDays, to: now) ?? .distantPast
        return (try? loadSamples(from: historyURL, since: cutoff, decoder: JSONDecoder())) ?? []
    }

    public func append(_ sample: ThermalSample, retentionDays: Int) throws {
        createDirectoryIfNeeded()
        try appendEncoded(sample, to: historyURL)

        if lastPruneAt.map({ Date.now.timeIntervalSince($0) >= pruneInterval }) ?? true {
            try prune(retentionDays: retentionDays)
            let now = Date.now
            lastPruneAt = now
            try? persistPruneDate(now)
        }
    }

    public func beginActiveIncident(
        id: UUID,
        name: String,
        startedAt: Date,
        trigger: ThermalIncidentTrigger,
        samples: [ThermalSample]
    ) throws {
        createDirectoryIfNeeded()
        try closeActiveIncidentHandle()
        let metadata = ActiveIncidentMetadata(
            id: id,
            name: name,
            startedAt: startedAt,
            trigger: trigger
        )
        try JSONEncoder().encode(metadata).write(to: activeIncidentMetadataURL, options: .atomic)

        var data = Data()
        let encoder = JSONEncoder()
        for sample in samples {
            data.append(try encoder.encode(sample))
            data.append(0x0A)
        }
        try data.write(to: activeIncidentURL, options: .atomic)
        activeIncidentHandle = try FileHandle(forWritingTo: activeIncidentURL)
        try activeIncidentHandle?.seekToEnd()
        activeWritesSinceSync = 0
    }

    public func appendActiveIncident(_ sample: ThermalSample) throws {
        guard FileManager.default.fileExists(atPath: activeIncidentMetadataURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if activeIncidentHandle == nil {
            activeIncidentHandle = try FileHandle(forWritingTo: activeIncidentURL)
            try activeIncidentHandle?.seekToEnd()
        }
        var data = try JSONEncoder().encode(sample)
        data.append(0x0A)
        try activeIncidentHandle?.write(contentsOf: data)
        activeWritesSinceSync += 1
        if activeWritesSinceSync >= activeSyncInterval {
            try activeIncidentHandle?.synchronize()
            activeWritesSinceSync = 0
        }
    }

    public func saveIncidents(
        _ incidents: [ThermalIncident],
        revision: Int,
        clearActiveIncident: Bool = false
    ) throws {
        guard revision >= latestIncidentRevision else { return }
        createDirectoryIfNeeded()
        if clearActiveIncident { try flushActiveIncident() }
        try writeIncidents(incidents)
        latestIncidentRevision = revision
        if clearActiveIncident { clearActiveIncidentFiles() }
    }

    public func flushActiveIncident() throws {
        try activeIncidentHandle?.synchronize()
        activeWritesSinceSync = 0
    }

    public func discardActiveIncident() {
        clearActiveIncidentFiles()
    }

    public func clearHistory() throws {
        if FileManager.default.fileExists(atPath: historyURL.path) {
            try FileManager.default.removeItem(at: historyURL)
        }
    }

    public nonisolated var storageDirectory: URL { directory }

    private func writeIncidents(_ incidents: [ThermalIncident]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(incidents).write(to: incidentsURL, options: .atomic)
    }

    private func recoverActiveIncident(decoder: JSONDecoder) -> ThermalIncident? {
        guard let metadataData = try? Data(contentsOf: activeIncidentMetadataURL),
              let metadata = try? decoder.decode(ActiveIncidentMetadata.self, from: metadataData),
              let samples = try? loadSamples(from: activeIncidentURL, since: .distantPast, decoder: decoder),
              let lastSample = samples.last else { return nil }
        return ThermalIncident(
            id: metadata.id,
            name: metadata.name + " (recovered)",
            startedAt: metadata.startedAt,
            endedAt: lastSample.timestamp,
            samples: samples,
            trigger: metadata.trigger
        )
    }

    private func clearActiveIncidentFiles() {
        try? closeActiveIncidentHandle()
        try? FileManager.default.removeItem(at: activeIncidentURL)
        try? FileManager.default.removeItem(at: activeIncidentMetadataURL)
        activeWritesSinceSync = 0
    }

    private func closeActiveIncidentHandle() throws {
        guard let activeIncidentHandle else { return }
        try activeIncidentHandle.synchronize()
        try activeIncidentHandle.close()
        self.activeIncidentHandle = nil
    }

    private func appendEncoded<T: Encodable>(_ value: T, to url: URL) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func prune(retentionDays: Int) throws {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: .now) ?? .distantPast
        if let oldestTimestamp = try oldestSampleTimestamp(), oldestTimestamp >= cutoff { return }

        let temporaryURL = directory.appending(path: "history-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let output = try FileHandle(forWritingTo: temporaryURL)
        var outputClosed = false
        defer {
            if !outputClosed { try? output.close() }
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        let decoder = JSONDecoder()
        let newline = Data([0x0A])
        try forEachLine(in: historyURL) { line in
            guard let envelope = try? decoder.decode(TimestampEnvelope.self, from: line),
                  envelope.timestamp >= cutoff else { return }
            try output.write(contentsOf: line)
            try output.write(contentsOf: newline)
        }
        try output.synchronize()
        try output.close()
        outputClosed = true
        _ = try FileManager.default.replaceItemAt(historyURL, withItemAt: temporaryURL)
    }

    private func createDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Deletes compaction temporaries left behind by a crash or force-quit.
    ///
    /// `prune` removes its own temporary on every normal exit path, but a SIGKILL
    /// mid-compaction strands a copy of the surviving history — tens of megabytes
    /// on a mature install — that nothing would ever reclaim.
    private func removeOrphanedPruneTemporaries() {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for url in contents ?? [] where url.lastPathComponent.hasPrefix("history-")
            && url.pathExtension == "tmp" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func loadSamples(
        from url: URL,
        since cutoff: Date,
        decoder: JSONDecoder
    ) throws -> [ThermalSample] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var samples: [ThermalSample] = []
        try forEachLine(in: url) { line in
            guard let sample = try? decoder.decode(ThermalSample.self, from: line),
                  sample.timestamp >= cutoff else { return }
            samples.append(sample)
        }
        return samples
    }

    private func oldestSampleTimestamp() throws -> Date? {
        let input = try FileHandle(forReadingFrom: historyURL)
        defer { try? input.close() }
        guard let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty else { return nil }
        let end = chunk.firstIndex(of: 0x0A) ?? chunk.endIndex
        guard end > chunk.startIndex else { return nil }
        let line = chunk.subdata(in: chunk.startIndex..<end)
        return try? JSONDecoder().decode(TimestampEnvelope.self, from: line).timestamp
    }

    private func forEachLine(in url: URL, _ body: (Data) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var buffer = Data()

        while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            buffer.append(chunk)
            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                if newline > lineStart {
                    try body(buffer.subdata(in: lineStart..<newline))
                }
                lineStart = buffer.index(after: newline)
            }
            if lineStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
        }

        if !buffer.isEmpty { try body(buffer) }
    }

    private func persistPruneDate(_ date: Date) throws {
        try Data(String(date.timeIntervalSince1970).utf8).write(to: pruneStampURL, options: .atomic)
    }

    private static func loadPruneDate(from url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let interval = TimeInterval(text) else { return nil }
        return Date(timeIntervalSince1970: interval)
    }
}

private struct TimestampEnvelope: Decodable {
    let timestamp: Date
}

private struct ActiveIncidentMetadata: Codable {
    let id: UUID
    let name: String
    let startedAt: Date
    let trigger: ThermalIncidentTrigger
}
