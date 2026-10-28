import AppKit
import UserNotifications

/// "Meeting notes are ready" with the notes folder opening on a click. Best
/// effort: when notifications are not allowed the caller falls back to the
/// menu's status line.
final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let folderKey = "folder"
    private static let urlKey = "url"

    func install() {
        // Only the delegate is set here: the authorization question is asked at the first `post`, in context,
        // never at launch — meetings are on by default now and an unexplained prompt must not greet anyone.
        UNUserNotificationCenter.current().delegate = self
    }

    /// `completion(true)` once the notification was handed to the system; `false`
    /// when notifications are not allowed (or the system refused it) — the caller then
    /// shows the same words on the menu's status line. Called on an arbitrary queue.
    ///
    /// `body` is the sentence under the title; `openURL` is opened by a click on the notification (the silent-tap
    /// notice opens System Settings' pane this way — a non-modal action that cannot catch a stray Return).
    func post(title: String, body: String? = nil, folder: URL? = nil, openURL: URL? = nil, completion: @escaping (Bool) -> Void = { _ in }) {
        let center = UNUserNotificationCenter.current()
        // Asked here, not at install: the permission question arrives with the first notification it enables.
        // An already-decided answer returns at once and raises nothing.
        center.requestAuthorization(options: [.alert]) { _, _ in
            center.getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    let content = UNMutableNotificationContent()
                    content.title = title
                    if let body { content.body = body }
                    var info: [String: String] = [:]
                    if let folder { info[Self.folderKey] = folder.path }
                    if let openURL { info[Self.urlKey] = openURL.absoluteString }
                    content.userInfo = info
                    center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) {
                        completion($0 == nil)
                    }
                default:
                    completion(false)
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let path = info[Self.folderKey] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let text = info[Self.urlKey] as? String, let url = URL(string: text) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
