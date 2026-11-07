import Foundation

/// Wire compatibility for optional source telemetry. No phone, ReplayKit or BLE.
@main
enum ScreenFollowSourceTimingSmoke {
    static var assertions = 0
    static func expect(_ value: @autoclosure () -> Bool, _ reason: String) {
        assertions += 1
        precondition(value(), reason)
    }

    // Previous receiver schema intentionally has no sourceTiming field.
    struct LegacyMessage: Decodable {
        let kind: String
        let sessionID: UUID
        let frameID: UInt64
        let capturedAt: TimeInterval
        let jpeg: Data?
        let stopReason: String?
        let stopIsError: Bool?
    }
    static func legacyPacket(_ body: Data) -> Data {
        let count = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: count) { Data($0) } + body
    }

    static func main() throws {
        let id = UUID(uuidString: "BF85BE68-2F9D-4F3E-A2F4-4B7D111EA366")!
        // Fixed wire bytes from the old schema; do not use the new encoder to
        // synthesize an alleged old peer. Its JPEG-like payload is deliberately
        // tiny: this exercises framing and data integrity, not image decoding.
        let oldJSON = Data(#"{"kind":"frame","sessionID":"BF85BE68-2F9D-4F3E-A2F4-4B7D111EA366","frameID":41,"capturedAt":321.25,"jpeg":"/9j/2Q=="}"#.utf8)
        let oldDecoded = try JSONDecoder().decode(ScreenFollowMessage.self, from: oldJSON)
        expect(oldDecoded.kind == .frame && oldDecoded.sessionID == id && oldDecoded.frameID == 41,
               "old frame identity decodes without telemetry")
        expect(oldDecoded.capturedAt == 321.25 && oldDecoded.jpeg == Data([255,216,255,217])
               && oldDecoded.sourceTiming == nil, "old frame bytes and capture time remain intact")
        let ackJSON = Data(#"{"kind":"ack","sessionID":"BF85BE68-2F9D-4F3E-A2F4-4B7D111EA366","frameID":41,"capturedAt":0}"#.utf8)
        let ack = try JSONDecoder().decode(ScreenFollowMessage.self, from: ackJSON)
        expect(ack.kind == .ack && ack.frameID == 41 && ack.jpeg == nil && ack.sourceTiming == nil,
               "old ACK remains valid without source fields")
        let nullJSON = Data(#"{"kind":"frame","sessionID":"BF85BE68-2F9D-4F3E-A2F4-4B7D111EA366","frameID":42,"capturedAt":321.3,"sourceTiming":null}"#.utf8)
        let nullDecoded = try JSONDecoder().decode(ScreenFollowMessage.self, from: nullJSON)
        expect(nullDecoded.sourceTiming == nil,
               "explicit null telemetry is also compatible")

        var counters = ScreenFollowSourceCounters()
        counters.videoCallbacks = 61; counters.admissionBusy = 2
        counters.notReady = 3; counters.inFlightBusy = 14; counters.rateLimited = 28
        counters.encoded = 14; counters.encodeExpired = 1; counters.sent = 13
        counters.callbackGapCount = 60; counters.totalCallbackGapMS = 1000.125
        counters.maximumCallbackGapMS = 34.25
        // PTS deliberately uses a different epoch from uptime; encoding must
        // preserve it independently, never coerce it into a latency estimate.
        let timing = ScreenFollowSourceTiming(sourcePTS: 900.125,
                                              queueStartedAt: 12345.01, encodeStartedAt: 12345.012,
                                              encodedAt: 12345.02, counters: counters)
        let payload = Data((0..<81923).map { UInt8(truncatingIfNeeded: $0*37) })
        let current = ScreenFollowMessage(kind: .frame, sessionID: id, frameID: 42,
                                          capturedAt: 12345, jpeg: payload, sourceTiming: timing)
        let packet = try ScreenFollowPacketDecoder.encode(current)
        let stream = legacyPacket(oldJSON) + packet
        var decoder = ScreenFollowPacketDecoder()
        var bodies: [Data] = []
        let chunks = [1,2,3,31,4093,8191,17]
        var offset = 0, index = 0
        while offset < stream.count {
            let end = min(stream.count, offset + chunks[index % chunks.count])
            bodies += try decoder.append(stream.subdata(in: offset..<end))
            offset = end; index += 1
        }
        expect(bodies.count == 2, "mixed old/new frames survive fragmented and coalesced TCP bytes")
        let frames = try bodies.map { try JSONDecoder().decode(ScreenFollowMessage.self, from: $0) }
        expect(frames[0].frameID == 41 && frames[0].sourceTiming == nil && frames[0].jpeg == oldDecoded.jpeg,
               "legacy frame retains exact payload through production packet decoding")
        expect(frames[1].kind == .frame && frames[1].sessionID == id && frames[1].frameID == 42
               && frames[1].capturedAt == 12345 && frames[1].jpeg == payload,
               "new telemetry does not alter frame ordering, identity, capture time or image bytes")
        let sourceObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(timing)) as! NSDictionary
        let decodedObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(frames[1].sourceTiming!)) as! NSDictionary
        expect(sourceObject.isEqual(decodedObject), "all source timestamps and cumulative counters survive the real framed payload")
        let legacyReceiver = try JSONDecoder().decode(LegacyMessage.self, from: bodies[1])
        expect(legacyReceiver.frameID == 42 && legacyReceiver.capturedAt == 12345
               && legacyReceiver.jpeg == payload, "a receiver with the previous schema ignores new telemetry and retains image bytes")

        let noPTS = ScreenFollowSourceTiming(sourcePTS: nil, queueStartedAt: 1.01,
                                             encodeStartedAt: 1.012, encodedAt: 1.02,
                                             counters: ScreenFollowSourceCounters())
        let noPTSFrame = ScreenFollowMessage(kind: .frame, sessionID: id, frameID: 43,
                                             capturedAt: 1, jpeg: Data([1,2,3]), sourceTiming: noPTS)
        let noPTSDecoded = try JSONDecoder().decode(ScreenFollowMessage.self, from: JSONEncoder().encode(noPTSFrame))
        expect(noPTSDecoded.sourceTiming != nil && noPTSDecoded.sourceTiming?.sourcePTS == nil,
               "invalid/missing source PTS can remain nil without discarding valid stage telemetry")
        print("screen_follow_source_timing=passed assertions=\(assertions) legacyMissingTiming=compatible legacyReceiver=compatible framedPayload=81923 sourcePTSEpoch=independent")
    }
}
