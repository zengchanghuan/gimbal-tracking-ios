// Tracking-only excerpts. Host transport implementation is required.
// Original source: Created by Kevin Tan on 2024/5/25.
import Foundation

struct PhysicalObjectTrackingWriteContext: Equatable {
    let sessionID: UUID
    let controlID: UUID
    let expiresAt: TimeInterval
    var frameID: UInt64? = nil
    var controlLease: ObjectTrackingControlLease? = nil
}

enum TrackingState: UInt8 {
    case none = 0           // 无跟踪
    case normal = 1         // 正常跟踪
    case reCapture = 2      // 重新捕捉
    case targetLost = 3     // 目标丢失
    case exit = 4           // 退出跟踪
    
    var description: String {
        switch self {
        case .none:
            return "无跟踪"
        case .normal:
            return "正常跟踪"
        case .reCapture:
            return "重新捕捉"
        case .targetLost:
            return "目标丢失"
        case .exit:
            return "退出跟踪"
        }
    }
}

enum BleCommand: UInt8 { case tracking = 0xd1 }

class ProtocolParser {
    static let shared = ProtocolParser()
    private var lastTrackingSendTime: Int64 = 0
private func calculateCRC(data: [UInt8], length: Int) -> UInt8 {
        let width = 8
        let topbit = 1 << (width - 1)
        let polynomial: UInt8 = 0x8d
        
        var crc: UInt8 = 0
        for i in 0..<length {
            crc ^= data[i]
            for _ in 0..<8 {
                if (crc & UInt8(topbit)) != 0 {
                    crc = (crc << 1) ^ polynomial
                } else {
                    crc = crc << 1
                }
            }
        }
        return crc
    }
private func getBaseData(length: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: length)
        data[0] = 0x55  // header
        data[1] = 0x55  // header
        return data
    }
func setTracking(centerX: Int,
                     centerY: Int,
                     state: UInt8,
                     isFront: Bool,
                     scale: Int = 3,
                     physicalObjectContext: PhysicalObjectTrackingWriteContext? = nil) {
        let appliedScale = max(1, scale)
        // 根据V1.0.3协议：偏移量范围是10000加/减300
        var adjustedCenterX: Int
        var adjustedCenterY: Int
        
        // 对齐 Android BleDataUtils.java 逻辑：
        if isFront {
            adjustedCenterX = 10000 + centerX / appliedScale
            adjustedCenterY = 10000 + centerY / appliedScale
        } else {
            adjustedCenterX = 10000 - centerX / appliedScale
            adjustedCenterY = 10000 - centerY / appliedScale
        }
        if physicalObjectContext != nil {
            adjustedCenterX = min(10300, max(9700, adjustedCenterX))
            adjustedCenterY = min(10300, max(9700, adjustedCenterY))
        }
        
        var data = getBaseData(length: 10)
        data[2] = 7  // length
        data[3] = BleCommand.tracking.rawValue  // 0xd1
        data[4] = state  // 跟踪状态
        data[5] = UInt8((adjustedCenterX >> 8) & 0xff) // 水平方向偏移量高位
        data[6] = UInt8(adjustedCenterX & 0xff)        // 水平方向偏移量低位
        data[7] = UInt8((adjustedCenterY >> 8) & 0xff) // 垂直方向偏移量高位
        data[8] = UInt8(adjustedCenterY & 0xff)        // 垂直方向偏移量低位
        
        // 添加CRC校验
        data[9] = calculateCRC(data: data, length: 9)

        if let physicalObjectContext {
            // Object tracking owns its frame cadence and transport coalescing.
            // A hold/exit must never disappear in the legacy normal-D1 throttle.
            KKBLEManager.shared.writePhysicalObjectTracking(Data(data), context: physicalObjectContext)
            return
        }
        
        // 控制发送频率：对齐 Android 端 (50ms≈20Hz)
        let currentTime = Int64(Date().timeIntervalSince1970 * 1000)
        if currentTime - lastTrackingSendTime > 50 || state == 4 {
            lastTrackingSendTime = currentTime
            
            // ⚠️ 深度优化：对于高频跟踪指令(state=1)，使用 writeWithoutResponse 极大提升实时性
            // 只有退出指令(state=4)才使用 withResponse 确保成功
            if state == 4 {
                KKBLEManager.shared.writeData(Data(data), type: .withResponse)
            } else {
                KKBLEManager.shared.writeData(Data(data), type: .withoutResponse)
            }
        }
    }
}
