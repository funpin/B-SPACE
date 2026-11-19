import BSpaceCore
import UserNotifications

/// Shows the web client's notifications and says when one is clicked.
public protocol NotificationPresenter: AnyObject {
    /// Called on the main queue with what the clicked notification carried
    /// (`NotificationRequest.userInfo`).
    var onClick: (([AnyHashable: Any]) -> Void)? { get set }
    /// Called when the window is first shown: the moment to ask the user for
    /// permission, if it has never been asked.
    func prepare()
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

    /// What the app asks to be allowed. The badge is part of it: the system
    /// shows the Dock icon's badge only for an app allowed to badge its icon.
    private static let permissions: UNAuthorizationOptions = [.alert, .sound, .badge]

    /// Asks for permission if the user has never been asked. The system's
    /// question is a banner that goes away by itself after a while and then
    /// counts as "no"; so it is put when the user is looking at the window,
    /// not when the first notification comes, which is exactly when they are
    /// not. The permission is kept per bundle identifier, so the one given to
    /// the Electron build stands and nothing is asked.
    public func prepare() {
        center.getNotificationSettings { [center] settings in
            // In the log once per launch: "why is there no notification, no
            // badge" starts with what the user has allowed.
            func allowed(_ setting: UNNotificationSetting) -> String {
                setting == .enabled ? "yes" : "no"
            }
            NSLog(
                "[notifications] permission %@: banners %@, sounds %@, badge %@",
                Self.describe(settings.authorizationStatus),
                allowed(settings.alertSetting),
                allowed(settings.soundSetting),
                allowed(settings.badgeSetting)
            )
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: Self.permissions) { _, _ in }
        }
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not asked yet"
        case .denied: return "refused"
        case .authorized: return "given"
        case .provisional: return "provisional"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }

    /// Shows the notification if the app is allowed to. Asking again here
    /// costs nothing once the user has answered, and covers a notification
    /// that comes before the window was ever shown.
    public func show(_ request: NotificationRequest) {
        center.requestAuthorization(options: Self.permissions) { [weak self] granted, error in
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
