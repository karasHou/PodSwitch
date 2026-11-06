import Foundation

/// How PodSwitch reacts when a relevant audio category starts playing.
public enum Mode: String, Sendable, Codable, CaseIterable {
    case steal = "STEAL"
    case ask = "ASK"
}

/// The kind of audio that triggered an event.
public enum Category: String, Sendable, Codable, CaseIterable {
    case media = "MEDIA"
    case call = "CALL"
    case notification = "NOTIFICATION"
}

/// Remote peer settings. Configure the same bearer token on both computers.
public struct PeerSettings: Sendable, Equatable {
    public var enabled: Bool
    public var host: String
    public var port: UInt16
    public var token: String

    public init(enabled: Bool = false, host: String = "", port: UInt16 = 8765, token: String = "") {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.token = token
    }
}

/// User configuration for the switching behaviour.
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

/// Live device/environment status sampled at decision time.
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

/// Events that drive the decision engine.
public enum SwitchEvent: Sendable, Equatable {
    case audioStarted(Category)
    case userAcceptedSwitch
    case audioStopped
}

/// The action the platform layer should perform.
public enum SwitchAction: Sendable, Equatable {
    case none
    case connect
    case notify
}