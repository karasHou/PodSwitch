import Foundation
import CoreAudio
import IOBluetooth
import IOKit
import os

/// IOBluetooth-backed connector. Device IDs are Bluetooth addresses.
public struct BluetoothConnector: BluetoothHandoff {
    private static let maxAttempts = 2
    private static let attemptTimeout: TimeInterval = 8
    private static let pollInterval: TimeInterval = 0.4
    private static let log = Logger(subsystem: "com.podswitch.core", category: "BluetoothConnector")

    public init() {}

    public func isPaired(deviceId: String) -> Bool {
        pairedDevice(matching: deviceId) != nil
    }

    /// Compatibility entry point used by the original single-device flow.
    public func connect(deviceId: String) {
        Task { _ = await connectAndWait(deviceId: deviceId) }
    }

    /// Disconnects the paired device and waits until the Bluetooth stack reports it disconnected.
    public func disconnectAndWait(deviceId: String) async -> Bool {
        guard let device = pairedDevice(matching: deviceId) else { return false }
        guard device.isConnected() else { return true }

        let result = device.closeConnection()
        guard result == kIOReturnSuccess else {
            Self.log.error("closeConnection failed: \(result)")
            return false
        }

        for _ in 0..<32 {
            if !device.isConnected() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return !device.isConnected()
    }

    /// Opens the connection and waits for the target to become the active audio output.
    public func connectAndWait(deviceId: String) async -> Bool {
        guard let device = pairedDevice(matching: deviceId) else { return false }
        if device.isConnected() && isActiveOutput(deviceId: deviceId) { return true }

        for attempt in 1...Self.maxAttempts {
            if !device.isConnected() {
                let result = device.openConnection()
                if result != kIOReturnSuccess {
                    Self.log.error("openConnection failed on attempt \(attempt): \(result)")
                }
            }

            let checks = Int(Self.attemptTimeout / Self.pollInterval)
            for _ in 0..<checks {
                if isActiveOutput(deviceId: deviceId) { return true }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        return isActiveOutput(deviceId: deviceId)
    }

    public func isActiveOutput(deviceId: String) -> Bool {
        guard let device = pairedDevice(matching: deviceId),
              let targetName = device.name, !targetName.isEmpty,
              let outputName = currentDefaultOutputName() else { return false }
        return outputName.localizedCaseInsensitiveContains(targetName)
            || targetName.localizedCaseInsensitiveContains(outputName)
    }

    private func pairedDevice(matching deviceId: String) -> IOBluetoothDevice? {
        let target = normalize(deviceId)
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return nil }
        return devices.first { device in
            guard let address = device.addressString else { return false }
            return normalize(address) == target
        }
    }

    private func normalize(_ address: String) -> String {
        address.lowercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func currentDefaultOutputName() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &size, &deviceID
        ) == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString?
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, pointer)
        }
        return status == noErr ? name as String? : nil
    }
}