import Foundation
import GimbalTracking

// Deterministic controller replay. No camera, network or motor commands are sent.
var controller = FollowController()
for frame in 1...24 {
    let now = 100 + Double(frame) / 15
    let boxes: [TrackingBox] = frame < 20
        ? [TrackingBox(CGRect(x: 0.65, y: 0.4, width: 0.2, height: 0.2))] : []
    if let command = controller.observe(boxes: boxes, frameID: UInt64(frame),
                                        capturedAt: now, now: now) {
        print("frame=\(frame) confirmed=\(controller.hasConfirmedTarget) yaw=\(command.yaw) pitch=\(command.pitch)")
    }
}
