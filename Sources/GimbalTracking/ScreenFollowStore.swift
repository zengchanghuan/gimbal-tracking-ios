import Foundation
import Network

enum ScreenFollowStore {
    static func directory() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ScreenFollowConstants.appGroup) else {
            throw ScreenFollowError.message(ScreenFollowLocalized("Shared storage unavailable. Reinstall a version with the Live Tracking extension."))
        }
        return url
    }
    static func save(_ configuration: ScreenFollowConfiguration) throws {
        try JSONEncoder().encode(configuration).write(to: directory().appendingPathComponent("session-v3.json"), options: .atomic)
    }
    static func load() throws -> ScreenFollowConfiguration {
        try load(from: directory())
    }
    // A native picker can outlive its app-side preparation (timeout, disconnect,
    // or cancellation). Treat the file as a short-lived invitation, never as a
    // durable configuration that the extension can recreate on its own.
    static func load(from directory: URL, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> ScreenFollowConfiguration {
        let configuration: ScreenFollowConfiguration
        do {
            configuration = try JSONDecoder().decode(ScreenFollowConfiguration.self,
                from: Data(contentsOf: directory.appendingPathComponent("session-v3.json")))
        } catch {
            let error = error as NSError
            NSLog("[ScreenFollowSession] load failed domain=%@ code=%ld", error.domain, error.code)
            throw ScreenFollowError.preparationUnavailable
        }
        guard configuration.canStart(now: now) else {
            NSLog("[ScreenFollowSession] load rejected version=%d age=%.3f", configuration.version, now - configuration.preparedUptime)
            throw ScreenFollowError.preparationUnavailable
        }
        return configuration
    }
    static func clear() {
        if let url = try? directory() { try? FileManager.default.removeItem(at: url.appendingPathComponent("session-v3.json")) }
    }
    // Some CoreDevice versions cannot export App Group files. Keep a metadata-only
    // copy in the main app's Documents container for device debugging as well.
    static func exportLastDiagnostics() {
        guard let group = try? directory(),
              let data = try? Data(contentsOf: group.appendingPathComponent("last-session-diagnostics.json")),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = documents.appendingPathComponent("ScreenFollow", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("last-session-diagnostics.json"), options: .atomic)
        } catch { /* The primary App Group diagnostic remains available in the app. */ }
    }
}

/// One queue owns each channel. Both ends use loopback; no camera data leaves the phone.
/// Application-level ACK permits only one frame in flight, including Vision processing.
final class ScreenFollowChannel {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var decoder = ScreenFollowPacketDecoder()
    private var closed = false
    private var finishing = false
    private var finishTimer: DispatchSourceTimer?
    private var finishCompletion: (() -> Void)?
    var onReady: (() -> Void)?
    var onMessage: ((ScreenFollowMessage) -> Void)?
    var onClose: ((String) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.onReady?(); self.receive()
            case .failed(let error): self.fail(error.localizedDescription)
            case .cancelled: self.fail(ScreenFollowLocalized("Screen Sharing Connection Closed"))
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func send(_ message: ScreenFollowMessage) {
        guard !closed, !finishing else { return }
        do {
            connection.send(content: try ScreenFollowPacketDecoder.encode(message), completion: .contentProcessed { [weak self] error in
                if let error { self?.fail(error.localizedDescription) }
            })
        } catch { fail(error.localizedDescription) }
    }

    /// Deliver the terminal reason before closing the write side, while draining
    /// in-flight frames. contentProcessed alone does not mean the peer received it.
    func finish(with message: ScreenFollowMessage, timeout: TimeInterval = 0.75,
                completion: (() -> Void)? = nil) {
        guard !finishing else { return }
        guard !closed else { completion?(); return }
        precondition(message.kind == .stop && timeout.isFinite && timeout > 0)
        finishing = true
        onReady = nil; onMessage = nil; onClose = nil
        finishCompletion = completion
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Retain this old channel until the peer closes or the bounded timeout;
        // cancel() releases the handler and cannot affect a newer app session.
        timer.setEventHandler { [self] in cancel() }
        timer.schedule(deadline: .now() + timeout)
        finishTimer = timer; timer.resume()
        do {
            connection.send(content: try ScreenFollowPacketDecoder.encode(message),
                            contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] error in
                if error != nil { self?.cancel() }
            })
        } catch { cancel() }
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        finishTimer?.setEventHandler {}; finishTimer?.cancel(); finishTimer = nil
        let completion = finishCompletion; finishCompletion = nil
        onReady = nil; onMessage = nil; onClose = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion?()
    }
    private func fail(_ message: String) {
        guard !closed else { return }
        let callback = onClose
        cancel()
        callback?(message)
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            do {
                if let data {
                    for body in try self.decoder.append(data) {
                        let message = try JSONDecoder().decode(ScreenFollowMessage.self, from: body)
                        self.onMessage?(message)
                        if self.closed { return }
                    }
                }
                if let error { self.fail(error.localizedDescription) }
                else if complete { self.fail(ScreenFollowLocalized("Screen Sharing Ended")) }
                else { self.receive() }
            } catch { self.fail(error.localizedDescription) }
        }
    }
}
