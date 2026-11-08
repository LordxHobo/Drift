import Foundation
import UIKit
import UserNotifications

/// Notifications shown by the phone itself (no server needed): Listen Together invites that arrive while
/// Drift plays in the background, with Join and Decline right on the notification.
@MainActor
final class LocalNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotifications()

    private static let inviteCategory = "jam-invite"
    private static let joinAction = "join"
    private static let declineAction = "decline"
    private var ready = false

    /// Answers notifications and asks for permission (once; iOS remembers the answer).
    func setUp() {
        guard !ready else { return }
        ready = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let join = UNNotificationAction(identifier: Self.joinAction, title: "Join", options: [.foreground])
        let decline = UNNotificationAction(identifier: Self.declineAction, title: "Decline", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.inviteCategory, actions: [join, decline], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func invite(_ invite: JamInvite) {
        let content = UNMutableNotificationContent()
        content.title = "\(invite.fromName) invited you to listen together"
        content.body = invite.title.isEmpty ? "Tap to join." : "“\(invite.title)” by \(invite.artist)"
        content.sound = .default
        content.categoryIdentifier = Self.inviteCategory
        content.threadIdentifier = "jam-invites"
        content.userInfo = ["invite": invite.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: invite.id, content: content, trigger: nil))
    }

    /// A song a friend sent (tapping it opens the inbox).
    func song(_ item: InboxItem) {
        let content = UNMutableNotificationContent()
        content.title = "\(item.fromName) sent you a song"
        content.body = "“\(item.track.title)” by \(item.track.artist)" + (item.note.isEmpty ? "" : " · \(item.note)")
        content.sound = .default
        content.threadIdentifier = "songs"
        content.userInfo = ["inbox": item.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "inbox-\(item.id)", content: content, trigger: nil))
    }

    func clearSong(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["inbox-\(id)"])
        center.removePendingNotificationRequests(withIdentifiers: ["inbox-\(id)"])
    }

    func clear(_ invite: JamInvite) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [invite.id])
        center.removePendingNotificationRequests(withIdentifiers: [invite.id])
    }

    // MARK: UNUserNotificationCenterDelegate

    /// On screen, invites show as Drift's own popup instead.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["invite"] as? String
        let song = response.notification.request.content.userInfo["inbox"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            if song != nil {
                UIState.shared.openInbox = true
                return
            }
            guard let id, let invite = JamInvites.shared.waitingInvite(id) else { return }
            switch action {
            case Self.joinAction: await JamInvites.shared.accept(invite)
            case Self.declineAction: JamInvites.shared.decline(invite)
            default: JamInvites.shared.appBecameActive()   // tapped: ask in Drift
            }
        }
    }
}
