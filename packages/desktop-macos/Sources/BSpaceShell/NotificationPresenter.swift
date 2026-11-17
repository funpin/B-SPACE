import BSpaceCore
import UserNotifications

/// Shows the web client's notifications and says when one is clicked.
public protocol NotificationPresenter: AnyObject {
    /// Called on the main queue with what the clicked notification carried
    /// (`NotificationRequest.userInfo`).
    var onClick: (([AnyHashable: Any]) -> Void)? { get set }
    func show(_ request: NotificationRequest)
}

/// The system's notifications. The system keeps a delivered notification
/// itself, so nothing has to be held here for its click to work (the Electron
/// build has to hold every notification object; plan, deviation 7), and a
/// click still arrives after the app was quit and opened again.
public final class SystemNotificationPresenter: NSObject, NotificationPresenter {
    public var onClick: (([AnyHashable: Any]) -> Void)?

    private let center: UNUserNotificationCenter
    private var hasReportedRefusal = false

    /// Nil for an executable that is not an application bundle (a test run):
    /// the system's notification centre exists for bundles only.
    public init?(bundle: Bundle = .main) {
        guard bundle.bundleIdentifier != nil else { return nil }
        center = .current()
        super.init()
        center.delegate = self
    }

    /// Asks for permission the first time (the system answers at once from
    /// then on) and shows the notification if it is given. The permission is
    /// kept per bundle identifier, so the one given to the Electron build
    /// stands.
    public func show(_ request: NotificationRequest) {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    guard !self.hasReportedRefusal else { return }
                    self.hasReportedRefusal = true
                    NSLog(
                        "[notifications] not allowed to show notifications%@",
                        error.map { ": \($0.localizedDescription)" } ?? ""
                    )
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.body
            content.sound = .default
            content.userInfo = request.userInfo
            let notification = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            self.center.add(notification) { error in
                if let error {
                    NSLog("[notifications] a notification could not be shown: %@", error.localizedDescription)
                }
            }
        }
    }
}

extension SystemNotificationPresenter: UNUserNotificationCenterDelegate {
    /// Shown even while the app is in front, as Electron's are: the web
    /// client decides when a notification is due.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let userInfo = response.notification.request.content.userInfo
            DispatchQueue.main.async { [weak self] in
                self?.onClick?(userInfo)
            }
        }
        completionHandler()
    }
}
