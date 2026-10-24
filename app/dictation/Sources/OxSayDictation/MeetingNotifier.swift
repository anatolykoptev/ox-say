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

    func post(title: String, folder: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let folder { content.userInfo = [Self.folderKey: folder.path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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
