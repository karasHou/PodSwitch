import Foundation

@MainActor
public protocol AudioMonitorDelegate: AnyObject {
    func audioMonitor(_ monitor: any AudioMonitoring, didEmit event: SwitchEvent)
}

@MainActor
public protocol AudioMonitoring: AnyObject {
    var delegate: AudioMonitorDelegate? { get set }
    func start()
    func stop()
}

public protocol BluetoothConnecting: Sendable {
    func isActiveOutput(deviceId: String) -> Bool
    func isPaired(deviceId: String) -> Bool
    func connect(deviceId: String)
}

public protocol BluetoothHandoff: BluetoothConnecting {
    func disconnectAndWait(deviceId: String) async -> Bool
    func connectAndWait(deviceId: String) async -> Bool
}

public protocol PeerSwitching: Sendable {
    func releasePeer(host: String, port: UInt16) async -> Bool
    func checkPeer(host: String, port: UInt16) async -> Bool
}

@MainActor
public protocol PeerSettingsProviding: AnyObject {
    var peerSettings: PeerSettings { get set }
}

@MainActor
public protocol Notifying: AnyObject {
    func showSwitchPrompt()
}

@MainActor
public protocol SwitchFailureNotifying: AnyObject {
    func showSwitchFailure(_ message: String)
}

@MainActor
public protocol SettingsStore: AnyObject {
    var config: Config { get set }
}
