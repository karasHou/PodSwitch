import Foundation

public enum Mode: String, Sendable, Codable, CaseIterable {
    case steal = "STEAL"
    case ask = "ASK"
}

public enum Category: String, Sendable, Codable, CaseIterable {
    case media = "MEDIA"
    case call = "CALL"
    case notification = "NOTIFICATION"
}

/// Peer endpoint. The peer's MagicDNS name is also the inbound IP allowlist identity.
public struct PeerSettings: Sendable, Equatable {
    public var enabled: Bool
    public var host: String
    public var port: UInt16

    public init(enabled: Bool = false, host: String = "", port: UInt16 = 8765) {
        self.enabled = enabled
        self.host = host
        self.port = port
    }
}

public struct Config: Sendable, Equatable {
    public var enabled: Bool
    public var mode: Mode
    public var enabledCategories: Set<Category>
    public var targetDeviceId: String?

    public init(enabled: Bool, mode: Mode, enabledCategories: Set<Category>, targetDeviceId: String?) {
        self.enabled = enabled
        self.mode = mode
        self.enabledCategories = enabledCategories
        self.targetDeviceId = targetDeviceId
    }
}

public struct DeviceStatus: Sendable, Equatable {
    public var targetPaired: Bool
    public var targetActiveOutput: Bool
    public var notificationPending: Bool

    public init(targetPaired: Bool, targetActiveOutput: Bool, notificationPending: Bool) {
        self.targetPaired = targetPaired
        self.targetActiveOutput = targetActiveOutput
        self.notificationPending = notificationPending
    }
}

public enum SwitchEvent: Sendable, Equatable {
    case audioStarted(Category)
    case userAcceptedSwitch
    case audioStopped
}

public enum SwitchAction: Sendable, Equatable {
    case none
    case connect
    case notify
}
