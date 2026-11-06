import Foundation
import UserNotifications

@MainActor
public final class NotificationManager: NSObject, Notifying, SwitchFailureNotifying, @preconcurrency UNUserNotificationCenterDelegate {
    public var onAccept: (() -> Void)?
    private let center = UNUserNotificationCenter.current()
    private static let categoryId = "PODSWITCH_SWITCH_PROMPT"
    private static let connectActionId = "PODSWITCH_CONNECT"
    private static let promptId = "PODSWITCH_PROMPT"

    public override init() {
        super.init()
        let connect = UNNotificationAction(identifier: Self.connectActionId, title: "Connect", options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.categoryId, actions: [connect], intentIdentifiers: [])
        center.setNotificationCategories([category])
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func showSwitchPrompt() {
        let content = UNMutableNotificationContent()
        content.title = "Audio started"
        content.body = "Move audio to your headphones?"
        content.categoryIdentifier = Self.categoryId
        content.sound = .default
        center.add(UNNotificationRequest(identifier: Self.promptId, content: content, trigger: nil))
    }

    public func showSwitchFailure(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "PodSwitch"
        content.body = message
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == Self.connectActionId { onAccept?() }
        completionHandler()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}