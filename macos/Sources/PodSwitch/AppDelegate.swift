import AppKit
import IOBluetooth
import PodSwitchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let settings = Settings()
    private let bluetooth = BluetoothConnector()
    private let notifier = NotificationManager()
    private let monitor = AudioMonitor()
    private var coordinator: Coordinator!
    private var peerServer: PeerSwitchServer!
    private var peerFields: [Int: NSTextField] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = Coordinator(monitor: monitor, bluetooth: bluetooth, notifier: notifier, settings: settings)
        peerServer = PeerSwitchServer(tokenProvider: { [weak settings] in
            settings?.peerSettings.token ?? ""
        }) { [weak self] in
            guard let self, let target = self.settings.config.targetDeviceId else { return false }
            return await self.bluetooth.disconnectAndWait(deviceId: target)
        }
        peerServer.onStateChange = { [weak self] in self?.rebuildMenu() }
        refreshPeerServer()
        notifier.onAccept = { [weak self] in self?.coordinator.handle(.userAcceptedSwitch) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarImage()
        coordinator.start()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        peerServer?.stop()
    }

    private static func menuBarImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "PodSwitch")
        image?.isTemplate = true
        return image
    }

    private func rebuildMenu() {
        let config = settings.config
        let menu = NSMenu()
        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = config.enabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(.separator())

        for (title, mode, selector) in [
            ("Steal (switch automatically)", Mode.steal, #selector(selectSteal)),
            ("Ask (notify me first)", Mode.ask, #selector(selectAsk))
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.state = config.mode == mode ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let submenu = NSMenu()
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        if devices.isEmpty {
            let empty = NSMenuItem(title: "No paired devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for device in devices {
                let name = device.name ?? device.addressString ?? "Unknown"
                let item = NSMenuItem(title: name, action: #selector(selectDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                item.state = device.addressString == config.targetDeviceId ? .on : .off
                submenu.addItem(item)
            }
        }
        let deviceItem = NSMenuItem(
            title: settings.targetDeviceName.map { "Target: \($0)" } ?? "Choose device…",
            action: nil,
            keyEquivalent: ""
        )
        deviceItem.submenu = submenu
        menu.addItem(deviceItem)
        menu.addItem(.separator())

        let peerItem = NSMenuItem(title: "Cross-device settings…", action: #selector(showPeerSettings), keyEquivalent: "")
        peerItem.target = self
        menu.addItem(peerItem)
        let peerStatus = NSMenuItem(
            title: peerServer.isRunning ? "Peer service: listening" : "Peer service: unavailable",
            action: nil,
            keyEquivalent: ""
        )
        peerStatus.isEnabled = false
        menu.addItem(peerStatus)

        let quit = NSMenuItem(title: "Quit PodSwitch", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        var config = settings.config
        config.enabled.toggle()
        settings.config = config
        rebuildMenu()
    }

    @objc private func selectSteal() {
        var config = settings.config
        config.mode = .steal
        settings.config = config
        rebuildMenu()
    }

    @objc private func selectAsk() {
        var config = settings.config
        config.mode = .ask
        settings.config = config
        rebuildMenu()
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? IOBluetoothDevice,
              let address = device.addressString else { return }
        settings.setTargetDevice(address: address, name: device.name ?? address)
        rebuildMenu()
    }

    @objc private func pastePeerField(_ sender: NSButton) {
        guard let field = peerFields[sender.tag],
              let value = NSPasteboard.general.string(forType: .string) else { return }
        field.stringValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func generatePeerToken() {
        guard let field = peerFields[3] else { return }
        let bytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        field.stringValue = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @objc private func copyPeerToken() {
        guard let field = peerFields[3], !field.stringValue.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(field.stringValue, forType: .string)
    }

    @objc private func showPeerSettings() {
        let current = settings.peerSettings
        let alert = NSAlert()
        alert.messageText = "Cross-device switching"
        alert.informativeText = "Enable MagicDNS in Tailscale Admin → DNS. Enter the other computer's full .ts.net name. Both computers can generate a token; use exactly the same value on both. Port 8765 is the default."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Test connection")
        alert.addButton(withTitle: "Cancel")

        let enabled = NSButton(checkboxWithTitle: "Enable Tailscale switching", target: nil, action: nil)
        enabled.state = current.enabled ? .on : .off

        let hostLabel = NSTextField(labelWithString: "Peer MagicDNS")
        let host = NSTextField(string: current.host)
        host.placeholderString = "windows-pc.example.ts.net"
        let hostPaste = NSButton(title: "Paste", target: self, action: #selector(pastePeerField(_:)))
        hostPaste.tag = 1

        let portLabel = NSTextField(labelWithString: "HTTP port")
        let port = NSTextField(string: String(current.port))
        let portPaste = NSButton(title: "Paste", target: self, action: #selector(pastePeerField(_:)))
        portPaste.tag = 2

        let tokenLabel = NSTextField(labelWithString: "Shared token")
        let token = NSSecureTextField(string: current.token)
        token.placeholderString = "Same shared token on both computers"
        let tokenPaste = NSButton(title: "Paste", target: self, action: #selector(pastePeerField(_:)))
        tokenPaste.tag = 3
        let generate = NSButton(title: "Generate", target: self, action: #selector(generatePeerToken))
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyPeerToken))

        peerFields = [1: host, 2: port, 3: token]
        let hostRow = NSStackView(views: [host, hostPaste])
        let portRow = NSStackView(views: [port, portPaste])
        let tokenRow = NSStackView(views: [token, tokenPaste, generate, copy])
        for row in [hostRow, portRow, tokenRow] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
        }
        host.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        token.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true

        let stack = NSStackView(views: [
            enabled, hostLabel, hostRow, portLabel, portRow, tokenLabel, tokenRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setFrameSize(NSSize(width: 430, height: 230))
        alert.accessoryView = stack

        let response = alert.runModal()
        let rawPort = UInt16(port.stringValue) ?? 8765
        let parsedPort = rawPort == 0 ? 8765 : rawPort
        if response == .alertFirstButtonReturn || response == .alertSecondButtonReturn {
            settings.peerSettings = PeerSettings(
                enabled: enabled.state == .on,
                host: host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                port: parsedPort,
                token: token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            refreshPeerServer()
        }
        peerFields.removeAll()

        if response == .alertSecondButtonReturn {
            let peer = settings.peerSettings
            Task { @MainActor in
                let result = await PeerSwitchClient().diagnose(host: peer.host, port: peer.port, token: peer.token)
                let alert = NSAlert()
                alert.messageText = result.isSuccess ? "Connection successful" : "Connection test failed"
                alert.informativeText = result.message
                alert.runModal()
            }
        }
        rebuildMenu()
    }

    private func refreshPeerServer() {
        let peer = settings.peerSettings
        if peer.enabled && !peer.token.isEmpty {
            peerServer.start(port: peer.port)
        } else {
            peerServer.stop()
        }
    }

    @objc private func quit() {
        coordinator.stop()
        peerServer.stop()
        NSApplication.shared.terminate(nil)
    }
}