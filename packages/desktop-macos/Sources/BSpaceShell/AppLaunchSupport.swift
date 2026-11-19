import AppKit
import BSpaceCore
import ServiceManagement

// The parts of starting the app that ask the system something: the login
// item, how this process was launched, and other copies of the app. What is
// decided from the answers is in BSpaceCore (AppLaunch.swift).

/// The app's own login item, as macOS 13 and later keep it. It belongs to the
/// bundle identifier, so the item the Electron build registered is this one:
/// installing the native app over it keeps "open at login" as the user set it.
public final class SystemLoginItem: LoginItem {
    public init() {}

    /// Enabled means it will open at login. An item the user switched off in
    /// System Settings is registered but not enabled, and reads as off.
    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

public enum LaunchContext {
    /// True when the system opened the app as a login item. The launch event
    /// says so; it can be read only while the app is finishing its launch.
    public static func wasLaunchedAtLogin() -> Bool {
        guard
            let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventID == AEEventID(kAEOpenApplication)
        else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    /// Makes this bundle the one that opens `backspace://` links, if its
    /// Info.plist says it opens them. Electron does the same at every launch.
    public static func claimDeepLinks(bundle: Bundle = .main) {
        guard DeepLink.isDeclared(infoDictionary: bundle.infoDictionary) else { return }
        NSWorkspace.shared.setDefaultApplication(at: bundle.bundleURL, toOpenURLsWithScheme: DeepLink.scheme) { error in
            if let error {
                NSLog("[links] could not become the handler of %@ links: %@", DeepLink.scheme, error.localizedDescription)
            }
        }
    }
}

/// Keeps one copy of the app running. macOS already does that for an app
/// opened from the Finder or the Dock; this covers what gets past it: the
/// executable started directly, or `open -n`.
public enum SingleInstanceGuard {
    /// Decides whether this copy stays. When another copy started first, this
    /// one tells it to come forward, hands it `link` if there is one, and the
    /// answer is false: the caller must quit without creating anything.
    public static func claim(bundleIdentifier: String?, link: String?) -> Bool {
        guard let bundleIdentifier else { return true }
        let own = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != own.processIdentifier && !$0.isTerminated }
        guard !others.isEmpty else { return true }

        let ownInstance = instance(of: own.processIdentifier)
        let survivor = SingleInstance.survivor(of: [ownInstance] + others.map { instance(of: $0.processIdentifier) })
        guard let survivor, survivor != ownInstance else { return true }

        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(SingleInstance.notificationName(bundleIdentifier: bundleIdentifier)),
            object: link,
            userInfo: nil,
            deliverImmediately: true
        )
        if let running = others.first(where: { $0.processIdentifier == survivor.processIdentifier }) {
            NSApp.yieldActivation(to: running)
            running.activate()
        }
        return false
    }

    /// Calls `handler` on the main queue when a copy that gave way asks this
    /// one to come forward, with the link it was launched with, if any.
    /// Any process of the user can send this; it can do no more than a click
    /// on a `backspace://` link can.
    public static func observe(bundleIdentifier: String?, handler: @escaping (String?) -> Void) -> NSObjectProtocol? {
        guard let bundleIdentifier else { return nil }
        return DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(SingleInstance.notificationName(bundleIdentifier: bundleIdentifier)),
            object: nil,
            queue: .main
        ) { notification in
            handler(notification.object as? String)
        }
    }

    private static func instance(of processIdentifier: pid_t) -> RunningInstance {
        RunningInstance(processIdentifier: processIdentifier, startTime: startTime(of: processIdentifier))
    }

    /// When a process started, from the kernel: `NSRunningApplication` knows
    /// it only for apps the Finder or the Dock opened.
    private static func startTime(of processIdentifier: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }
}
