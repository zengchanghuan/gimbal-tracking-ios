import Foundation
import Darwin

/// Local, image-free diagnostics. Model predictions are not ground truth:
/// precision/recall/identity accuracy intentionally remain unmeasured.
final class ObjectTrackingDiagnostics {
    let exportURL: URL?
    let runID: String
    private let queue = DispatchQueue(label: "ObjectTracking.Diagnostics", qos: .utility)
    private let pendingEntries = DispatchSemaphore(value: 512)
    private let droppedEntriesLock = NSLock()
    private var droppedEntries = 0
    private var handles: [String: FileHandle] = [:]
    private var manifest: [String: Any]
    private var counters: [String: Int] = [:]
    private var latencies: [Double] = []
    private var latencyObservationCount = 0
    private var memoryPeak: UInt64 = 0
    private var writeFailures = 0
    private var finished = false
    private var finishedSummary: [String: Any]?
    private var postStopEventCount = 0
    private var resourceTimer: DispatchSourceTimer?
    private let startedAt = ProcessInfo.processInfo.systemUptime

    init(backend: ObjectDetectionBackend, sessionID: UUID, trackerRevision: Int, rootDirectory: URL? = nil) {
        runID = "\(Int(Date().timeIntervalSince1970))-\(sessionID.uuidString)"
        manifest = [
            "schemaVersion": 1, "runID": runID, "sessionID": sessionID.uuidString,
            "backend": backend.rawValue, "modelIdentifier": "loading",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "buildVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "startedAtUTC": ISO8601DateFormatter().string(from: Date()),
            "clock": "ProcessInfo.systemUptime seconds; mediaPTS recorded separately",
            "captureTimeProvenance": "caller_supplied; see capture events",
            "geometry": "actual pixel buffer orientation; lower-left normalized boxes",
            "imagesStored": false, "accuracyMeasured": false,
            "positionValidityMeaning": "policy freshness/association only, not annotated ground-truth correctness",
            "detectionIntervalSeconds": ObjectTrackingPolicy.detectionInterval,
            "positionLifetimeSeconds": ObjectTrackingPolicy.positionLifetime,
            "semanticLifetimeSeconds": ObjectTrackingPolicy.semanticLifetime,
            "recoveryWindowSeconds": ObjectTrackingPolicy.recoveryWindow,
            "trackerRevision": trackerRevision, "trackerRevisionApplied": NSNull(),
            "trackerLevel": "accurate",
            "trackerLevelEffective": trackerRevision == 2 ? "ignored_by_VNTrackObjectRequestRevision2" : "accurate",
            "trackerRevisionMeaning": "Requested revision; trackerRevisionApplied is the actual request revision after seed construction, null before any supported seed",
            "trackerObservationDiagnostics": "Raw Vision observation before policy checks; confidence is not ground-truth correctness; failure reasons do not change tracking policy"
        ]
        manifest.merge(Self.hardwareEnvironment()) { _, latest in latest }
        let base = rootDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ObjectTrackingRuns", isDirectory: true)
        if let directory = base?.appendingPathComponent(runID, isDirectory: true) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                exportURL = directory
            } catch {
                exportURL = nil
            }
        } else {
            exportURL = nil
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.writeManifest()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0)
            timer.setEventHandler { [weak self] in self?.recordResources() }
            self.resourceTimer = timer
            timer.resume()
        }
    }

    deinit {
        resourceTimer?.cancel()
        for handle in handles.values { try? handle.close() }
    }

    func updateManifest(_ fields: [String: Any]) {
        queue.async { [self] in
            for (key, value) in fields { manifest[key] = value }
            writeManifest()
        }
    }

    func recordEvent(_ name: String, details: [String: String] = [:]) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        enqueue { [self] in
            counters["event.\(name)", default: 0] += 1
            append(["event": name, "hostTime": timestamp, "details": details], to: "events.jsonl")
            if finished {
                postStopEventCount += 1
                finishedSummary?["counts"] = counters
                finishedSummary?["postStopEventCount"] = postStopEventCount
                finishedSummary?["diagnosticDroppedEntries"] = droppedEntryCount()
                finishedSummary?["evidenceIncomplete"] = droppedEntryCount() > 0 || writeFailures > 0
                if let finishedSummary { writeJSON(finishedSummary, name: "summary.json") }
            }
        }
    }

    func recordDrop(_ reason: String, frameID: UInt64? = nil) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        enqueue { [self] in
            counters["drop.\(reason)", default: 0] += 1
            var row: [String: Any] = ["event": "frame_dropped", "hostTime": timestamp, "reason": reason]
            if let frameID { row["frameID"] = frameID }
            append(row, to: "events.jsonl")
        }
    }

    func recordFrame(_ fields: [String: Any]) {
        enqueue { [self] in
            if finished {
                // Stop is deliberately not blocked by inference. Preserve its
                // late diagnostic row, but do not call it an active-run sample.
                var late = fields
                late["completedAfterStop"] = true
                counters["postStopCompletedFrames", default: 0] += 1
                append(late, to: "frames.jsonl")
                finishedSummary?["counts"] = counters
                if let finishedSummary { writeJSON(finishedSummary, name: "summary.json") }
                return
            }
            counters["analyzedFrames", default: 0] += 1
            if fields["detectorRan"] as? Bool == true { counters["detectionFrames", default: 0] += 1 }
            if fields["trackerRan"] as? Bool == true { counters["trackerFrames", default: 0] += 1 }
            if fields["trackerObservationMissing"] as? Bool == true { counters["trackerObservationMissingFrames", default: 0] += 1 }
            if let reason = fields["trackerFailureReason"] as? String {
                counters["trackerFailure.\(reason)", default: 0] += 1
            }
            if fields["shouldMove"] as? Bool == true { counters["validPositionFrames", default: 0] += 1 }
            if let latency = fields["captureToAnalysisEndMs"] as? Double, latency.isFinite, latency >= 0 {
                latencyObservationCount += 1
                // Bounded even if a user leaves a diagnostic run open for days.
                if latencies.count < 100_000 { latencies.append(latency) }
            }
            append(fields, to: "frames.jsonl")
        }
    }

    func recordUIConsumption(frameID: UInt64, capturedAt: TimeInterval, hostTime: TimeInterval) {
        enqueue { [self] in
            counters["mainDeliveredSnapshots", default: 0] += 1
            append(["event": "snapshot_delivered", "frameID": frameID, "hostTime": hostTime,
                    "capturedAt": capturedAt, "latencyMs": max(0, hostTime - capturedAt) * 1000], to: "events.jsonl")
        }
    }

    /// Writes a reproducible measured summary, never fabricated accuracy or power values.
    func finish(reason: String) {
        let endedAt = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            resourceTimer?.cancel()
            resourceTimer = nil
            let duration = max(0.001, endedAt - startedAt)
            let sorted = latencies.sorted()
            func percentile(_ p: Double) -> Any {
                guard !sorted.isEmpty else { return NSNull() }
                let index = min(sorted.count - 1, Int(ceil(p * Double(sorted.count))) - 1)
                return sorted[max(0, index)]
            }
            let summary: [String: Any] = [
                "runID": runID, "reason": reason, "durationSeconds": duration,
                "counts": counters,
                "validPositionAnalysisFPS": Double(counters["validPositionFrames"] ?? 0) / duration,
                "detectionFPS": Double(counters["detectionFrames"] ?? 0) / duration,
                "captureToAnalysisEndMs": ["p50": percentile(0.50), "p95": percentile(0.95),
                                           "p99": percentile(0.99), "max": sorted.last as Any? ?? NSNull()],
                "latencySampleCount": sorted.count, "latencyObservationCount": latencyObservationCount,
                "latencySamplePolicy": "first 100000 valid samples; all frames retained in JSONL",
                "memoryFootprintPeakBytes": memoryPeak > 0 ? memoryPeak as Any : NSNull(),
                "diagnosticWriteFailures": writeFailures,
                "diagnosticDroppedEntries": droppedEntryCount(),
                "evidenceIncomplete": droppedEntryCount() > 0 || writeFailures > 0,
                "precision": NSNull(), "recall": NSNull(), "identityErrors": NSNull(),
                "motorLatency": NSNull(), "powerWatts": NSNull(),
                "unmeasuredReason": "Requires annotated independent fixtures and external motor/power measurements"
            ]
            finishedSummary = summary
            writeJSON(summary, name: "summary.json")
            manifest["endedAtUTC"] = ISO8601DateFormatter().string(from: Date())
            manifest["stopReason"] = reason
            writeManifest()
            for handle in handles.values { try? handle.synchronize() }
        }
    }

    /// Flushes queued writes before UI packages/shares the run directory.
    func flush(completion: @escaping (URL?) -> Void) {
        queue.async { [self] in
            for handle in handles.values { try? handle.synchronize() }
            let url = exportURL
            DispatchQueue.main.async { completion(url) }
        }
    }

    private func recordResources() {
        guard !finished else { return }
        let footprint = Self.memoryFootprint()
        if let footprint { memoryPeak = max(memoryPeak, footprint) }
        append(["hostTime": ProcessInfo.processInfo.systemUptime,
                "memoryFootprintBytes": footprint as Any? ?? NSNull(),
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue], to: "resources.jsonl")
    }

    /// A slow disk cannot turn frame telemetry into an unbounded memory queue.
    /// On saturation the evidence is explicitly incomplete, never a clean zero.
    private func enqueue(_ work: @escaping () -> Void) {
        guard pendingEntries.wait(timeout: .now()) == .success else {
            droppedEntriesLock.lock()
            droppedEntries += 1
            droppedEntriesLock.unlock()
            return
        }
        queue.async { [self] in
            defer { pendingEntries.signal() }
            work()
        }
    }

    private func droppedEntryCount() -> Int {
        droppedEntriesLock.lock(); defer { droppedEntriesLock.unlock() }
        return droppedEntries
    }

    private static func hardwareEnvironment() -> [String: Any] {
        var system = utsname()
        let available = uname(&system) == 0
        func text<T>(_ field: T) -> String {
            withUnsafeBytes(of: field) {
                String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "unknown"
            }
        }
        var fields: [String: Any] = [
            "hardwareMachine": available ? text(system.machine) : "unknown",
            "kernelSystem": available ? text(system.sysname) : "unknown",
            "kernelRelease": available ? text(system.release) : "unknown"
        ]
        #if targetEnvironment(simulator)
        fields["executionEnvironment"] = "ios_simulator"
        fields["simulatedDeviceModelIdentifier"] = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown"
        #elseif os(iOS)
        fields["executionEnvironment"] = "ios_device"
        #elseif os(macOS)
        fields["executionEnvironment"] = "macos_host"
        #else
        fields["executionEnvironment"] = "other"
        #endif
        return fields
    }

    private static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    private func writeManifest() { writeJSON(manifest, name: "manifest.json") }

    private func writeJSON(_ object: [String: Any], name: String) {
        guard let exportURL else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: exportURL.appendingPathComponent(name), options: .atomic)
        } catch { writeFailures += 1 }
    }

    private func append(_ object: [String: Any], to name: String) {
        guard let exportURL else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(0x0A)
            let handle: FileHandle
            if let existing = handles[name] {
                handle = existing
            } else {
                let path = exportURL.appendingPathComponent(name)
                guard FileManager.default.createFile(atPath: path.path, contents: nil) else {
                    writeFailures += 1
                    return
                }
                handle = try FileHandle(forWritingTo: path)
                handles[name] = handle
            }
            try handle.write(contentsOf: data)
        } catch { writeFailures += 1 }
    }
}
