import Foundation
import UserNotifications
import AgentBarCore

/// Thin wrapper over UNUserNotificationCenter. UNUserNotificationCenter crashes when the
/// process isn't a proper .app bundle (e.g. `swift run`), so everything is gated on that.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    enum PermissionAction: Sendable { case allow, deny, review }

    /// Called (on any thread) when the user taps a permission notification or one of its buttons.
    var onPermissionAction: (@Sendable (_ sessionKey: String, _ requestID: String, _ action: PermissionAction) -> Void)?

    /// Commands up to this length, on one line, are fully visible in a banner, so the banner
    /// may offer "Allow". Anything longer only offers "Review…" (opens the full card) and "Deny".
    static let maxInlineDetail = 100

    private enum ID {
        static let allow = "ALLOW", deny = "DENY", review = "REVIEW"
        static let categoryShort = "PERMISSION_SHORT", categoryLong = "PERMISSION_LONG"
    }

    var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func installDelegate() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Allow needs an unlocked Mac; Deny is always safe.
        let allow = UNNotificationAction(identifier: ID.allow, title: "Allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: ID.deny, title: "Deny", options: [.destructive])
        let review = UNNotificationAction(identifier: ID.review, title: "Review…", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ID.categoryShort, actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: ID.categoryLong, actions: [review, deny], intentIdentifiers: []),
        ])
    }

    func requestAuthorization(_ done: @escaping @Sendable (String) -> Void) {
        guard isAvailable else { done("unavailable outside the .app bundle"); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { done("error: \(error.localizedDescription)") } else { done(granted ? "granted" : "denied") }
        }
    }

    func status(_ done: @escaping @Sendable (String) -> Void) {
        guard isAvailable else { done("unavailable outside the .app bundle"); return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized: done("allowed")
            case .denied: done("denied (System Settings › Notifications)")
            case .notDetermined: done("not requested yet")
            case .provisional: done("provisional")
            @unknown default: done("unknown")
            }
        }
    }

    func post(id: String, title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["session": id]
        // Same identifier replaces the previous banner for this session.
        add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    static func permissionID(_ requestKey: String) -> String { "permission:\(requestKey)" }

    func postPermission(sessionKey: String, request: PermissionRequestInfo, title: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = request.summary ?? request.tool ?? "Permission requested"
        let detail = request.detail ?? ""
        // Questions and plans are answered on the card (options, the full plan); never with a bare Allow.
        let needsCard = request.isQuestion || request.tool == "ExitPlanMode"
        let fitsInline = !needsCard && !detail.contains("\n") && detail.count <= Self.maxInlineDetail
        if request.isQuestion {
            content.body = "Choose Review to pick an answer."
        } else {
            content.body = detail.isEmpty ? "Open AgentBar to review" : (fitsInline ? detail : "\(detail.prefix(80))… Choose Review to see all of it.")
        }
        content.sound = .default
        content.categoryIdentifier = fitsInline ? ID.categoryShort : ID.categoryLong
        content.userInfo = ["session": sessionKey, "request": request.id]
        if #available(macOS 12.0, *) { content.interruptionLevel = .timeSensitive }
        add(UNNotificationRequest(identifier: Self.permissionID("\(sessionKey)#\(request.id)"), content: content, trigger: nil))
    }

    func withdraw(id: String) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("AgentBar notification failed: %@", error.localizedDescription) }
        }
    }

    // Show banners even while the panel is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let session = info["session"] as? String, let request = info["request"] as? String {
            switch response.actionIdentifier {
            case ID.allow: onPermissionAction?(session, request, .allow)
            case ID.deny: onPermissionAction?(session, request, .deny)
            default: onPermissionAction?(session, request, .review) // Review… or a click on the banner
            }
        }
        completionHandler()
    }
}
