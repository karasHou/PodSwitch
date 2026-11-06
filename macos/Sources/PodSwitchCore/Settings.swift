import Foundation

/// UserDefaults-backed implementation of local and peer settings.
@MainActor
public final class Settings: SettingsStore, PeerSettingsProviding {
    private enum Key {
        static let enabled = "podswitch.enabled"
        static let mode = "podswitch.mode"
        static let address = "podswitch.target.address"
        static let name = "podswitch.target.name"
        static let peerEnabled = "podswitch.peer.enabled"
        static let peerHost = "podswitch.peer.host"
        static let peerPort = "podswitch.peer.port"
        static let peerToken = "podswitch.peer.token"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Key.enabled) == nil {
            defaults.set(true, forKey: Key.enabled)
        }
    }

    public var targetDeviceName: String? {
        get { defaults.string(forKey: Key.name) }
        set { defaults.set(newValue, forKey: Key.name) }
    }

    public var config: Config {
        get {
            let enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
            let mode = (defaults.string(forKey: Key.mode)).flatMap(Mode.init(rawValue:)) ?? .ask
            return Config(enabled: enabled, mode: mode, enabledCategories: [.media], targetDeviceId: defaults.string(forKey: Key.address))
        }
        set {
            defaults.set(newValue.enabled, forKey: Key.enabled)
            defaults.set(newValue.mode.rawValue, forKey: Key.mode)
            if let address = newValue.targetDeviceId {
                defaults.set(address, forKey: Key.address)
            } else {
                defaults.removeObject(forKey: Key.address)
                defaults.removeObject(forKey: Key.name)
            }
        }
    }

    public var peerSettings: PeerSettings {
        get {
            let rawPort = defaults.integer(forKey: Key.peerPort)
            return PeerSettings(
                enabled: defaults.bool(forKey: Key.peerEnabled),
                host: defaults.string(forKey: Key.peerHost) ?? "",
                port: UInt16(rawPort > 0 && rawPort <= 65535 ? rawPort : 8765),
                token: defaults.string(forKey: Key.peerToken) ?? ""
            )
        }
        set {
            defaults.set(newValue.enabled, forKey: Key.peerEnabled)
            defaults.set(newValue.host, forKey: Key.peerHost)
            defaults.set(Int(newValue.port), forKey: Key.peerPort)
            defaults.set(newValue.token, forKey: Key.peerToken)
        }
    }

    public func setTargetDevice(address: String, name: String) {
        defaults.set(address, forKey: Key.address)
        defaults.set(name, forKey: Key.name)
    }
}