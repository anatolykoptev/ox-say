import AppKit
import UserNotifications

/// "Meeting notes are ready" with the notes folder opening on a click. Best
/// effort: when notifications are not allowed the caller falls back to the
/// menu's status line.
final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let folderKey = "folder"

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// `completion(true)` once the notification was handed to the system; `false`
    /// when notifications are not allowed (or the system refused it) — the caller then
    /// shows the same words on the menu's status line. Called on an arbitrary queue.
    func post(title: String, folder: URL?, completion: @escaping (Bool) -> Void = { _ in }) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                let content = UNMutableNotificationContent()
                content.title = title
                if let folder { content.userInfo = [Self.folderKey: folder.path] }
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) {
                    completion($0 == nil)
                }
            default:
                completion(false)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo[Self.folderKey] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
