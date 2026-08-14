import Foundation
// Under SwiftPM/Xcode the core is a separate module; the flat `swiftc` test
// build compiles core + tests as one module, where this import doesn't resolve
// (and `canImport` is false, so the guard removes it).
#if canImport(MacThermalCore)
import MacThermalCore
#endif

// Lightweight, dependency-free test runner for macthermal's pure logic — no SMC
// hardware or live IOKit connection is required. Build and run with `make test`;
// it prints a summary and exits non-zero if any check fails (CI-friendly).

@main
@MainActor
struct Tests {
    static var checks = 0
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            failures += 1
            FileHandle.standardError.write("  ✗ \(message)\n".data(using: .utf8)!)
        }
    }

    static func eq(_ got: Double?, _ want: Double, _ message: String, eps: Double = 1e-6) {
        expect(got != nil && abs(got! - want) < eps,
               "\(message) — got \(got.map { String($0) } ?? "nil"), want \(want)")
    }

    /// Builds a 32-byte `SMCBytes` tuple from a prefix of bytes (rest zero-filled).
    static func bytes(_ a: [UInt8]) -> SMCBytes {
        var b = a
        while b.count < 32 { b.append(0) }
        return (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15],
                b[16], b[17], b[18], b[19], b[20], b[21], b[22], b[23],
                b[24], b[25], b[26], b[27], b[28], b[29], b[30], b[31])
    }

    static func value(_ type: String, _ b: [UInt8]) -> SMCValue {
        SMCValue(key: "TEST", type: type, size: UInt32(b.count), bytes: bytes(b))
    }

    static func sample(
        seconds: TimeInterval,
        hotspot: Double,
        fan: Double? = 20,
        severity: Severity = .ok,
        processCPU: Double = 0,
        processSnapshotID: UUID? = nil
    ) -> ThermalSample {
        let processes = processCPU > 0
            ? [ProcessUsage(pid: 42, name: "RenderApp", cpuPercent: processCPU)]
            : []
        let stateName: String
        switch severity {
        case .warn: stateName = "serious"
        case .critical: stateName = "critical"
        default: stateName = "nominal"
        }
        return ThermalSample(
            timestamp: Date(timeIntervalSince1970: seconds),
            hottestCelsius: hotspot,
            averageCelsius: hotspot - 10,
            categoryPeaks: ["CPU": hotspot],
            categoryAverages: ["CPU": hotspot - 10],
            fanRPM: fan.map { _ in [2_000] } ?? [],
            fanUtilization: fan.map { [$0] } ?? [],
            thermalStateName: stateName,
            thermalSeverity: severity,
            topProcesses: processes,
            processSnapshotID: processSnapshotID,
            processSampledAt: processSnapshotID.map { _ in Date(timeIntervalSince1970: seconds) }
        )
    }

    /// A sample anchored to a real `Date`, for the persistence tests — the
    /// epoch-based `sample(seconds:)` above predates every retention window.
    static func sample(at date: Date, hotspot: Double) -> ThermalSample {
        ThermalSample(
            timestamp: date,
            hottestCelsius: hotspot,
            averageCelsius: hotspot - 10,
            categoryPeaks: ["CPU": hotspot],
            categoryAverages: ["CPU": hotspot - 10],
            fanRPM: [2_000],
            fanUtilization: [20],
            thermalStateName: "nominal",
            thermalSeverity: .ok,
            topProcesses: []
        )
    }

    /// A fresh scratch directory, so each persistence test starts from a known
    /// empty state (`HistoryStore` keys everything off one folder).
    static func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "macthermal-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func main() async {
        // --- SMC value decoding (the fixed-point / float encodings) ---
        eq(value("sp78", [0x3D, 0x00]).double, 61.0, "sp78 0x3D00 = 61.0")
        eq(value("sp78", [0x1E, 0x80]).double, 30.5, "sp78 0x1E80 = 30.5")
        eq(value("flt ", [0x00, 0x00, 0x48, 0x42]).double, 50.0, "flt little-endian = 50.0")
        eq(value("fpe2", [0x00, 0xF0]).double, 60.0, "fpe2 0x00F0 = 60.0 (/4)")
        eq(value("fp88", [0x3D, 0x00]).double, 61.0, "fp88 0x3D00 = 61.0 (/256)")
        eq(value("ui8 ", [0x2A]).double, 42.0, "ui8 = 42")
        eq(value("ui16", [0x01, 0x00]).double, 256.0, "ui16 big-endian = 256")
        eq(value("si8 ", [0xFF]).double, -1.0, "si8 0xFF = -1")
        expect(value("zzzz", [0x00]).double == nil, "unknown type decodes to nil")

        // --- size guards: a too-short value decodes to nil, not garbage ---
        expect(value("flt ", [0x00, 0x00, 0x48]).double == nil, "flt with 3 bytes = nil")
        expect(value("ui16", [0x01]).double == nil, "ui16 with 1 byte = nil")
        expect(value("ui32", [0x01, 0x02, 0x03]).double == nil, "ui32 with 3 bytes = nil")
        expect(value("sp78", [0x3D]).double == nil, "sp78 with 1 byte = nil")

        // --- count clamping (SEC-1): untrusted SMC counts can't crash/blow up ---
        expect(clampedCount(.nan, upperBound: 8192) == 0, "clampedCount(NaN) = 0")
        expect(clampedCount(.infinity, upperBound: 8192) == 0, "clampedCount(∞) = 0")
        expect(clampedCount(-5, upperBound: 8192) == 0, "clampedCount(negative) = 0")
        expect(clampedCount(3, upperBound: 8192) == 3, "clampedCount(3) = 3")
        expect(clampedCount(1e12, upperBound: 8192) == 8192, "clampedCount(huge) = upperBound")
        expect(clampedCount(1e300, upperBound: 8192) == 8192, "clampedCount(> Int.max) = upperBound (no trap)")

        // --- temperature thresholds ---
        expect(tempLevel(59.9).label == "cool" && tempLevel(59.9).severity == .ok, "tempLevel < 60 = cool")
        expect(tempLevel(60).severity == .normal, "tempLevel 60 = normal")
        expect(tempLevel(89).severity == .warn, "tempLevel 89 = warm")
        expect(tempLevel(99).severity == .hot, "tempLevel 99 = hot")
        expect(tempLevel(100).severity == .critical, "tempLevel 100 = critical")

        let fairThermalState = ThermalState(processInfoState: .fair)
        expect(fairThermalState.note == "macOS reports mildly elevated thermal pressure",
               "fair thermal pressure uses hardware-neutral wording")
        expect(!fairThermalState.note.localizedCaseInsensitiveContains("fan"),
               "thermal pressure does not claim that fans are present")

        // --- fan thresholds ---
        expect(fanLevel(4).label == "idle", "fanLevel < 5 = idle")
        expect(fanLevel(49).label == "low", "fanLevel 49 = low")
        expect(fanLevel(50).label == "elevated", "fanLevel 50 = elevated")
        expect(fanLevel(90).label == "maxing", "fanLevel 90 = maxing")

        // --- Pro history summaries and before/after comparison ---
        let baselineSamples = [
            sample(seconds: 0, hotspot: 60, fan: 10),
            sample(seconds: 10, hotspot: 70, fan: 20),
        ]
        let currentSamples = [
            sample(seconds: 20, hotspot: 75, fan: 30),
            sample(seconds: 30, hotspot: 85, fan: 40, severity: .warn),
        ]
        let baselineSummary = ThermalSummary(samples: baselineSamples)
        eq(baselineSummary.averageHotspotCelsius, 65, "history average hotspot = 65°C")
        eq(baselineSummary.averageFanUtilization, 15, "history average fan utilization = 15%")
        let comparison = ThermalComparison(baselineSamples: baselineSamples, currentSamples: currentSamples)
        eq(comparison.hotspotDeltaCelsius, 15, "comparison hotspot delta = +15°C")
        expect(comparison.current.pressureSampleCount == 1, "comparison counts serious pressure samples")

        let fanlessSummary = ThermalSummary(samples: [
            sample(seconds: 0, hotspot: 65, fan: nil),
            sample(seconds: 30, hotspot: 66, fan: nil),
        ])
        expect(!fanlessSummary.hasFanData && fanlessSummary.fanSampleCount == 0,
               "summary distinguishes missing fan sensors from zero fan load")
        let partialFanSummary = ThermalSummary(samples: [
            sample(seconds: 0, hotspot: 65, fan: nil),
            sample(seconds: 30, hotspot: 66, fan: 30),
        ])
        eq(partialFanSummary.averageFanUtilization, 30,
           "fan average excludes samples that contain no fan sensors")

        let mixedComparison = ThermalComparison(
            baselineSamples: [
                sample(seconds: 0, hotspot: 34.3),
                sample(seconds: 30, hotspot: 106.3),
            ],
            currentSamples: [
                sample(seconds: 60, hotspot: 65.2),
                sample(seconds: 90, hotspot: 79.6),
            ]
        )
        let mixedAssessment = ThermalComparisonAssessment(comparison: mixedComparison)
        expect(mixedAssessment.averageHotspotTrend == .regressed,
               "comparison marks a meaningful average hotspot increase as a regression")
        expect(mixedAssessment.peakHotspotTrend == .improved,
               "comparison marks a meaningful peak reduction as an improvement")
        expect(mixedAssessment.pressureTrend == .unchanged,
               "comparison treats zero pressure delta as unchanged")
        expect(mixedAssessment.result == .mixed,
               "opposing average and peak trends produce a mixed result")

        let unchangedAssessment = ThermalComparisonAssessment(comparison: ThermalComparison(
            baselineSamples: [sample(seconds: 0, hotspot: 70, fan: 20)],
            currentSamples: [sample(seconds: 30, hotspot: 70.5, fan: 22)],
        ))
        expect(unchangedAssessment.averageHotspotTrend == .unchanged,
               "temperature noise inside the tolerance remains unchanged")
        expect(unchangedAssessment.fanTrend == .unchanged,
               "fan changes inside the tolerance remain unchanged")
        expect(unchangedAssessment.result == .unchanged,
               "an assessment ignores changes inside metric tolerances")

        // --- chart density reduction preserves chronology and thermal peaks ---
        let denseSamples = (0..<2_500).map { index in
            sample(
                seconds: TimeInterval(index),
                hotspot: index == 1_234 ? 112 : 60 + Double(index % 8)
            )
        }
        let reducedSamples = ThermalSampleDownsampler.samples(from: denseSamples, maximumCount: 100)
        expect(reducedSamples.count <= 100, "chart downsampling honors its maximum count")
        expect(reducedSamples.first?.id == denseSamples.first?.id, "chart downsampling preserves the first sample")
        expect(reducedSamples.last?.id == denseSamples.last?.id, "chart downsampling preserves the last sample")
        expect(reducedSamples.contains { $0.hottestCelsius == 112 }, "chart downsampling preserves a hotspot spike")
        expect(zip(reducedSamples, reducedSamples.dropFirst()).allSatisfy { pair in
            pair.0.timestamp < pair.1.timestamp
        },
               "chart downsampling preserves chronological order")
        let threeSamples = ThermalSampleDownsampler.samples(from: denseSamples, maximumCount: 3)
        expect(threeSamples.count == 3 && threeSamples[1].hottestCelsius == 112,
               "three-point downsampling keeps the hottest interior sample")

        // --- process/heat correlation ---
        let correlationSamples = [
            sample(seconds: 0, hotspot: 50, processCPU: 10),
            sample(seconds: 10, hotspot: 60, processCPU: 20),
            sample(seconds: 20, hotspot: 70, processCPU: 30),
            sample(seconds: 30, hotspot: 80, processCPU: 40),
        ]
        let correlations = ThermalAnalytics.processCorrelations(samples: correlationSamples)
        expect(correlations.first?.processName == "RenderApp", "correlation identifies sampled process")
        eq(correlations.first?.coefficient, 1, "perfect process/temperature correlation = 1")

        let sparseCorrelationSamples = [
            sample(seconds: 0, hotspot: 50, processCPU: 10),
            sample(seconds: 10, hotspot: 60),
            sample(seconds: 20, hotspot: 70, processCPU: 30),
            sample(seconds: 30, hotspot: 80, processCPU: 40),
        ]
        let sparseCorrelations = ThermalAnalytics.processCorrelations(samples: sparseCorrelationSamples)
        expect(sparseCorrelations.first?.samplesObserved == 3, "correlation counts only samples where a process appears")
        eq(sparseCorrelations.first?.averageCPUPercent, 20, "correlation treats an absent process as 0% CPU")

        let processCaptureIDs = [UUID(), UUID(), UUID()]
        var repeatedProcessSamples: [ThermalSample] = []
        for (capture, id) in processCaptureIDs.enumerated() {
            for duplicate in 0..<3 {
                repeatedProcessSamples.append(sample(
                    seconds: TimeInterval(capture * 15 + duplicate * 2),
                    hotspot: 50 + Double(capture * 10 + duplicate),
                    processCPU: 10 + Double(capture * 10),
                    processSnapshotID: id
                ))
            }
        }
        let deduplicatedCorrelations = ThermalAnalytics.processCorrelations(samples: repeatedProcessSamples)
        expect(deduplicatedCorrelations.first?.samplesObserved == 3,
               "correlation counts one observation per real process capture")

        // --- comparison coverage rejects sparse or incomplete periods ---
        let completeCoverageSamples = stride(from: 0, through: 3_600, by: 30).map {
            sample(seconds: TimeInterval($0), hotspot: 65)
        }
        let completeCoverage = ThermalPeriodCoverage(
            samples: completeCoverageSamples,
            expectedStart: Date(timeIntervalSince1970: 0),
            expectedEnd: Date(timeIntervalSince1970: 3_600),
            expectedInterval: 30
        )
        eq(completeCoverage.fraction, 1, "continuous samples provide complete comparison coverage")
        let sparseCoverage = ThermalPeriodCoverage(
            samples: [completeCoverageSamples[0], completeCoverageSamples[completeCoverageSamples.count - 1]],
            expectedStart: Date(timeIntervalSince1970: 0),
            expectedEnd: Date(timeIntervalSince1970: 3_600),
            expectedInterval: 30
        )
        expect(sparseCoverage.fraction < 0.1, "a large gap does not masquerade as complete coverage")
        eq(comparison.current.pressureFraction, 0.5, "comparison normalizes pressure by sample count")

        // --- persisted samples and diagnostic report rendering ---
        if let encoded = try? JSONEncoder().encode(correlationSamples[0]),
           let decoded = try? JSONDecoder().decode(ThermalSample.self, from: encoded) {
            expect(decoded == correlationSamples[0], "thermal sample survives Codable round-trip")
            eq(decoded.categoryAverages?["CPU"], 40, "thermal sample persists category averages")
        } else {
            expect(false, "thermal sample encodes and decodes")
        }
        if let encoded = try? JSONEncoder().encode(correlationSamples[0]),
           var legacyObject = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
            legacyObject.removeValue(forKey: "categoryAverages")
            if let legacyData = try? JSONSerialization.data(withJSONObject: legacyObject),
               let legacySample = try? JSONDecoder().decode(ThermalSample.self, from: legacyData) {
                expect(legacySample.categoryAverages == nil,
                       "samples recorded before category averages remain decodable")
                eq(legacySample.categoryPeaks["CPU"], 50,
                   "legacy sample keeps its component peak")
            } else {
                expect(false, "legacy thermal sample decodes without category averages")
            }
        } else {
            expect(false, "legacy thermal sample fixture can be created")
        }
        let csvReport = DiagnosticReportRenderer.csv(samples: correlationSamples)
        expect(csvReport.hasPrefix("timestamp,hotspot_c"), "CSV report has stable header")
        expect(csvReport.contains("cpu_peak_c,gpu_peak_c"), "CSV report exposes component peaks")
        expect(csvReport.contains("top_process_cpu_percent"), "CSV report includes top-process CPU")
        expect(csvReport.contains("RenderApp"), "CSV report includes top process")
        let htmlReport = DiagnosticReportRenderer.html(title: "Heat <test>", samples: correlationSamples)
        expect(htmlReport.contains("Heat &lt;test&gt;"), "HTML report escapes its title")
        expect(htmlReport.contains("Likely contributors"), "HTML report includes contributor section")
        let context = DiagnosticContext(
            hardwareModel: "Mac <Test>",
            operatingSystem: "macOS Test",
            architecture: "arm64",
            processorCount: 8,
            physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
            appVersion: "0.5.0"
        )
        let contextualReport = DiagnosticReportRenderer.html(
            title: "Diagnostic",
            samples: correlationSamples,
            context: context
        )
        expect(contextualReport.contains("System context"), "HTML report includes system context")
        expect(contextualReport.contains("Mac &lt;Test&gt;"), "HTML report escapes hardware model")

        // --- throttling assessment uses OS pressure before temperature inference ---
        let nominalState = ThermalState(name: "nominal", note: "", severity: .ok)
        let seriousState = ThermalState(name: "serious", note: "", severity: .warn)
        expect(ThrottleAssessment(hottestCelsius: 70, thermalState: nominalState).level == .normal,
               "nominal pressure and 70°C = no throttling")
        expect(ThrottleAssessment(hottestCelsius: 95, thermalState: nominalState).level == .elevated,
               "nominal pressure and 95°C = throttling risk")
        expect(ThrottleAssessment(hottestCelsius: 70, thermalState: seriousState).level == .active,
               "serious OS pressure = active throttling")

        // --- sustained alert timing, pressure edge, and cooldown ---
        let alertConfiguration = AlertConfiguration(
            enabled: true,
            thresholdCelsius: 90,
            sustainedDuration: 60,
            cooldown: 300,
            notifyOnThermalPressure: true
        )
        var evaluator = ThermalAlertEvaluator()
        expect(evaluator.evaluate(
            sample: sample(seconds: 0, hotspot: 92),
            configuration: alertConfiguration,
            now: Date(timeIntervalSince1970: 0)
        ) == nil, "hot alert waits for sustained duration")
        expect(evaluator.evaluate(
            sample: sample(seconds: 60, hotspot: 93),
            configuration: alertConfiguration,
            now: Date(timeIntervalSince1970: 60)
        ) == .sustainedTemperature(celsius: 93), "hot alert fires after sustained duration")
        expect(evaluator.evaluate(
            sample: sample(seconds: 70, hotspot: 94),
            configuration: alertConfiguration,
            now: Date(timeIntervalSince1970: 70)
        ) == nil, "alert cooldown suppresses repeats")

        var pressureEvaluator = ThermalAlertEvaluator()
        expect(pressureEvaluator.evaluate(
            sample: sample(seconds: 0, hotspot: 70, severity: .warn),
            configuration: alertConfiguration,
            now: Date(timeIntervalSince1970: 0)
        ) == .thermalPressure(state: "serious"), "pressure alert fires on serious transition")

        // --- automatic pressure incidents and delayed recovery ---
        var incidentDetector = AutomaticIncidentDetector()
        expect(incidentDetector.evaluate(
            sample: sample(seconds: 0, hotspot: 82, severity: .warn),
            pressureEnabled: true,
            temperatureEnabled: false,
            thresholdCelsius: 90,
            sustainedDuration: 60,
            recoveryDuration: 60,
            now: Date(timeIntervalSince1970: 0)
        ) == .start(trigger: .automaticThermalPressure, state: "serious", severity: .warn),
               "serious pressure starts an automatic incident")
        expect(incidentDetector.evaluate(
            sample: sample(seconds: 10, hotspot: 70),
            pressureEnabled: true,
            temperatureEnabled: false,
            thresholdCelsius: 90,
            sustainedDuration: 60,
            recoveryDuration: 60,
            now: Date(timeIntervalSince1970: 10)
        ) == nil, "automatic incident waits through recovery grace period")
        expect(incidentDetector.evaluate(
            sample: sample(seconds: 70, hotspot: 68),
            pressureEnabled: true,
            temperatureEnabled: false,
            thresholdCelsius: 90,
            sustainedDuration: 60,
            recoveryDuration: 60,
            now: Date(timeIntervalSince1970: 70)
        ) == .stop, "automatic incident stops after sustained recovery")

        var disabledDetector = AutomaticIncidentDetector()
        _ = disabledDetector.evaluate(
            sample: sample(seconds: 0, hotspot: 82, severity: .critical),
            pressureEnabled: true,
            temperatureEnabled: false,
            thresholdCelsius: 90,
            sustainedDuration: 60,
            recoveryDuration: 60,
            now: Date(timeIntervalSince1970: 0)
        )
        expect(disabledDetector.evaluate(
            sample: sample(seconds: 1, hotspot: 82, severity: .critical),
            pressureEnabled: false,
            temperatureEnabled: false,
            thresholdCelsius: 90,
            sustainedDuration: 60,
            recoveryDuration: 60,
            now: Date(timeIntervalSince1970: 1)
        ) == .stop, "disabling automatic capture stops its active incident")

        var masterDisabledDetector = AutomaticIncidentDetector()
        expect(masterDisabledDetector.evaluate(
            sample: sample(seconds: 0, hotspot: 82, severity: .critical),
            automaticCaptureEnabled: false,
            pressureEnabled: true,
            temperatureEnabled: true,
            thresholdCelsius: 90,
            sustainedDuration: 60,
            recoveryDuration: 60,
            now: Date(timeIntervalSince1970: 0)
        ) == nil, "the master switch prevents automatic incident recording")
        _ = masterDisabledDetector.evaluate(
            sample: sample(seconds: 1, hotspot: 82, severity: .critical),
            automaticCaptureEnabled: true,
            pressureEnabled: true,
            temperatureEnabled: false,
            thresholdCelsius: 90,
            sustainedDuration: 60,
            recoveryDuration: 60,
            now: Date(timeIntervalSince1970: 1)
        )
        expect(masterDisabledDetector.evaluate(
            sample: sample(seconds: 2, hotspot: 82, severity: .critical),
            automaticCaptureEnabled: false,
            pressureEnabled: true,
            temperatureEnabled: false,
            thresholdCelsius: 90,
            sustainedDuration: 60,
            recoveryDuration: 60,
            now: Date(timeIntervalSince1970: 2)
        ) == .stop, "turning off the master switch stops an active automatic incident")

        var hotIncidentDetector = AutomaticIncidentDetector()
        expect(hotIncidentDetector.evaluate(
            sample: sample(seconds: 0, hotspot: 92),
            pressureEnabled: false,
            temperatureEnabled: true,
            thresholdCelsius: 90,
            sustainedDuration: 60,
            recoveryDuration: 60,
            now: Date(timeIntervalSince1970: 0)
        ) == nil, "high-temperature incident waits for sustained duration")
        expect(hotIncidentDetector.evaluate(
            sample: sample(seconds: 60, hotspot: 93),
            pressureEnabled: false,
            temperatureEnabled: true,
            thresholdCelsius: 90,
            sustainedDuration: 60,
            recoveryDuration: 60,
            now: Date(timeIntervalSince1970: 60)
        ) == .start(trigger: .automaticHighTemperature, state: "nominal", severity: .ok),
               "sustained high temperature starts an automatic incident even with nominal pressure")
        expect(hotIncidentDetector.evaluate(
            sample: sample(seconds: 70, hotspot: 88),
            pressureEnabled: false,
            temperatureEnabled: true,
            thresholdCelsius: 90,
            sustainedDuration: 60,
            recoveryDuration: 60,
            now: Date(timeIntervalSince1970: 70)
        ) == nil, "temperature recovery margin prevents early incident stop")
        expect(hotIncidentDetector.evaluate(
            sample: sample(seconds: 80, hotspot: 86),
            pressureEnabled: false,
            temperatureEnabled: true,
            thresholdCelsius: 90,
            sustainedDuration: 60,
            recoveryDuration: 60,
            now: Date(timeIntervalSince1970: 80)
        ) == nil, "temperature incident begins recovery below the hysteresis margin")
        expect(hotIncidentDetector.evaluate(
            sample: sample(seconds: 140, hotspot: 85),
            pressureEnabled: false,
            temperatureEnabled: true,
            thresholdCelsius: 90,
            sustainedDuration: 60,
            recoveryDuration: 60,
            now: Date(timeIntervalSince1970: 140)
        ) == .stop, "temperature incident stops after sustained recovery")

        // --- derived event timeline with threshold hysteresis ---
        let eventSamples = [
            sample(seconds: 0, hotspot: 80),
            sample(seconds: 10, hotspot: 91),
            sample(seconds: 20, hotspot: 89),
            sample(seconds: 30, hotspot: 86),
            sample(seconds: 40, hotspot: 82, severity: .warn),
            sample(seconds: 50, hotspot: 84, severity: .critical),
            sample(seconds: 60, hotspot: 72),
        ]
        let events = ThermalEventAnalyzer.events(samples: eventSamples, thresholdCelsius: 90)
        expect(events.map(\.kind) == [
            .pressureRecovered,
            .pressureEscalated,
            .pressureBegan,
            .temperatureRecovered,
            .temperatureExceeded,
        ], "timeline records threshold, pressure escalation, and recovery in newest-first order")

        let preRoll = ThermalIncidentPreRoll.samples(
            from: eventSamples,
            endingAt: Date(timeIntervalSince1970: 50),
            duration: 25
        )
        expect(preRoll.map { $0.timestamp.timeIntervalSince1970 } == [30, 40, 50],
               "automatic incident pre-roll includes only the configured lead-up window")

        // --- incident provenance, renaming, and backward-compatible decoding ---
        let incident = ThermalIncident(
            name: "Before",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 60),
            samples: eventSamples,
            trigger: .automaticThermalPressure
        )
        let renamedIncident = incident.renamed(to: "Export workload")
        expect(renamedIncident.id == incident.id && renamedIncident.name == "Export workload",
               "renaming preserves incident identity and samples")
        if let encodedIncident = try? JSONEncoder().encode(incident),
           var object = try? JSONSerialization.jsonObject(with: encodedIncident) as? [String: Any] {
            object.removeValue(forKey: "trigger")
            if let legacyData = try? JSONSerialization.data(withJSONObject: object),
               let legacyIncident = try? JSONDecoder().decode(ThermalIncident.self, from: legacyData) {
                expect(legacyIncident.effectiveTrigger == .manual, "legacy incidents without provenance decode as manual")
            } else {
                expect(false, "legacy incident JSON decodes")
            }
        } else {
            expect(false, "incident JSON encodes for compatibility test")
        }

        // --- fan utilization math ---
        eq(FanReading(index: 0, rpm: 2400, min: 1200, max: 6000, target: 0).utilization,
           25.0, "utilization (2400 in 1200..6000) = 25%")
        eq(FanReading(index: 0, rpm: 3000, min: 2000, max: 2000, target: 0).utilization,
           0.0, "utilization with max == min = 0")
        eq(FanReading(index: 0, rpm: 9999, min: 1200, max: 6000, target: 0).utilization,
           100.0, "utilization clamps to 100%")

        // --- categorization (intentionally case-sensitive: SMC naming is) ---
        expect(categorize("Tp00") == .cpu, "Tp00 (P-core) = CPU")
        expect(categorize("TG0P") == .gpu, "TG0P = GPU")
        expect(categorize("TB0T") == .battery, "TB0T = battery")
        expect(categorize("Tm0P") == .memory, "Tm0P = memory")
        expect(categorize("TVD0") == .other, "TVD0 (undocumented SoC rail) = other")

        // --- FourCharCode helpers (round-trip + short-key space padding) ---
        expect(fourCharString(fourCharCode("TC0P")) == "TC0P", "fourChar round-trips a full 4-char key")
        expect(fourCharCode("TC0P") == 0x54_43_30_50, "fourCharCode packs big-endian ASCII")
        expect(fourCharString(fourCharCode("FNum")) == "FNum", "fourChar round-trips FNum")
        expect(fourCharString(fourCharCode("F0")) == "F0  ", "fourCharCode space-pads a short key to 4 bytes")

        // --- JSON encoding (round-trips into the expected shape) ---
        let temps = [TempReading(key: "TC0P", label: "CPU proximity", category: .cpu, celsius: 65.789)]
        let fans = [FanReading(index: 0, rpm: 2317.4, min: 1200, max: 5779, target: 2300)]
        let json = renderJSON(temps: temps, fans: fans)
        if let data = json.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let summary = root["summary"] as? [String: Any],
           let temperatures = root["temperatures"] as? [[String: Any]] {
            expect((summary["sensorCount"] as? Int) == 1, "JSON summary.sensorCount = 1")
            expect((summary["fanCount"] as? Int) == 1, "JSON summary.fanCount = 1")
            eq(summary["hottestC"] as? Double, 65.79, "JSON hottestC rounded to 2dp")
            expect((temperatures.first?["key"] as? String) == "TC0P", "JSON temperature key = TC0P")
        } else {
            expect(false, "JSON parses into the expected shape")
        }

        // --- heat contributors: rank by CPU while hot, not by correlation ---
        // A process pegged at steady high CPU (the usual culprit for sustained
        // heat) must outrank a low-CPU process whose usage merely tracks
        // temperature — the opposite of what raw Pearson correlation would do.
        let heatSamples: [ThermalSample] = (0..<20).map { i in
            let temp = 60.0 + Double(i)               // hotspot rises 60 -> 79
            let tracker = max(0, temp - 55)           // co-moves with temperature
            return ThermalSample(
                timestamp: Date(timeIntervalSince1970: Double(i) * 15),
                hottestCelsius: temp,
                averageCelsius: temp - 10,
                categoryPeaks: ["CPU": temp],
                fanRPM: [2_000],
                fanUtilization: [30],
                thermalStateName: "nominal",
                thermalSeverity: .ok,
                topProcesses: [
                    ProcessUsage(pid: 1, name: "StuckHelper", cpuPercent: 70),       // steady, high
                    ProcessUsage(pid: 2, name: "WindowServer", cpuPercent: tracker), // co-moves, lower
                ],
                processSnapshotID: UUID(),
                processSampledAt: Date(timeIntervalSince1970: Double(i) * 15)
            )
        }
        let contributors = ThermalAnalytics.heatContributors(samples: heatSamples)
        expect(contributors.first?.processName == "StuckHelper",
               "heat contributors rank the steadily-pegged process first, not the co-mover")
        expect(contributors.first?.pattern == .steadyLoad,
               "a flat high-CPU process is labeled steady load")
        if let windowServer = contributors.first(where: { $0.processName == "WindowServer" }) {
            expect(windowServer.pattern == .tracksTemperature,
                   "a process whose CPU tracks temperature is labeled accordingly")
        } else {
            expect(false, "WindowServer should still appear as a contributor")
        }
        expect(ThermalAnalytics.heatContributors(samples: Array(heatSamples.prefix(2))).isEmpty,
               "heat contributors need at least three observations")

        // Regression: a lone temperature spike must not collapse the hot set to a
        // single sample and leave the list empty (the peak-minus-fixed-margin bug
        // that made "Likely Contributors" empty for short/spiky windows).
        let spikySamples: [ThermalSample] = (0..<30).map { i in
            let temp = i == 5 ? 100.0 : 58.0 + Double(i % 6)   // one 100°C blip, rest ~58–63°C
            return ThermalSample(
                timestamp: Date(timeIntervalSince1970: Double(i) * 15),
                hottestCelsius: temp,
                averageCelsius: temp - 10,
                categoryPeaks: ["CPU": temp],
                fanRPM: [2_000],
                fanUtilization: [30],
                thermalStateName: "nominal",
                thermalSeverity: .ok,
                topProcesses: [ProcessUsage(pid: 7, name: "BusyApp", cpuPercent: 40)],
                processSnapshotID: UUID(),
                processSampledAt: Date(timeIntervalSince1970: Double(i) * 15)
            )
        }
        let spikyContributors = ThermalAnalytics.heatContributors(samples: spikySamples)
        expect(spikyContributors.first?.processName == "BusyApp",
               "a lone temperature spike doesn't collapse the hot set to empty")
        // --- alert evaluator: a suppressed thermal-pressure edge is not lost ---
        func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
        var pressureEval = ThermalAlertEvaluator()
        let cooldownCfg = AlertConfiguration(
            enabled: true, thresholdCelsius: 90, sustainedDuration: 10,
            cooldown: 300, notifyOnThermalPressure: true
        )
        _ = pressureEval.evaluate(sample: sample(seconds: 0, hotspot: 95), configuration: cooldownCfg, now: at(0))
        let sustainedFire = pressureEval.evaluate(sample: sample(seconds: 10, hotspot: 95), configuration: cooldownCfg, now: at(10))
        expect(sustainedFire == .sustainedTemperature(celsius: 95),
               "sustained-temperature alert fires after the sustained duration")
        let suppressedEdge = pressureEval.evaluate(sample: sample(seconds: 15, hotspot: 50, severity: .warn), configuration: cooldownCfg, now: at(15))
        expect(suppressedEdge == nil, "a pressure edge inside the cooldown is suppressed")
        let firesAfterCooldown = pressureEval.evaluate(sample: sample(seconds: 320, hotspot: 50, severity: .warn), configuration: cooldownCfg, now: at(320))
        expect(firesAfterCooldown == .thermalPressure(state: "serious"),
               "a suppressed pressure edge still fires once the cooldown clears (not lost forever)")

        // --- alert evaluator: a sub-threshold dip restarts the sustained timer,
        //     even when a pressure alert fired on the same sample ---
        var sustainedEval = ThermalAlertEvaluator()
        let noCooldownCfg = AlertConfiguration(
            enabled: true, thresholdCelsius: 90, sustainedDuration: 10,
            cooldown: 0, notifyOnThermalPressure: true
        )
        _ = sustainedEval.evaluate(sample: sample(seconds: 0, hotspot: 95), configuration: noCooldownCfg, now: at(0))
        _ = sustainedEval.evaluate(sample: sample(seconds: 2, hotspot: 85, severity: .warn), configuration: noCooldownCfg, now: at(2))
        _ = sustainedEval.evaluate(sample: sample(seconds: 3, hotspot: 91), configuration: noCooldownCfg, now: at(3))
        let notYetSustained = sustainedEval.evaluate(sample: sample(seconds: 11, hotspot: 91), configuration: noCooldownCfg, now: at(11))
        expect(notYetSustained == nil,
               "a dip past the recovery margin restarts the sustained timer even when a pressure alert fired")

        // --- alert evaluator: hysteresis matches automatic capture and the
        //     timeline, so all three agree on when a hot period ended ---
        var hysteresisEval = ThermalAlertEvaluator()
        _ = hysteresisEval.evaluate(sample: sample(seconds: 0, hotspot: 95), configuration: noCooldownCfg, now: at(0))
        // 88 °C is under the 90 °C threshold but inside the 3 °C recovery margin:
        // ordinary SMC noise, not the end of the episode.
        _ = hysteresisEval.evaluate(sample: sample(seconds: 4, hotspot: 88), configuration: noCooldownCfg, now: at(4))
        let survivesNoise = hysteresisEval.evaluate(sample: sample(seconds: 10, hotspot: 94), configuration: noCooldownCfg, now: at(10))
        expect(survivesNoise == .sustainedTemperature(celsius: 94),
               "a dip inside the recovery margin does not restart the sustained timer")
        expect(thermalRecoveryMarginCelsius == 3,
               "the shared recovery margin keeps its documented value")

        // --- category temperatures: inline storage, unchanged on-disk shape ---
        var categories = CategoryTemperatures()
        expect(categories.isEmpty, "a new category set is empty")
        expect(categories[.cpu] == nil, "an absent category reads as nil, not zero")
        categories[.cpu] = 71.5
        categories["GPU"] = 60
        categories["NotACategory"] = 99
        eq(categories["CPU"], 71.5, "category values round-trip through the string subscript")
        expect(categories["NotACategory"] == nil, "an unknown category key is ignored")
        expect(categories.categories == [.cpu, .gpu], "present categories are reported in canonical order")
        categories[.cpu] = nil
        expect(categories[.cpu] == nil && categories[.gpu] == 60,
               "clearing one category leaves the others intact")

        let categoryJSON = try? JSONEncoder().encode(
            CategoryTemperatures(["CPU": 70.5, "Battery": 33])
        )
        let categoryText = categoryJSON.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expect(categoryText.contains("\"CPU\":70.5") && categoryText.contains("\"Battery\":33"),
               "categories encode as a plain rawValue-keyed map")
        expect(!categoryText.contains("Memory"), "absent categories are omitted rather than zeroed")
        // History written by earlier builds used a dictionary, so key order was
        // arbitrary and unknown keys were possible. Both must still decode.
        let legacyCategories = try? JSONDecoder().decode(
            CategoryTemperatures.self,
            from: Data(#"{"Other":41,"CPU":70.5,"Unknown":12}"#.utf8)
        )
        eq(legacyCategories?["CPU"], 70.5, "legacy category JSON decodes regardless of key order")
        eq(legacyCategories?["Other"], 41, "legacy category JSON keeps every known key")

        // --- CSV export: spreadsheet formula injection is defused ---
        let injectionSample = ThermalSample(
            timestamp: Date(timeIntervalSince1970: 0),
            hottestCelsius: 70, averageCelsius: 60,
            categoryPeaks: ["CPU": 70], categoryAverages: ["CPU": 60],
            fanRPM: [], fanUtilization: [],
            thermalStateName: "nominal", thermalSeverity: .ok,
            topProcesses: [ProcessUsage(pid: 1, name: "=HYPERLINK(\"http://evil\")", cpuPercent: 9)]
        )
        let injectionCSV = DiagnosticReportRenderer.csv(samples: [injectionSample])
        expect(injectionCSV.contains("\"'=HYPERLINK"),
               "a process name that looks like a formula is escaped and quoted")
        expect(!injectionCSV.contains(",=HYPERLINK"),
               "no CSV field starts a bare formula")
        let carriageReturnSample = ThermalSample(
            timestamp: Date(timeIntervalSince1970: 0),
            hottestCelsius: 70, averageCelsius: 60,
            categoryPeaks: ["CPU": 70], categoryAverages: ["CPU": 60],
            fanRPM: [], fanUtilization: [],
            thermalStateName: "nom\rinal", thermalSeverity: .ok,
            topProcesses: []
        )
        expect(DiagnosticReportRenderer.csv(samples: [carriageReturnSample]).contains("\"nom\rinal\""),
               "a carriage return is quoted so it cannot split the record")

        // --- sample windowing: the binary search matches an exhaustive filter ---
        let ordered = (0..<500).map { sample(seconds: Double($0) * 30, hotspot: 50) }
        let windowCutoff = Date(timeIntervalSince1970: 300 * 30)
        let fastWindow = ThermalSampleWindow.recent(ordered, since: windowCutoff)
        let slowWindow = ordered.filter { $0.timestamp >= windowCutoff }
        expect(fastWindow == slowWindow, "the binary-searched window matches the filtered one")
        expect(ThermalSampleWindow.recent(ordered, since: Date(timeIntervalSince1970: -1)).count == 500,
               "a cutoff before every sample keeps the whole series")
        expect(ThermalSampleWindow.recent(ordered, since: Date(timeIntervalSince1970: 1e9)).isEmpty,
               "a cutoff after every sample yields nothing")
        expect(ThermalSampleWindow.recent([], since: windowCutoff).isEmpty, "an empty series windows to empty")
        // A backwards clock jump breaks the ordering the search relies on, so the
        // caller reports it and the exhaustive path takes over.
        var jumbled = ordered
        jumbled.insert(sample(seconds: 499 * 30, hotspot: 50), at: 0)
        let jumbledWindow = ThermalSampleWindow.recent(jumbled, since: windowCutoff, chronological: false)
        expect(jumbledWindow.count == slowWindow.count + 1,
               "an out-of-order series falls back to the exhaustive filter")

        await runPersistenceTests()

        let tag = failures == 0 ? "ok" : "FAILED"
        let summary = "macthermal tests: \(checks - failures)/\(checks) passed — \(tag)\n"
        FileHandle.standardOutput.write(summary.data(using: .utf8)!)
        exit(failures == 0 ? 0 : 1)
    }

    /// `HistoryStore` against a scratch directory — no SMC, no Application
    /// Support. This is the part of the app most likely to lose user data: it
    /// appends NDJSON, tolerates a line a crash cut in half, compacts through a
    /// temporary file, and rebuilds an incident whose recording never ended.
    static func runPersistenceTests() async {
        let manager = FileManager.default

        // --- append then load round-trips, newest window first ---
        let roundTripDirectory = scratchDirectory()
        defer { try? manager.removeItem(at: roundTripDirectory) }
        let store = HistoryStore(directory: roundTripDirectory)
        let now = Date.now
        for offset in 0..<3 {
            try? await store.append(
                sample(at: now.addingTimeInterval(Double(offset - 3) * 60), hotspot: 70 + Double(offset)),
                retentionDays: 7
            )
        }
        var loaded = await store.load(
            retentionDays: 7, inMemoryDays: 7, incidentRetentionDays: 30, maximumStoredIncidents: 25
        )
        expect(loaded.samples.count == 3, "appended samples reload from NDJSON")
        eq(loaded.samples.last?.hottestCelsius, 72, "reloaded samples keep append order")
        eq(loaded.samples.first?.categoryPeaks["CPU"], 70, "reloaded samples keep their component peaks")

        // --- a last line truncated by a crash must not void earlier samples ---
        let historyURL = roundTripDirectory.appending(path: "history.ndjson")
        if let handle = try? FileHandle(forWritingTo: historyURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(#"{"timestamp":1,"hottest"#.utf8))
            try? handle.close()
        }
        loaded = await store.load(
            retentionDays: 7, inMemoryDays: 7, incidentRetentionDays: 30, maximumStoredIncidents: 25
        )
        expect(loaded.samples.count == 3, "a truncated final line is skipped, earlier samples survive")

        // --- compaction drops samples past retention, keeps the rest ---
        let pruneDirectory = scratchDirectory()
        defer { try? manager.removeItem(at: pruneDirectory) }
        let pruneStore = HistoryStore(directory: pruneDirectory)
        let stale = sample(at: now.addingTimeInterval(-10 * 86_400), hotspot: 60)
        let fresh = sample(at: now.addingTimeInterval(-60), hotspot: 80)
        // A store with no prune stamp compacts on its first append, which is what
        // puts both of these through the retention filter.
        try? await pruneStore.append(stale, retentionDays: 7)
        try? await pruneStore.append(fresh, retentionDays: 7)
        let afterPrune = await pruneStore.load(
            retentionDays: 7, inMemoryDays: 7, incidentRetentionDays: 30, maximumStoredIncidents: 25
        )
        expect(afterPrune.samples.count == 1, "compaction drops samples past the retention window")
        eq(afterPrune.samples.first?.hottestCelsius, 80, "compaction keeps the samples inside retention")
        let pruneStamp = pruneDirectory.appending(path: ".last-history-prune")
        expect(manager.fileExists(atPath: pruneStamp.path),
               "the prune run is stamped so the next append does not repeat it")

        // --- an interrupted recording is recovered on the next launch ---
        let recoveryDirectory = scratchDirectory()
        defer { try? manager.removeItem(at: recoveryDirectory) }
        let crashedStore = HistoryStore(directory: recoveryDirectory)
        let incidentID = UUID()
        try? await crashedStore.beginActiveIncident(
            id: incidentID,
            name: "Export run",
            startedAt: now.addingTimeInterval(-120),
            trigger: .manual,
            samples: [sample(at: now.addingTimeInterval(-120), hotspot: 85)]
        )
        try? await crashedStore.appendActiveIncident(sample(at: now.addingTimeInterval(-60), hotspot: 92))
        try? await crashedStore.flushActiveIncident()

        // A second store on the same directory stands in for the next launch.
        let relaunchedStore = HistoryStore(directory: recoveryDirectory)
        let recovered = await relaunchedStore.load(
            retentionDays: 7, inMemoryDays: 7, incidentRetentionDays: 30, maximumStoredIncidents: 25
        )
        expect(recovered.incidents.count == 1, "an unfinished recording is recovered")
        expect(recovered.incidents.first?.id == incidentID, "recovery keeps the incident's identity")
        expect(recovered.incidents.first?.samples.count == 2, "recovery keeps every journaled sample")
        expect(recovered.incidents.first?.name.hasSuffix("(recovered)") == true,
               "a recovered incident is labelled as such")
        expect(!manager.fileExists(atPath: recoveryDirectory.appending(path: "active-incident.json").path),
               "the journal is cleared once its incident has been folded in")
        let recoveredAgain = await relaunchedStore.load(
            retentionDays: 7, inMemoryDays: 7, incidentRetentionDays: 30, maximumStoredIncidents: 25
        )
        expect(recoveredAgain.incidents.count == 1, "recovery does not duplicate on a later launch")

        // --- a crash mid-compaction must not strand its temporary ---
        let orphanDirectory = scratchDirectory()
        defer { try? manager.removeItem(at: orphanDirectory) }
        let orphan = orphanDirectory.appending(path: "history-\(UUID().uuidString).tmp")
        try? Data("stranded".utf8).write(to: orphan)
        let sweepingStore = HistoryStore(directory: orphanDirectory)
        _ = await sweepingStore.load(
            retentionDays: 7, inMemoryDays: 7, incidentRetentionDays: 30, maximumStoredIncidents: 25
        )
        expect(!manager.fileExists(atPath: orphan.path), "a stranded compaction temporary is swept on load")

        // --- out-of-order incident writes cannot resurrect stale state ---
        let revisionDirectory = scratchDirectory()
        defer { try? manager.removeItem(at: revisionDirectory) }
        let revisionStore = HistoryStore(directory: revisionDirectory)
        let keptIncident = ThermalIncident(
            name: "Newer", startedAt: now.addingTimeInterval(-60), endedAt: now, samples: [], trigger: .manual
        )
        try? await revisionStore.saveIncidents([keptIncident], revision: 5)
        try? await revisionStore.saveIncidents([], revision: 4)
        let afterRevisions = await revisionStore.load(
            retentionDays: 7, inMemoryDays: 7, incidentRetentionDays: 30, maximumStoredIncidents: 25
        )
        expect(afterRevisions.incidents.count == 1,
               "a late write from an older revision does not overwrite a newer one")

        // --- a retention change re-reads the window without touching incidents ---
        let reloadDirectory = scratchDirectory()
        defer { try? manager.removeItem(at: reloadDirectory) }
        let reloadStore = HistoryStore(directory: reloadDirectory)
        try? await reloadStore.append(sample(at: now.addingTimeInterval(-3 * 86_400), hotspot: 65), retentionDays: 30)
        try? await reloadStore.append(sample(at: now.addingTimeInterval(-60), hotspot: 75), retentionDays: 30)
        let wideWindow = await reloadStore.reloadHistoryWindow(retentionDays: 30, inMemoryDays: 14)
        expect(wideWindow.count == 2, "a wider window re-reads the samples already on disk")
        let narrowWindow = await reloadStore.reloadHistoryWindow(retentionDays: 1, inMemoryDays: 1)
        expect(narrowWindow.count == 1, "a narrower window drops what retention no longer covers")
        eq(narrowWindow.first?.hottestCelsius, 75, "the narrowed window keeps the most recent samples")
    }
}
