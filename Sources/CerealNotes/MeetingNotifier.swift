import Foundation
import UserNotifications

final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let categoryID = "MEETING_DETECTED"
    static let recordActionID = "RECORD_ACTION"
    static let dismissActionID = "DISMISS_ACTION"
    static let notificationID = "meeting-detected"

    @MainActor var onRecord: (() -> Void)?
    @MainActor var onDismiss: (() -> Void)?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let record = UNNotificationAction(
            identifier: Self.recordActionID,
            title: "Record",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: Self.dismissActionID,
            title: "Dismiss",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [record, dismiss],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func notify(appName: String, bundleIdentifier: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var authorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        if settings.authorizationStatus == .notDetermined {
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(appName) call detected"
        content.body = "Record this meeting?"
        content.categoryIdentifier = Self.categoryID
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: Self.notificationID,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionID = response.actionIdentifier
        await MainActor.run {
            switch actionID {
            case Self.recordActionID:
                self.onRecord?()
            case Self.dismissActionID:
                self.onDismiss?()
            default:
                break
            }
        }
    }
}
