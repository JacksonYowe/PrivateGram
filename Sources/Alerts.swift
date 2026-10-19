import UIKit
import UserNotifications

/// Local notifications for new Instagram messages and activity, plus the app-icon badge.
/// Everything is generated on the phone from Instagram's own unread indicators — no server,
/// no push token, nothing sent anywhere.
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Alerts()

    /// Called when a notification is tapped, with the Instagram path to open.
    var onOpen: ((String) -> Void)?

    private let defaults = UserDefaults.standard
    private let enabledKey = "alertsEnabled", dmsKey = "alertsLastDMs", activityKey = "alertsLastActivity"

    var enabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: enabledKey)
            if !newValue { clear() }
        }
    }

    func requestPermissionIfNeeded() {
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// New unread counts from Instagram. Shows a banner when they go up and keeps the badge in sync.
    /// `currentPath` suppresses message banners while you're already in Messages.
    /// nil means "this screen doesn't show that indicator" — the previous value is kept.
    func update(dms newDMs: Int?, activity newActivity: Bool?, currentPath: String? = nil) {
        guard enabled, newDMs != nil || newActivity != nil else { return }
        let lastDMs = defaults.integer(forKey: dmsKey)
        let lastActivity = defaults.bool(forKey: activityKey)
        let dms = newDMs ?? lastDMs
        let activity = newActivity ?? lastActivity
        defaults.set(dms, forKey: dmsKey)
        defaults.set(activity, forKey: activityKey)

        let inMessages = currentPath.map { $0.hasPrefix("/direct") } ?? false
        if dms > lastDMs, !inMessages {
            post(id: "dms", title: "Instagram", path: "/direct/inbox/",
                 body: dms == 1 ? "You have a new message." : "You have \(dms) unread messages.")
        }
        if activity, !lastActivity {
            post(id: "activity", title: "Instagram", path: "/",
                 body: "New likes, comments or follows. Tap the heart to see them.")
        }
        if dms == 0 {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["dms"])
        }
        UNUserNotificationCenter.current().setBadgeCount(dms + (activity ? 1 : 0))
    }

    func clear() {
        defaults.removeObject(forKey: dmsKey)
        defaults.removeObject(forKey: activityKey)
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.setBadgeCount(0)
    }

    private func post(id: String, title: String, path: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = id
        content.userInfo = ["path": path]
        // Same identifier replaces the previous banner instead of stacking duplicates.
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show full banners with sound even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String,
           path.range(of: #"^/[A-Za-z0-9/._-]*$"#, options: .regularExpression) != nil {
            DispatchQueue.main.async { self.onOpen?(path) }
        }
        completionHandler()
    }
}
