import UIKit
import Network
import Vision
import ImageIO

/// The main process remains the sole owner of Vision and the initialized BLE connection.
/// State, controller and BLE access are confined to the main queue; Vision has one worker.
final class ScreenFollowMainAccess {
    private final class BackgroundTaskLease {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        func end() {
            guard identifier != .invalid else { return }
            let old = identifier; identifier = .invalid
            UIApplication.shared.endBackgroundTask(old)
        }
    }
    static let shared = ScreenFollowMainAccess()
    static var featureEnabled: Bool { (Bundle.main.object(forInfoDictionaryKey: "KKScreenFollowEnabled") as? String) == "YES" }
    private(set) var sessionID: UUID?
    var allowsCamera: Bool { sessionID == nil && !configurationVisible }
    var configurationVisible = false
    private(set) var readyForBroadcast = false
    private(set) var diagnostics = ScreenFollowDiagnostics()
    var onUpdate: (() -> Void)?

    private let visionQueue = DispatchQueue(label: "com.example.screenfollow.vision", qos: .userInitiated)
    private let faceAnalyzer = ScreenFollowFaceAnalyzer(
        asyncValidation: ScreenFollowValidationWorker(prefersNeuralEngine: true),
        prefersNeuralEngine: true, detectsVerticalMotionEveryFrame: true)
    private var listener: NWListener?
    private var channel: ScreenFollowChannel?
    private var peripheralID: UUID?
    private var controller = ScreenFollowController()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var backgroundTask: BackgroundTaskLease?
    var broadcastConnected: Bool { authenticated }
    static let broadcastStateDidChange = Notification.Name("ScreenFollowBroadcastStateDidChange")
    private var authenticated = false {
        didSet {
            guard authenticated != oldValue else { return }
            NotificationCenter.default.post(name: Self.broadcastStateDidChange, object: self)
        }
    }
    private var processing = false
    private var paused = false
    private var preparedAt: TimeInterval = 0
    private var lastFrameAt: TimeInterval = 0
    private var lastHoldAt: TimeInterval = 0
    private var lastHeartbeatAt: TimeInterval = 0
    private var broadcastBeganAt: TimeInterval = 0
    private var lastMetricsAt: TimeInterval = 0
    private var lastMetricsFrames = 0
    private var lastSourceMetricsAt: TimeInterval = 0
    private var lastTraceAt: TimeInterval = 0
    private var lastTraceDecision = ""
    private var lastControlCompletedAt: TimeInterval?
    private var lastControlCapturedAt: TimeInterval?
    private var lastWriteAt: TimeInterval?
    private var lastWriteWasMotion = false
    private var acceptedFrameID: UInt64 = 0
    private var analysisGeneration: UInt64 = 0
    private var yawSign = 1.0
    private var pitchSign = 1.0
    private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)

    private init() {
        ScreenFollowStore.exportLastDiagnostics()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, sessionID != nil else { return }
            invalidateAnalysis(); hold(message: KKLocalized("Paused: return to the live video to resume tracking"))
            endBackgroundTask()
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, sessionID != nil else { return }
            invalidateAnalysis(); lastFrameAt = ProcessInfo.processInfo.systemUptime
            beginBackgroundTask()
        })
        observers.append(center.addObserver(forName: .bleStatusChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, sessionID != nil else { return }
            if !bleReady { stop(message: KKLocalized("Gimbal disconnected. Reconnect and prepare tracking again.")) }
        })
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop(message: KKLocalized("App Exited"))
        })
    }

    private var bleReady: Bool {
        KKBLEManager.shared.isCommandChannelReady && KKBLEManager.shared.connectedPeripheral?.identifier == peripheralID
    }

    func prepare(frontCamera: Bool, reverseYaw: Bool, reversePitch: Bool, crop: CGRect) throws {
        precondition(Thread.isMainThread)
        guard Self.featureEnabled, sessionID == nil else { throw ScreenFollowError.message(KKLocalized("Stop the current tracking session first.")) }
        guard !CameraManager.shared.isRecording, !CameraManager.shared.isPanoramaCameraControlLocked,
              !FirmwareUpdateManager.mUpdating else { throw ScreenFollowError.message(KKLocalized("Stop recording, panorama capture or firmware updates first.")) }
        guard ProcessInfo.processInfo.thermalState != .critical else { throw ScreenFollowError.message(KKLocalized("Phone is too hot. Let it cool before preparing tracking.")) }
        guard KKBLEManager.shared.isCommandChannelReady, let peripheral = KKBLEManager.shared.connectedPeripheral else {
            throw ScreenFollowError.message(KKLocalized("Connect the gimbal and wait for the connection to finish."))
        }
        UserDefaults(suiteName: ScreenFollowConstants.appGroup)?.set(KKLanguageManager.shared.effectiveLanguage.rawValue, forKey: "screenFollowLanguage")
        let id = UUID()
        guard KKBLEManager.shared.beginScreenFollowSession(id, peripheralID: peripheral.identifier) else {
            throw ScreenFollowError.message(KKLocalized("Gimbal controls are busy. Finish the update or try again later."))
        }
        sessionID = id; peripheralID = peripheral.identifier
        readyForBroadcast = false; authenticated = false; processing = false; paused = false
        controller = ScreenFollowController(); acceptedFrameID = 0
        diagnostics = ScreenFollowDiagnostics()
        broadcastBeganAt = 0; lastMetricsAt = 0; lastMetricsFrames = 0
        lastSourceMetricsAt = 0
        lastTraceAt = 0; lastTraceDecision = ""
        lastControlCompletedAt = nil; lastControlCapturedAt = nil
        lastWriteAt = nil; lastWriteWasMotion = false
        preparedAt = ProcessInfo.processInfo.systemUptime; lastFrameAt = preparedAt
        kkLog("[ScreenFollowSession] prepare session=\(id) uptime=\(preparedAt)")
        yawSign = (frontCamera ? 1 : -1) * (reverseYaw ? -1 : 1)
        pitchSign = (frontCamera ? 1 : -1) * (reversePitch ? -1 : 1)
        diagnostics.camera = frontCamera ? "front" : "rear"
        diagnostics.yawSign = yawSign; diagnostics.pitchSign = pitchSign
        self.crop = crop
        KKBLEManager.shared.screenFollowWriteEvent = { [weak self] eventID, data, event in
            guard let self, sessionID == eventID else { return }
            switch event {
            case "sent":
                diagnostics.lastPacket = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                let motion = data != GimbalTrackingPacket.encode()
                let sentAt = ProcessInfo.processInfo.systemUptime
                let gap = lastWriteAt.map { sentAt - $0 } ?? 0
                if (motion || lastWriteWasMotion), data.count == 10 {
                    let bytes = Array(data)
                    let yaw = Int(bytes[5]) * 256 + Int(bytes[6]) - 10000
                    let pitch = Int(bytes[7]) * 256 + Int(bytes[8]) - 10000
                    kkLog("[ScreenFollowWrite] sentAtMS=\(Int(sentAt * 1000)) gapMS=\(Int(gap * 1000)) command=\(yaw),\(pitch)")
                }
                lastWriteAt = sentAt; lastWriteWasMotion = motion
                if !motion { diagnostics.submittedHold += 1 }
                else { diagnostics.submittedMotion += 1 }
            case "ack": diagnostics.acknowledgements += 1
            case "expired": diagnostics.expiredCommands += 1
            default: diagnostics.writeErrors += 1; stop(message: KKLocalized("Bluetooth write failed. Check the gimbal connection."))
            }
        }
        do {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, sessionID == id else { return }
                switch state {
                case .ready:
                    do {
                        guard let port = listener.port else { throw ScreenFollowError.message(KKLocalized("Unable to create a screen sharing channel.")) }
                        try ScreenFollowStore.save(ScreenFollowConfiguration(sessionID: id, peripheralID: peripheral.identifier,
                                                                            port: port.rawValue, preparedUptime: preparedAt))
                        kkLog("[ScreenFollowSession] saved session=\(id) age=\(ProcessInfo.processInfo.systemUptime - preparedAt)")
                        readyForBroadcast = true
                        update(KKLocalized("Tap Screen Broadcast, then Start Broadcast in the system dialog."))
                    } catch { stop(message: error.localizedDescription) }
                case .failed(let error): stop(message: KKLocalizedFormat("Screen sharing channel failed: %@", error.localizedDescription))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, sessionID == id, channel == nil else { connection.cancel(); return }
                let channel = ScreenFollowChannel(connection: connection, queue: .main)
                self.channel = channel
                channel.onMessage = { [weak self] message in self?.receive(message) }
                channel.onClose = { [weak self] message in self?.stop(message: message) }
                channel.start()
            }
            listener.start(queue: .main)
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
            beginBackgroundTask()
            update(KKLocalized("Preparing screen sharing…"))
        } catch { stop(message: error.localizedDescription); throw error }
    }

    func receive(_ message: ScreenFollowMessage, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        precondition(Thread.isMainThread)
        guard let id = sessionID else { return }
        guard message.sessionID == id else { stop(message: KKLocalized("Screen sharing session expired. Prepare it again.")); return }
        if message.kind == .hello {
            guard !authenticated, now - preparedAt <= ScreenFollowConstants.preparationLifetime else {
                stop(message: KKLocalized("Preparation expired. Prepare tracking again.")); return
            }
            authenticated = true; lastFrameAt = now
            broadcastBeganAt = lastFrameAt; lastMetricsAt = lastFrameAt
            channel?.send(ScreenFollowMessage(kind: .ack, sessionID: id))
            update(KKLocalized("Screen broadcast connected. Open your streaming app and show one face."))
            return
        }
        guard authenticated else { stop(message: KKLocalized("Screen sharing is not authenticated.")); return }
        if message.kind == .pause || message.kind == .resume {
            let wasPaused = paused
            let frameGap = max(0, now - lastFrameAt)
            paused = message.kind == .pause
            // ReplayKit can suspend delivery while another app opens its camera.
            // Resume starts a new wait for the first frame; time spent paused
            // must not consume it. Duplicate resume messages cannot renew it.
            if wasPaused, !paused { lastFrameAt = now }
            kkLog("[ScreenFollowSession] broadcastControl=\(message.kind.rawValue) wasPaused=\(wasPaused) frameGapMS=\(Int(frameGap * 1000))")
            invalidateAnalysis(); hold(message: paused ? KKLocalized("Screen Broadcast Paused") : KKLocalized("Waiting for Live Video"))
            return
        }
        guard message.kind == .frame, let jpeg = message.jpeg, message.frameID > acceptedFrameID else {
            stop(message: KKLocalized("Invalid frame order. Prepare screen sharing again.")); return
        }
        acceptedFrameID = message.frameID
        diagnostics.frames += 1
        lastFrameAt = now
        let receivedAt = lastFrameAt
        reportSourceCounters(message, now: receivedAt)
        guard !paused, UIApplication.shared.applicationState == .background else {
            hold(message: KKLocalized("Paused: open your streaming app to start tracking"))
            acknowledge(message); return
        }
        guard bleReady else { stop(message: KKLocalized("Gimbal Connection Unavailable")); return }
        guard fresh(message.capturedAt), !processing else {
            diagnostics.staleFrames += 1; hold(message: KKLocalized("Video delayed. Waiting for a new frame."))
            acknowledge(message); return
        }
        processing = true
        let generation = analysisGeneration
        let crop = self.crop
        let confirmedTarget = controller.trackingReference
        let visionQueuedAt = ProcessInfo.processInfo.systemUptime
        visionQueue.async { [weak self] in
            guard let self else { return }
            let visionStartedAt = ProcessInfo.processInfo.systemUptime
            var analyzerStartedAt: TimeInterval?
            var analyzerCompletedAt: TimeInterval?
            let result: Result<ScreenFollowFaceAnalyzer.Result, Error> = Result {
                try autoreleasepool {
                    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 640, height <= 640,
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        throw ScreenFollowError.message(KKLocalized("Invalid Screen Image"))
                    }
                    guard width <= height else { throw ScreenFollowError.message(KKLocalized("Portrait streaming only. Hold your phone upright and prepare again.")) }
                    // Crop is top-left normalized. Physically crop so returned boxes are relative to the preview.
                    let rect = CGRect(x: crop.minX * CGFloat(width), y: crop.minY * CGFloat(height),
                                      width: crop.width * CGFloat(width), height: crop.height * CGFloat(height)).integral
                    guard let preview = image.cropping(to: rect) else { throw ScreenFollowError.message(KKLocalized("Detection Area Unavailable")) }
                    analyzerStartedAt = ProcessInfo.processInfo.systemUptime
                    defer { analyzerCompletedAt = ProcessInfo.processInfo.systemUptime }
                    return try self.faceAnalyzer.analyze(preview, capturedAt: message.capturedAt,
                                                    now: ProcessInfo.processInfo.systemUptime,
                                                    context: "\(id.uuidString):\(generation)", confirmedTarget: confirmedTarget)
                }
            }
            // Copy worker-local measurements before returning to the main queue.
            // These timestamps never participate in frame eligibility or control.
            let analyzerStarted = analyzerStartedAt
            let analyzerCompleted = analyzerCompletedAt
            let visionCompletedAt = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { [weak self] in
                guard let self, sessionID == id else { return }
                processing = false
                defer { acknowledge(message) }
                guard generation == analysisGeneration, !paused,
                      UIApplication.shared.applicationState == .background else { return }
                switch result {
                case .failure(let error): stop(message: KKLocalizedFormat("Face detection failed: %@", error.localizedDescription))
                case .success(let analysis):
                    let faces = analysis.faces
                    let now = ProcessInfo.processInfo.systemUptime
                    diagnostics.recordAnalysis(capturedAt: message.capturedAt, receivedAt: receivedAt,
                                               completedAt: now, usedTracking: analysis.usedTracking)
                    if let duration = analysis.backgroundValidationMS, duration.isFinite, duration >= 0 {
                        diagnostics.backgroundValidationResults = (diagnostics.backgroundValidationResults ?? 0) + 1
                        diagnostics.totalBackgroundValidationMS = (diagnostics.totalBackgroundValidationMS ?? 0) + duration
                    }
                    guard fresh(message.capturedAt) else {
                        diagnostics.staleFrames += 1; hold(message: KKLocalized("Detection took too long. Waiting for a new frame.")); return
                    }
                    if faces.isEmpty { diagnostics.noFaceFrames += 1 }
                    else { diagnostics.detectedFrames += 1 }
                    if analysis.detectedFaceCount > 1 { diagnostics.multipleFaceFrames += 1 }
                    let wasConfirmed = controller.trackingReference != nil
                    if analysis.resetsTarget { controller.reset() }
                    guard let command = controller.observe(faces: faces, frameID: message.frameID,
                                                            capturedAt: message.capturedAt, now: now,
                                                            yawSign: yawSign, pitchSign: pitchSign) else { return }
                    if !wasConfirmed, controller.trackingReference != nil { diagnostics.targetAcquisitions += 1 }
                    if wasConfirmed, controller.trackingReference == nil { diagnostics.targetLosses += 1 }
                    diagnostics.analysisDecisions[analysis.decision, default: 0] += 1
                    diagnostics.controlDecisions[controller.decision, default: 0] += 1
                    if controller.pitchStartBoosted {
                        diagnostics.pitchStartBoostFrames = (diagnostics.pitchStartBoostFrames ?? 0) + 1
                    }
                    // Diagnostic timing only: the restored controller uses capture time.
                    let controlGap = lastControlCompletedAt.map { now - $0 } ?? 0
                    let captureGap = lastControlCapturedAt.map { message.capturedAt - $0 } ?? 0
                    lastControlCompletedAt = now; lastControlCapturedAt = message.capturedAt
                    let traceDecision = "\(analysis.decision)/\(controller.decision)"
                    if command != .hold || traceDecision != lastTraceDecision || now - lastTraceAt >= 0.4 {
                        kkLog("[ScreenFollowTrace] frame=\(message.frameID) decision=\(traceDecision) command=\(command.yaw),\(command.pitch) pitchStartBoosted=\(controller.pitchStartBoosted) downwardLead=\(Int(controller.downwardLead.rounded())) centerHandoffTail=\(controller.centerHandoffTailActive) capturedAtMS=\(Int(message.capturedAt * 1000)) completedAtMS=\(Int(now * 1000)) controlGapMS=\(Int(controlGap * 1000)) captureGapMS=\(Int(captureGap * 1000)) \(analysis.details)")
                        let source = message.sourceTiming
                        let sourcePTS = source?.sourcePTS.flatMap { $0.isFinite ? String(format: "%.6f", $0) : nil } ?? "NA"
                        kkLog("[ScreenFollowPipeline] frame=\(message.frameID) sourceQueueMS=\(Self.durationMS(from: message.capturedAt, to: source?.queueStartedAt)) encodeMS=\(Self.durationMS(from: source?.encodeStartedAt, to: source?.encodedAt)) transportMS=\(Self.durationMS(from: source?.encodedAt, to: receivedAt)) visionQueueMS=\(Self.durationMS(from: visionQueuedAt, to: visionStartedAt)) decodeMS=\(Self.durationMS(from: visionStartedAt, to: analyzerStarted)) analyzerMS=\(Self.durationMS(from: analyzerStarted, to: analyzerCompleted)) mainReturnMS=\(Self.durationMS(from: visionCompletedAt, to: now)) totalMS=\(Self.durationMS(from: message.capturedAt, to: now)) sourcePTS=\(sourcePTS)")
                        lastTraceAt = now; lastTraceDecision = traceDecision
                    }
                    if command != .hold { diagnostics.motionCommands += 1 }
                    KKBLEManager.shared.writeScreenFollow(command, sessionID: id,
                                                         expiresAt: message.capturedAt + ScreenFollowConstants.maximumFrameAge)
                    update(controller.hasConfirmedTarget ? KKLocalized("Face detected. Sending tracking commands.") : faces.count > 1 ? KKLocalized("Place one face in the detection area.") : KKLocalized("Waiting for a steady face in the frame"))
                }
            }
        }
    }

    private func fresh(_ time: TimeInterval) -> Bool {
        let age = ProcessInfo.processInfo.systemUptime - time
        return age.isFinite && age >= 0 && age <= ScreenFollowConstants.maximumFrameAge
    }
    private static func durationMS(from start: TimeInterval?, to end: TimeInterval?) -> String {
        guard let start, let end, start.isFinite, end.isFinite, end >= start else { return "NA" }
        let milliseconds = (end - start) * 1000
        return milliseconds.isFinite ? String(format: "%.2f", milliseconds) : "NA"
    }
    private func reportSourceCounters(_ message: ScreenFollowMessage, now: TimeInterval) {
        guard let source = message.sourceTiming, now.isFinite,
              lastSourceMetricsAt == 0 || now - lastSourceMetricsAt >= 2 else { return }
        lastSourceMetricsAt = now
        let counts = source.counters
        let hasGaps = counts.callbackGapCount > 0
        let averageGap = hasGaps && counts.totalCallbackGapMS.isFinite && counts.totalCallbackGapMS >= 0
            ? String(format: "%.2f", counts.totalCallbackGapMS / Double(counts.callbackGapCount)) : "NA"
        let maximumGap = hasGaps && counts.maximumCallbackGapMS.isFinite && counts.maximumCallbackGapMS >= 0
            ? String(format: "%.2f", counts.maximumCallbackGapMS) : "NA"
        // Cumulative source counters are intentionally separate from per-frame
        // traces. Old broadcast messages without optional timing stay compatible.
        kkLog("[ScreenFollowSource] frame=\(message.frameID) videoCallbacks=\(counts.videoCallbacks) admissionBusy=\(counts.admissionBusy) notReady=\(counts.notReady) inFlightBusy=\(counts.inFlightBusy) rateLimited=\(counts.rateLimited) encoded=\(counts.encoded) encodeExpired=\(counts.encodeExpired) sent=\(counts.sent) callbackGapCount=\(counts.callbackGapCount) callbackAvgMS=\(averageGap) callbackMaxMS=\(maximumGap)")
    }
    private func acknowledge(_ frame: ScreenFollowMessage) {
        guard sessionID == frame.sessionID else { return }
        channel?.send(ScreenFollowMessage(kind: .ack, sessionID: frame.sessionID, frameID: frame.frameID))
    }
    private func invalidateAnalysis() {
        analysisGeneration &+= 1; controller.reset()
        lastControlCompletedAt = nil; lastControlCapturedAt = nil
    }
    private func hold(message: String) {
        controller.reset()
        lastControlCompletedAt = nil; lastControlCapturedAt = nil
        let now = ProcessInfo.processInfo.systemUptime
        if let id = sessionID, now - lastHoldAt >= 0.2 {
            KKBLEManager.shared.writeScreenFollow(.hold, sessionID: id, expiresAt: now + 0.5)
            lastHoldAt = now
        }
        update(message)
    }
    func tick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        precondition(Thread.isMainThread)
        guard let id = sessionID else { return }
        guard bleReady else { stop(message: KKLocalized("Gimbal Disconnected")); return }
        if ProcessInfo.processInfo.thermalState == .critical { stop(message: KKLocalized("Phone overheated. Tracking stopped.")); return }
        if !authenticated, now - preparedAt > ScreenFollowConstants.preparationLifetime { stop(message: KKLocalized("Preparation expired. Prepare again.")); return }
        guard authenticated else { onUpdate?(); return }
        diagnostics.broadcastDurationSeconds = now - broadcastBeganAt
        if now - lastMetricsAt >= 2 { reportMetrics(now: now) }
        if now - lastHeartbeatAt >= 1 {
            channel?.send(ScreenFollowMessage(kind: .ack, sessionID: id))
            lastHeartbeatAt = now
        }
        if authenticated, !paused, now - lastFrameAt > 5 { stop(message: KKLocalized("No screen frames received. Restart the broadcast.")); return }
        if paused || now - lastFrameAt > ScreenFollowConstants.maximumFrameAge {
            hold(message: paused ? KKLocalized("Screen Broadcast Paused") : KKLocalized("Waiting for New Screen Frames"))
        }
        onUpdate?()
    }

    func stop() { stop(message: KKLocalized("Live Tracking Ended"), userInitiated: true) }

    func stop(message: String, userInitiated: Bool = false) {
        precondition(Thread.isMainThread)
        guard let id = sessionID else { return }
        kkLog("[ScreenFollowSession] stop session=\(id) age=\(ProcessInfo.processInfo.systemUptime - preparedAt) connected=\(authenticated) reason=\(message)")
        // Flush queued motion before allowing normal camera commands again.
        KKBLEManager.shared.endScreenFollowSession(id)
        KKBLEManager.shared.screenFollowWriteEvent = nil
        sessionID = nil; readyForBroadcast = false; authenticated = false
        invalidateAnalysis()
        visionQueue.async { [faceAnalyzer] in faceAnalyzer.reset() }
        let oldChannel = channel; channel = nil
        let oldBackgroundTask = backgroundTask; backgroundTask = nil
        let completeOldBackgroundTask: () -> Void = { oldBackgroundTask?.end() }
        if let oldChannel {
            oldChannel.finish(with: ScreenFollowMessage(kind: .stop, sessionID: id,
                                                       stopReason: message, stopIsError: !userInitiated),
                              completion: completeOldBackgroundTask)
        } else { completeOldBackgroundTask() }
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        timer?.invalidate(); timer = nil
        ScreenFollowStore.clear()
        update(message)
        let now = ProcessInfo.processInfo.systemUptime
        if broadcastBeganAt > 0 {
            diagnostics.broadcastDurationSeconds = now - broadcastBeganAt
            reportMetrics(now: now)
        }
        if let directory = try? ScreenFollowStore.directory(), let data = try? JSONEncoder().encode(diagnostics) {
            try? data.write(to: directory.appendingPathComponent("last-session-diagnostics.json"), options: .atomic)
            ScreenFollowStore.exportLastDiagnostics()
        }
    }
    private func beginBackgroundTask() {
        guard backgroundTask == nil else { return }
        let lease = BackgroundTaskLease(); backgroundTask = lease
        lease.identifier = UIApplication.shared.beginBackgroundTask(withName: "Live face following") { [weak self, weak lease] in
            guard let lease else { return }
            // A detached old task may expire while a new session is preparing.
            // Its callback can release only its own lease, never the new session.
            if let self, backgroundTask === lease {
                stop(message: KKLocalized("Background execution ended. Return to the app and prepare tracking again."))
            }
            lease.end()
        }
        if lease.identifier == .invalid { backgroundTask = nil }
    }
    private func reportMetrics(now: TimeInterval) {
        let elapsed = max(0.001, now - lastMetricsAt)
        let fps = Double(diagnostics.analyzedFrames - lastMetricsFrames) / elapsed
        let backgroundMeanMS = (diagnostics.totalBackgroundValidationMS ?? 0) / Double(max(1, diagnostics.backgroundValidationResults ?? 0))
        let center = controller.target.map { "\(Int(($0.centerX - 0.5) * 2000)),\(Int((0.5 - $0.centerY) * 2000))" } ?? "none"
        kkLog("[ScreenFollowMetrics] version=\(diagnostics.controllerVersion) camera=\(diagnostics.camera) signs=\(Int(yawSign)),\(Int(pitchSign)) seconds=\(Int(diagnostics.broadcastDurationSeconds)) frames=\(diagnostics.frames) analyzed=\(diagnostics.analyzedFrames) windowFPS=\(String(format: "%.1f", fps)) meanMS=\(Int(diagnostics.averageLatencyMS)) transportMS=\(Int(diagnostics.averageTransportMS)) analysisMS=\(Int(diagnostics.averageAnalysisMS)) detect=\(diagnostics.faceDetectionFrames) track=\(diagnostics.visualTrackingFrames) detectMS=\(Int(diagnostics.averageDetectionMS)) trackMS=\(Int(diagnostics.averageTrackingMS)) asyncResults=\(diagnostics.backgroundValidationResults ?? 0) asyncDetectMS=\(Int(backgroundMeanMS)) maxMS=\(Int(diagnostics.maximumLatencyMS)) stale=\(diagnostics.staleFrames) faces=\(diagnostics.detectedFrames) motionTX=\(diagnostics.submittedMotion) holdTX=\(diagnostics.submittedHold) ack=\(diagnostics.acknowledgements) errors=\(diagnostics.writeErrors) pitchStarts=\(diagnostics.pitchStartBoostFrames ?? 0) center=\(center) packet=\(diagnostics.lastPacket)")
        lastMetricsAt = now; lastMetricsFrames = diagnostics.analyzedFrames
    }
    private func endBackgroundTask() {
        let task = backgroundTask; backgroundTask = nil
        task?.end()
    }
    private func update(_ message: String) {
        if diagnostics.message != message {
            diagnostics.message = message
            kkLog("[ScreenFollow] \(message) frames=\(diagnostics.frames) faces=\(diagnostics.detectedFrames) motionTX=\(diagnostics.submittedMotion)")
        }
        onUpdate?()
    }
}
