import ReplayKit
import Network

final class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "com.example.screenfollow.broadcast")
    private let admission = DispatchSemaphore(value: 1)
    private let adapter = ScreenFollowFrameAdapter()
    private var channel: ScreenFollowChannel?
    private var configuration: ScreenFollowConfiguration?
    private var timer: DispatchSourceTimer?
    private var ready = false
    private var paused = false
    private var finished = false
    private var inFlight: UInt64?
    private var frameID: UInt64 = 0
    private var cadence = ScreenFollowFrameCadence()
    private var lastReplyAt: TimeInterval = 0
    private let sourceLock = NSLock()
    private var sourceCounters = ScreenFollowSourceCounters()
    private var lastVideoCallbackAt: TimeInterval?

    @discardableResult
    private func recordSource(_ update: (inout ScreenFollowSourceCounters) -> Void) -> ScreenFollowSourceCounters {
        sourceLock.lock()
        defer { sourceLock.unlock() }
        update(&sourceCounters)
        return sourceCounters
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        queue.async { [self] in
            do {
                guard (Bundle.main.object(forInfoDictionaryKey: "SFEnabled") as? String) == "YES" else {
                    throw ScreenFollowError.message(ScreenFollowLocalized("Live Tracking is not available in this version."))
                }
                let config = try ScreenFollowStore.load()
                NSLog("[ScreenFollowSession] extension loaded session=%@ age=%.3f", config.sessionID.uuidString,
                      ProcessInfo.processInfo.systemUptime - config.preparedUptime)
                configuration = config
                let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: config.port)!, using: .tcp)
                let channel = ScreenFollowChannel(connection: connection, queue: queue)
                self.channel = channel
                channel.onReady = { [weak self] in
                    self?.channel?.send(ScreenFollowMessage(kind: .hello, sessionID: config.sessionID))
                }
                channel.onMessage = { [weak self] message in
                    guard let self, message.sessionID == config.sessionID else { return }
                    lastReplyAt = ProcessInfo.processInfo.systemUptime
                    if message.kind == .stop {
                        fail(message.stopReason ?? ScreenFollowLocalized("Live Tracking Ended"), code: message.stopIsError == false ? 0 : 1)
                        return
                    }
                    guard message.kind == .ack else { fail(ScreenFollowLocalized("Invalid Screen Sharing Response")); return }
                    if message.frameID == 0 { ready = true }
                    else if inFlight == message.frameID { inFlight = nil }
                }
                channel.onClose = { [weak self] message in
                    NSLog("[ScreenFollowBroadcast] channel closed: %@", message)
                    self?.fail(ScreenFollowLocalized("Screen sharing disconnected. Return to Gimbal Tracking and prepare tracking again."))
                }
                lastReplyAt = ProcessInfo.processInfo.systemUptime
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    if ProcessInfo.processInfo.systemUptime - lastReplyAt > 5 {
                        fail(ScreenFollowLocalized("Gimbal Tracking cannot process frames right now. Return to the app and prepare tracking again."))
                    }
                }
                self.timer = timer; timer.resume()
                channel.start()
            } catch { fail(error.localizedDescription) }
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let capturedAt = ProcessInfo.processInfo.systemUptime
        recordSource {
            $0.videoCallbacks += 1
            if let previous = lastVideoCallbackAt, capturedAt > previous {
                let gap = (capturedAt - previous) * 1000
                $0.callbackGapCount += 1
                $0.totalCallbackGapMS += gap
                $0.maximumCallbackGapMS = max($0.maximumCallbackGapMS, gap)
            }
            lastVideoCallbackAt = capturedAt
        }
        guard admission.wait(timeout: .now()) == .success else {
            recordSource { $0.admissionBusy += 1 }; return
        }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        queue.async { [self] in
            defer { admission.signal() }
            let queueStartedAt = ProcessInfo.processInfo.systemUptime
            guard ready, !paused, !finished, let config = configuration else {
                recordSource { $0.notReady += 1 }; return
            }
            guard inFlight == nil else { recordSource { $0.inFlightBusy += 1 }; return }
            guard cadence.isDue(at: capturedAt) else { recordSource { $0.rateLimited += 1 }; return }
            autoreleasepool {
                do {
                    let encodeStartedAt = ProcessInfo.processInfo.systemUptime
                    let jpeg = try adapter.jpeg(from: sampleBuffer)
                    let encodedAt = ProcessInfo.processInfo.systemUptime
                    recordSource { $0.encoded += 1 }
                    guard encodedAt - capturedAt <= ScreenFollowConstants.maximumFrameAge else {
                        recordSource { $0.encodeExpired += 1 }; return
                    }
                    frameID += 1; inFlight = frameID; cadence.didSend(at: capturedAt)
                    let counters = recordSource { $0.sent += 1 }
                    channel?.send(ScreenFollowMessage(kind: .frame, sessionID: config.sessionID,
                                                      frameID: frameID, capturedAt: capturedAt, jpeg: jpeg,
                                                      sourceTiming: ScreenFollowSourceTiming(sourcePTS: pts.isFinite ? pts : nil,
                                                          queueStartedAt: queueStartedAt, encodeStartedAt: encodeStartedAt,
                                                          encodedAt: encodedAt, counters: counters)))
                } catch { fail(error.localizedDescription) }
            }
        }
    }

    override func broadcastPaused() { queue.async { [self] in paused = true; control(.pause) } }
    override func broadcastResumed() { queue.async { [self] in
        paused = false; cadence.reset()
        recordSource { _ in lastVideoCallbackAt = nil }
        control(.resume)
    } }
    override func broadcastFinished() { queue.async { [self] in cleanup() } }
    private func control(_ kind: ScreenFollowMessage.Kind) {
        if let config = configuration { channel?.send(ScreenFollowMessage(kind: kind, sessionID: config.sessionID)) }
    }
    private func cleanup() {
        finished = true; ready = false
        timer?.cancel(); timer = nil
        channel?.cancel(); channel = nil
    }
    private func fail(_ message: String, code: Int = 1) {
        guard !finished else { return }
        cleanup()
        finishBroadcastWithError(NSError(domain: ScreenFollowConstants.extensionBundleID, code: code,
                                         userInfo: [NSLocalizedDescriptionKey: message, NSLocalizedFailureReasonErrorKey: message]))
    }
}
