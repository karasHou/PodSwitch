import Foundation
import os

@MainActor
public final class Coordinator: AudioMonitorDelegate {
    private let monitor: any AudioMonitoring
    private let bluetooth: any BluetoothConnecting
    private let peer: any PeerSwitching
    private let notifier: any Notifying
    private let settings: any SettingsStore
    private var switchInProgress = false

    public private(set) var notificationPending = false
    private static let log = Logger(subsystem: "com.podswitch.core", category: "Coordinator")

    public init(
        monitor: any AudioMonitoring,
        bluetooth: any BluetoothConnecting,
        peer: any PeerSwitching = PeerSwitchClient(),
        notifier: any Notifying,
        settings: any SettingsStore
    ) {
        self.monitor = monitor
        self.bluetooth = bluetooth
        self.peer = peer
        self.notifier = notifier
        self.settings = settings
        self.monitor.delegate = self
    }

    public func start() { monitor.start() }
    public func stop() { monitor.stop() }

    public func handle(_ event: SwitchEvent) {
        let config = settings.config
        let peerSettings = (settings as? any PeerSettingsProviding)?.peerSettings ?? PeerSettings()
        var decisionConfig = config

        // Cross-device mode is always automatic on macOS; audio events stay silent.
        if peerSettings.enabled, case .audioStarted = event {
            decisionConfig.mode = .steal
        }

        let status = currentStatus(for: decisionConfig)
        execute(SwitchEngine.decide(event: event, config: decisionConfig, status: status), config: config)
    }

    public func audioMonitor(_ monitor: any AudioMonitoring, didEmit event: SwitchEvent) {
        handle(event)
    }

    private func currentStatus(for config: Config) -> DeviceStatus {
        guard let target = config.targetDeviceId else {
            return DeviceStatus(targetPaired: false, targetActiveOutput: false, notificationPending: notificationPending)
        }
        return DeviceStatus(
            targetPaired: bluetooth.isPaired(deviceId: target),
            targetActiveOutput: bluetooth.isActiveOutput(deviceId: target),
            notificationPending: notificationPending
        )
    }

    private func execute(_ action: SwitchAction, config: Config) {
        switch action {
        case .none:
            break
        case .connect:
            performConnect(config: config)
        case .notify:
            notificationPending = true
            notifier.showSwitchPrompt()
        }
    }

    private func performConnect(config: Config) {
        guard let target = config.targetDeviceId else { return }
        notificationPending = false
        let peerSettings = (settings as? any PeerSettingsProviding)?.peerSettings ?? PeerSettings()
        guard peerSettings.enabled else {
            bluetooth.connect(deviceId: target)
            return
        }
        guard !switchInProgress else { return }
        switchInProgress = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.switchInProgress = false }

            guard !peerSettings.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.logFailure("Cross-device switch skipped: peer MagicDNS is empty")
                return
            }

            let released = await self.peer.releasePeer(host: peerSettings.host, port: peerSettings.port)
            guard released else {
                self.logFailure("Cross-device switch skipped: peer release was not confirmed")
                return
            }

            if let handoff = self.bluetooth as? any BluetoothHandoff {
                let connected = await handoff.connectAndWait(deviceId: target)
                if !connected { self.logFailure("Local XM3 connection failed after peer release") }
            } else {
                self.bluetooth.connect(deviceId: target)
            }
        }
    }

    private func logFailure(_ message: String) {
        Self.log.error("\(message, privacy: .public)")
    }
}
