import XCTest
import GimbalTracking

final class PublicAPITests: XCTestCase {
    func testTargetLossStopsAndDuplicateDoesNotMove() {
        var controller = FollowController()
        let box = TrackingBox(CGRect(x: 0.65, y: 0.4, width: 0.2, height: 0.2))
        var command: FollowCommand?
        for frame in 1...10 {
            let now = 100 + Double(frame) / 10
            command = controller.observe(boxes: [box], frameID: UInt64(frame), capturedAt: now, now: now)
        }
        XCTAssertTrue(controller.hasConfirmedTarget)
        XCTAssertGreaterThan(command?.yaw ?? 0, 0)
        XCTAssertNil(controller.observe(boxes: [box], frameID: 10, capturedAt: 101, now: 101))
        XCTAssertEqual(controller.observe(boxes: [], frameID: 11, capturedAt: 101.1, now: 101.1), .hold)
        XCTAssertFalse(controller.hasConfirmedTarget)
    }

    func testStaleFrameRevokesConfirmationAndResetClearsReference() {
        var controller = FollowController()
        let box = TrackingBox(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        for frame in 1...3 {
            let now = 100 + Double(frame) / 10
            _ = controller.observe(boxes: [box], frameID: UInt64(frame), capturedAt: now, now: now)
        }
        XCTAssertTrue(controller.hasConfirmedTarget)
        XCTAssertEqual(controller.observe(boxes: [box], frameID: 4, capturedAt: 100.4, now: 101), .hold)
        XCTAssertFalse(controller.hasConfirmedTarget)
        controller.reset()
        XCTAssertNil(controller.trackingReference)
    }

    func testOriginalHardwareHoldPacket() {
        XCTAssertEqual(FollowCommand.hold.encodedD1Packet(), Data([0x55, 0x55, 0x07, 0xd1, 0x01, 0x27, 0x10, 0x27, 0x10, 0xdb]))
    }
}
