import Foundation
import MiraCore
import UserNotifications

/// Only this adapter knows the system notification framework. Business state lives in MiraCore.
actor MacLocalNotifications: LocalNotificationPort {
    private let center = UNUserNotificationCenter.current()
    private let delegate = MiraNotificationDelegate()

    init() { center.delegate = delegate }

    nonisolated static func retireNotificationNamespace(_ namespace: String) async throws {
        try await MacNotificationRetirement.retire(namespace: namespace)
    }

    func permission() async -> NotificationPermission {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestPermission() async throws -> Bool {
        do { return try await center.requestAuthorization(options: [.alert, .sound]) } catch {
            throw MiraError(.unauthorized, "Notification permission could not be requested. Check System Settings.")
        }
    }

    func pending() async -> [ReminderNotification] {
        await center.pendingNotificationRequests().compactMap { request in
            guard let revision = request.content.userInfo["mira_revision"] as? Int,
                let timestamp = request.content.userInfo["mira_fire_at"] as? Double
            else { return nil }
            return .init(
                identifier: request.identifier, title: request.content.title, body: request.content.body,
                fireAt: Date(timeIntervalSince1970: timestamp), revision: revision)
        }
    }

    func install(_ notification: ReminderNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = [
            "mira_revision": notification.revision, "mira_fire_at": notification.fireAt.timeIntervalSince1970,
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: notification.fireAt)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        do {
            try await center.add(.init(identifier: notification.identifier, content: content, trigger: trigger))
        } catch { throw MiraError(.storage, "The reminder could not be scheduled. Retry scheduling.") }
    }

    func remove(_ identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

private final class MiraNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions
    {
        [.banner, .sound]
    }
}

/// Explicit demo sessions never request permission or change the user's notification center.
struct DemoLocalNotifications: LocalNotificationPort {
    func permission() async -> NotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func pending() async -> [ReminderNotification] { [] }
    func install(_ notification: ReminderNotification) async throws {
        throw MiraError(.unsupported, "Local notifications are unavailable in this session.")
    }
    func remove(_ identifier: String) async {}
}
