import Foundation
import os

/// Routes audio events through a guarded local or cross-device hand-off.
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
        let status = currentStatus(for: config)
        execute(SwitchEngine.decide(event: event, config: config, status: status), config: config)
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
        guard !switchInProgress, let target = config.targetDeviceId else { return }
        switchInProgress = true
        notificationPending = false
        let peerSettings = (settings as? any PeerSettingsProviding)?.peerSettings ?? PeerSettings()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.switchInProgress = false }

            if peerSettings.enabled {
                guard !peerSettings.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !peerSettings.token.isEmpty else {
                    self.showFailure("请先配置对端 MagicDNS 和共享 Token")
                    return
                }
                let released = await self.peer.releasePeer(
                    host: peerSettings.host,
                    port: peerSettings.port,
                    token: peerSettings.token
                )
                guard released else {
                    self.showFailure("对端未确认断开 XM3，本次切换已取消")
                    return
                }
            }

            if let handoff = self.bluetooth as? any BluetoothHandoff {
                let connected = await handoff.connectAndWait(deviceId: target)
                if !connected { self.showFailure("XM3 连接失败，请检查蓝牙状态") }
            } else {
                self.bluetooth.connect(deviceId: target)
            }
        }
    }

    private func showFailure(_ message: String) {
        (notifier as? any SwitchFailureNotifying)?.showSwitchFailure(message)
        Self.log.error("\(message, privacy: .public)")
    }
}