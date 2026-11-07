import Foundation

@main
enum ScreenFollowStoreSmoke {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }
    static func rejectsPreparation(_ directory: URL, now: TimeInterval, _ message: String) {
        do {
            _ = try ScreenFollowStore.load(from: directory, now: now)
            preconditionFailure(message)
        } catch ScreenFollowError.preparationUnavailable {
            let description = ScreenFollowError.preparationUnavailable.localizedDescription
            expect(description.contains("Return to Gimbal Tracking") && description.contains("Start Live Tracking again"), "failure explains recovery")
            expect(!description.contains("session-v3.json"), "internal filename stays out of system alert")
        } catch { preconditionFailure("Unexpected error for \(message): \(error)") }
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screen-follow-store-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session-v3.json")
        func write(_ config: ScreenFollowConfiguration) throws {
            try JSONEncoder().encode(config).write(to: file, options: .atomic)
        }
        // Control Center entry before preparation, or late extension startup
        // after app-side expiry, must give the same actionable recovery message.
        rejectsPreparation(directory, now: 100, "absent preparation")
        try Data("{partial".utf8).write(to: file)
        rejectsPreparation(directory, now: 100, "corrupt preparation")

        let original = ScreenFollowConfiguration(sessionID: UUID(), peripheralID: UUID(), port: 8999, preparedUptime: 100)
        try write(original)
        let loaded = try ScreenFollowStore.load(from: directory, now: 100)
        expect(loaded.sessionID == original.sessionID && loaded.port == original.port, "fresh invitation is preserved")
        _ = try ScreenFollowStore.load(from: directory, now: 220)
        assertions += 1
        rejectsPreparation(directory, now: 220.01, "expired invitation")
        rejectsPreparation(directory, now: 99, "uptime reset")
        rejectsPreparation(directory, now: .nan, "invalid clock")
        var oldVersion = original; oldVersion.version = 2
        try write(oldVersion)
        rejectsPreparation(directory, now: 100, "old protocol version")
        try write(ScreenFollowConfiguration(sessionID: UUID(), peripheralID: original.peripheralID, port: 0, preparedUptime: 100))
        rejectsPreparation(directory, now: 100, "invalid port")

        try FileManager.default.removeItem(at: file)
        rejectsPreparation(directory, now: 221, "app cleared invitation before extension loaded")
        let retry = ScreenFollowConfiguration(sessionID: UUID(), peripheralID: original.peripheralID, port: 9000, preparedUptime: 221)
        try write(retry)
        let recovered = try ScreenFollowStore.load(from: directory, now: 221)
        expect(recovered.sessionID == retry.sessionID && recovered.sessionID != original.sessionID, "fresh retry recovers with new identity")
        expect(recovered.canStart(now: 341), "retry gets the full preparation lifetime")
        print("screen_follow_store=passed assertions=\(assertions)")
    }
}
