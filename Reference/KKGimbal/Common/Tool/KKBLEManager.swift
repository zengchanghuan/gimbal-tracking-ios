// Tracking session and queued-write excerpts; host BLE serializer is required.
import Foundation
import CoreBluetooth

class KKBLEManager {
    // Screen-follow commands use this existing connection and withResponse serializer.
    // No second central, no reconnect, and no stale motion after an ATT backlog.
    private var screenFollowSession: UUID?
    private var screenFollowPeripheral: UUID?
    var screenFollowWriteEvent: ((UUID, Data, String) -> Void)?

    func beginScreenFollowSession(_ id: UUID, peripheralID: UUID) -> Bool {
        precondition(Thread.isMainThread)
        expirePhysicalObjectStopIfNeeded()
        guard screenFollowSession == nil, physicalObjectTrackingSession == nil, !isFirmwareUpdateTransportIsolated,
              !FirmwareUpdateManager.mUpdating, isCommandChannelReady,
              connectedPeripheral?.identifier == peripheralID else { return false }
        screenFollowSession = id; screenFollowPeripheral = peripheralID
        clearPendingTrackingWrites()
        return true
    }

    private func clearPendingTrackingWrites() {
        let discarded = [pendingLatestD1WithResponse, pendingPhysicalObjectStop].compactMap { $0 }
            + pendingWithResponseQueue.filter { $0.physicalObjectContext != nil }
        pendingWriteWithoutResponseQueue.removeAll(where: { isTrackingD1Packet($0) })
        pendingLatestD1WithResponse = nil
        pendingPhysicalObjectStop = nil
        pendingWithResponseQueue.removeAll(where: { isTrackingD1Packet($0.data) })
        for write in discarded { reportPhysicalObjectWrite(write, event: "discarded") }
    }

    func writeScreenFollow(_ command: ScreenFollowCommand, sessionID: UUID, expiresAt: TimeInterval) {
        precondition(Thread.isMainThread)
        guard screenFollowSession == sessionID, isCommandChannelReady,
              !isFirmwareUpdateTransportIsolated,
              let peripheral = connectedPeripheral, peripheral.identifier == screenFollowPeripheral,
              let characteristic = writeCharacteristic else { return }
        let data = GimbalTrackingPacket.encode(command)
        guard expiresAt.isFinite, expiresAt >= ProcessInfo.processInfo.systemUptime else {
            screenFollowWriteEvent?(sessionID, data, "expired"); return
        }
        // Prefer the existing reliable serialized path. The latest unsent frame replaces the previous one.
        if supportsWriteWithResponse(characteristic) {
            pendingLatestD1WithResponse = WithResponseWrite(data: data, logPrefix: "ble发送(直播跟随)",
                isFirmwareUpdateData: false, firmwareTransportGeneration: nil,
                screenFollowSession: sessionID, expiresAt: expiresAt)
            drainWithResponseQueueIfPossible(peripheral: peripheral, characteristic: characteristic)
        } else if characteristic.properties.contains(.writeWithoutResponse), peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            screenFollowWriteEvent?(sessionID, data, "sent")
        }
        // A blocked withoutResponse-only peripheral drops this frame; it never queues old motion.
    }

    func endScreenFollowSession(_ id: UUID) {
        precondition(Thread.isMainThread)
        guard screenFollowSession == id else { return }
        clearPendingTrackingWrites()
        screenFollowSession = nil
        let peripheralID = screenFollowPeripheral; screenFollowPeripheral = nil
        guard !isFirmwareUpdateTransportIsolated, isCommandChannelReady,
              let peripheral = connectedPeripheral, peripheral.identifier == peripheralID,
              let characteristic = writeCharacteristic else { return }
        let exit = GimbalTrackingPacket.encode(exit: true)
        if supportsWriteWithResponse(characteristic) {
            pendingWithResponseQueue.insert(WithResponseWrite(data: exit, logPrefix: "ble发送(结束直播跟随)",
                isFirmwareUpdateData: false, firmwareTransportGeneration: nil), at: 0)
            drainWithResponseQueueIfPossible(peripheral: peripheral, characteristic: characteristic)
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            enqueueWriteWithoutResponse(exit)
            drainWriteWithoutResponseQueueIfPossible(peripheral: peripheral, characteristic: characteristic)
        }
    }

    // MARK: - Physical object tracking transport
    // Main-queue ownership is separate from screen following and legacy D1.
    // Recognition may run without BLE; acquiring this lease requires ready BLE.
    private var physicalObjectTrackingSession: UUID?
    private var physicalObjectTrackingControlID: UUID?
    private var physicalObjectTrackingPeripheral: UUID?
    private var physicalObjectTrackingAcceptsMotion = false
    private var physicalObjectTrackingEnding = false
    private var physicalObjectTrackingLastFrameID: UInt64?
    private var pendingPhysicalObjectStop: WithResponseWrite?
    var physicalObjectTrackingWriteEvent: ((PhysicalObjectTrackingWriteContext, Data, String) -> Void)?

    @discardableResult
    func beginPhysicalObjectTrackingSession(sessionID: UUID) -> Bool {
        precondition(Thread.isMainThread)
        expirePhysicalObjectStopIfNeeded()
        guard physicalObjectTrackingSession == nil, screenFollowSession == nil,
              !isFirmwareUpdateTransportIsolated, !FirmwareUpdateManager.mUpdating,
              isCommandChannelReady, let peripheral = connectedPeripheral else { return false }
        clearPendingTrackingWrites()
        physicalObjectTrackingSession = sessionID
        physicalObjectTrackingPeripheral = peripheral.identifier
        physicalObjectTrackingControlID = nil
        physicalObjectTrackingAcceptsMotion = false
        physicalObjectTrackingEnding = false
        physicalObjectTrackingLastFrameID = nil
        return true
    }

    @discardableResult
    func updatePhysicalObjectTrackingTarget(sessionID: UUID, controlID: UUID) -> Bool {
        precondition(Thread.isMainThread)
        guard physicalObjectTrackingSession == sessionID, !physicalObjectTrackingEnding,
              isCommandChannelReady,
              connectedPeripheral?.identifier == physicalObjectTrackingPeripheral else { return false }
        // A paused target cannot be resurrected by a delayed update. Reacquire
        // with a new token, including after a hold/loss or a backend switch.
        if physicalObjectTrackingControlID == controlID { return physicalObjectTrackingAcceptsMotion }
        clearPendingTrackingWrites()
        physicalObjectTrackingControlID = controlID
        physicalObjectTrackingAcceptsMotion = true
        physicalObjectTrackingLastFrameID = nil
        // A target handoff starts from a stop on the new token. A fresh motion
        // may queue behind it but cannot replace this priority barrier.
        let context = PhysicalObjectTrackingWriteContext(sessionID: sessionID, controlID: controlID,
            expiresAt: ProcessInfo.processInfo.systemUptime + 0.5)
        enqueuePhysicalObjectWrite(GimbalTrackingPacket.encode(.hold), context: context, priorityStop: true)
        return true
    }

    func holdPhysicalObjectTracking(sessionID: UUID, controlID: UUID, frameID: UInt64? = nil) {
        precondition(Thread.isMainThread)
        guard physicalObjectTrackingSession == sessionID,
              physicalObjectTrackingControlID == controlID, !physicalObjectTrackingEnding else { return }
        physicalObjectTrackingAcceptsMotion = false
        clearPendingTrackingWrites()
        let context = PhysicalObjectTrackingWriteContext(sessionID: sessionID, controlID: controlID,
            expiresAt: ProcessInfo.processInfo.systemUptime + 0.5, frameID: frameID)
        enqueuePhysicalObjectWrite(GimbalTrackingPacket.encode(.hold), context: context, priorityStop: true)
    }

    func endPhysicalObjectTrackingSession(sessionID: UUID) {
        precondition(Thread.isMainThread)
        guard physicalObjectTrackingSession == sessionID, !physicalObjectTrackingEnding else { return }
        physicalObjectTrackingAcceptsMotion = false
        physicalObjectTrackingEnding = true
        clearPendingTrackingWrites()
        let controlID = physicalObjectTrackingControlID ?? UUID()
        physicalObjectTrackingControlID = controlID
        let context = PhysicalObjectTrackingWriteContext(sessionID: sessionID, controlID: controlID,
            expiresAt: ProcessInfo.processInfo.systemUptime + 0.5)
        // Keep the lease until exit is submitted or expires. A late old callback
        // must never release a newer session that already owns this connection.
        enqueuePhysicalObjectWrite(GimbalTrackingPacket.encode(exit: true), context: context, priorityStop: true)
    }

    func writePhysicalObjectTracking(_ data: Data, context: PhysicalObjectTrackingWriteContext) {
        let submit = { [weak self] in
            guard let self else { return }
            guard data.count == 10, self.isTrackingD1Packet(data), data[4] == 1 || data[4] == 4 else {
                self.physicalObjectTrackingWriteEvent?(context, data, "discarded"); return
            }
            let stop = self.isPhysicalObjectStopPacket(data)
            if let reason = self.physicalObjectWriteRejection(context, data: data) {
                self.physicalObjectTrackingWriteEvent?(context, data, reason); return
            }
            if let frameID = context.frameID {
                guard self.physicalObjectTrackingLastFrameID.map({ frameID > $0 }) ?? true else {
                    self.physicalObjectTrackingWriteEvent?(context, data, "discarded"); return
                }
                self.physicalObjectTrackingLastFrameID = frameID
            }
            if data[4] == 4 {
                self.physicalObjectTrackingEnding = true
                self.physicalObjectTrackingAcceptsMotion = false
            }
            if stop { self.clearPendingTrackingWrites() }
            self.enqueuePhysicalObjectWrite(data, context: context, priorityStop: stop)
        }
        if Thread.isMainThread { submit() } else { DispatchQueue.main.async(execute: submit) }
    }

    private func isPhysicalObjectStopPacket(_ data: Data) -> Bool {
        guard data.count == 10, isTrackingD1Packet(data) else { return false }
        return data[4] == 4 || (data[5] == 0x27 && data[6] == 0x10 && data[7] == 0x27 && data[8] == 0x10)
    }

    private func physicalObjectWriteRejection(_ context: PhysicalObjectTrackingWriteContext, data: Data) -> String? {
        guard context.sessionID == physicalObjectTrackingSession,
              context.controlID == physicalObjectTrackingControlID,
              connectedPeripheral?.identifier == physicalObjectTrackingPeripheral,
              isCommandChannelReady, screenFollowSession == nil,
              !isFirmwareUpdateTransportIsolated, !FirmwareUpdateManager.mUpdating else { return "discarded" }
        guard context.expiresAt.isFinite, context.expiresAt >= ProcessInfo.processInfo.systemUptime else { return "expired" }
        if physicalObjectTrackingEnding && data[4] != 4 { return "discarded" }
        if !physicalObjectTrackingAcceptsMotion && !isPhysicalObjectStopPacket(data) { return "discarded" }
        if !isPhysicalObjectStopPacket(data) {
            guard let lease = context.controlLease else { return "missing_control_lease" }
            guard lease.isValid(sessionID: context.sessionID, controlID: context.controlID,
                                expiresAt: context.expiresAt) else { return "authorization_revoked" }
        }
        return nil
    }

    /// The lease transaction encloses only the CoreBluetooth submission. Keep
    /// logging/delegates outside: they can re-enter the Coordinator lock.
    /// A hold/exit keeps the existing session/transport/expiry gates but never
    /// needs motion authorization, so revocation cannot prevent a safety stop.
    private func commitPhysicalObjectWrite(_ data: Data, context: PhysicalObjectTrackingWriteContext,
                                           peripheral: CBPeripheral, characteristic: CBCharacteristic,
                                           type: CBCharacteristicWriteType) -> Bool {
        if isPhysicalObjectStopPacket(data) {
            peripheral.writeValue(data, for: characteristic, type: type)
            return true
        }
        guard let lease = context.controlLease else { return false }
        return lease.withValidAuthorization(sessionID: context.sessionID, controlID: context.controlID,
                                             expiresAt: context.expiresAt) {
            peripheral.writeValue(data, for: characteristic, type: type)
        }
    }

    private func enqueuePhysicalObjectWrite(_ data: Data, context: PhysicalObjectTrackingWriteContext, priorityStop: Bool) {
        let write = WithResponseWrite(data: data, logPrefix: "ble发送(实物跟踪)",
            isFirmwareUpdateData: false, firmwareTransportGeneration: nil, physicalObjectContext: context)
        guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic,
              physicalObjectWriteRejection(context, data: data) == nil else {
            let reason = physicalObjectWriteRejection(context, data: data) ?? "discarded"
            finishPhysicalObjectWrite(write)
            reportPhysicalObjectWrite(write, event: reason)
            return
        }
        if priorityStop {
            let previous = pendingPhysicalObjectStop
            pendingPhysicalObjectStop = write
            if let previous { reportPhysicalObjectWrite(previous, event: "discarded") }
        } else if supportsWriteWithResponse(characteristic) {
            let previous = pendingLatestD1WithResponse
            pendingLatestD1WithResponse = write
            if let previous { reportPhysicalObjectWrite(previous, event: "discarded") }
        } else if characteristic.properties.contains(.writeWithoutResponse), peripheral.canSendWriteWithoutResponse {
            // A stop left from a blocked callback always precedes fresh motion.
            drainPhysicalObjectStopWithoutResponse(peripheral: peripheral, characteristic: characteristic)
            guard pendingPhysicalObjectStop == nil, peripheral.canSendWriteWithoutResponse else {
                reportPhysicalObjectWrite(write, event: "discarded"); return
            }
            if let reason = physicalObjectWriteRejection(context, data: data) {
                reportPhysicalObjectWrite(write, event: reason); return
            }
            guard commitPhysicalObjectWrite(data, context: context, peripheral: peripheral,
                                            characteristic: characteristic, type: .withoutResponse) else {
                reportPhysicalObjectWrite(write, event: physicalObjectWriteRejection(context, data: data) ?? "authorization_revoked")
                return
            }
            reportPhysicalObjectWrite(write, event: "actual_write")
            return
        } else {
            // Motion never waits for withoutResponse readiness and never loses
            // its token by entering the legacy untagged Data queue.
            reportPhysicalObjectWrite(write, event: "discarded")
            return
        }
        if supportsWriteWithResponse(characteristic) {
            drainWithResponseQueueIfPossible(peripheral: peripheral, characteristic: characteristic)
        } else {
            drainPhysicalObjectStopWithoutResponse(peripheral: peripheral, characteristic: characteristic)
        }
    }

    private func drainPhysicalObjectStopWithoutResponse(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        expirePhysicalObjectStopIfNeeded()
        guard !supportsWriteWithResponse(characteristic), characteristic.properties.contains(.writeWithoutResponse),
              peripheral.canSendWriteWithoutResponse, let stop = pendingPhysicalObjectStop else { return }
        pendingPhysicalObjectStop = nil
        if let context = stop.physicalObjectContext,
           let reason = physicalObjectWriteRejection(context, data: stop.data) {
            finishPhysicalObjectWrite(stop)
            reportPhysicalObjectWrite(stop, event: reason)
            return
        }
        peripheral.writeValue(stop.data, for: characteristic, type: .withoutResponse)
        finishPhysicalObjectWrite(stop)
        reportPhysicalObjectWrite(stop, event: "actual_write")
    }

    private func expirePhysicalObjectStopIfNeeded() {
        guard let stop = pendingPhysicalObjectStop, let context = stop.physicalObjectContext,
              !context.expiresAt.isFinite || context.expiresAt < ProcessInfo.processInfo.systemUptime else { return }
        pendingPhysicalObjectStop = nil
        finishPhysicalObjectWrite(stop)
        reportPhysicalObjectWrite(stop, event: "expired")
    }

    private func finishPhysicalObjectWrite(_ write: WithResponseWrite) {
        guard let context = write.physicalObjectContext, write.data.count > 4, write.data[4] == 4,
              physicalObjectTrackingEnding, physicalObjectTrackingSession == context.sessionID,
              physicalObjectTrackingControlID == context.controlID else { return }
        physicalObjectTrackingSession = nil
        physicalObjectTrackingControlID = nil
        physicalObjectTrackingPeripheral = nil
        physicalObjectTrackingAcceptsMotion = false
        physicalObjectTrackingEnding = false
        physicalObjectTrackingLastFrameID = nil
    }

    private func reportPhysicalObjectWrite(_ write: WithResponseWrite, event: String) {
        guard let context = write.physicalObjectContext else { return }
        physicalObjectTrackingWriteEvent?(context, write.data, event)
    }

    private func invalidatePhysicalObjectTrackingTransport() {
        guard physicalObjectTrackingSession != nil else { return }
        physicalObjectTrackingSession = nil
        physicalObjectTrackingControlID = nil
        physicalObjectTrackingPeripheral = nil
        physicalObjectTrackingAcceptsMotion = false
        physicalObjectTrackingEnding = false
        physicalObjectTrackingLastFrameID = nil
        clearPendingTrackingWrites()
    }

}
