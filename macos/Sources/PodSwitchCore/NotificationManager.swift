import Foundation
import UserNotifications

/// `UserNotifications`-backed implementation of `Notifying`.
///
/// Requires running from a bundled `.app` with a valid bundle identifier.
@MainActor
public final class NotificationManager: NSObject, Notifying, @preconcurrency UNUserNotificationCenterDelegate {

    /// Invoked when the user taps the "Connect" action on the switch prompt.
    public var onAccept: (() -> Void)?

    private let center: UNUserNotificationCenter
    private static let categoryId = "PODSWITCH_SWITCH_PROMPT"
    private static let connectActionId = "PODSWITCH_CONNECT"
    private static let promptId = "PODSWITCH_PROMPT"

    public override init() {
        self.center = UNUserNotificationCenter.current()
        super.init()
        configure()
    }

    private func configure() {
        let connect = UNNotificationAction(
            identifier: Self.connectActionId,
            title: "Connect",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [connect],
            intentIdentifiers: [],
            options: []
        )
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
        deliver(content, identifier: Self.promptId)
    }

    private func deliver(_ content: UNMutableNotificationContent, identifier: String) {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == Self.connectActionId {
            onAccept?()
        }
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
