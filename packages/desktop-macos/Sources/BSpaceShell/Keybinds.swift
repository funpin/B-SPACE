import AppKit
import BSpaceCore
import CoreGraphics

/// What reports the keys and mouse buttons pressed anywhere in the system.
public protocol KeyInputSource: AnyObject {
    /// Called on the main thread with each report.
    var onInput: ((KeyInput) -> Void)? { get set }
    /// Called when reports may have been lost: the system had switched the
    /// listener off for a while.
    var onInterrupted: (() -> Void)? { get set }
    /// Starts reporting. False when the system does not let it.
    func start() -> Bool
    func stop()
}

/// What says whether a key or a mouse button is down right now, apart from
/// what the listener reported.
public protocol KeyStateProbe: AnyObject {
    func isKeyDown(_ keyCode: UInt16) -> Bool
    /// - Parameter button: numbered as the system numbers them, 2 the middle one.
    func isMouseButtonDown(_ button: Int) -> Bool
}

/// Asks the system. The state is the one of the whole session, the same
/// stream of events the listener sees, so a key pressed by another program
/// counts as down here as it does there.
public final class SystemKeyStateProbe: KeyStateProbe {
    public init() {}

    public func isKeyDown(_ keyCode: UInt16) -> Bool {
        // Caps Lock counts as down while its light is on, which a look at
        // the key does not show: it is left to the listener.
        if keyCode == 0x39 { return true }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }

    public func isMouseButtonDown(_ button: Int) -> Bool {
        guard let known = UInt32(exactly: button).flatMap(CGMouseButton.init(rawValue:)) else { return true }
        return CGEventSource.buttonState(.combinedSessionState, button: known)
    }
}

/// The system's permission to listen to the keyboard while another app is in
/// front.
public protocol KeybindPermission: AnyObject {
    var isGranted: Bool { get }
    /// Has the system ask the user, which it does once: after that the app
    /// is in the list of System Settings, on or off.
    func request()
    /// Opens the list in System Settings.
    func openSettings()
}

/// Input Monitoring: what the system asks of an app that only listens to
/// the keyboard. The Electron build asks for Accessibility, which lets an app
/// control the computer as well; listening needs less.
public final class InputMonitoringPermission: KeybindPermission {
    public static let settingsAddress = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

    public init() {}

    public var isGranted: Bool {
        CGPreflightListenEventAccess()
    }

    public func request() {
        _ = CGRequestListenEventAccess()
    }

    public func openSettings() {
        guard let url = URL(string: Self.settingsAddress) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Listens to the keyboard and the extra mouse buttons with an event tap
/// that only listens: it cannot change or hold back what it sees.
public final class EventTapKeyInputSource: KeyInputSource {
    public var onInput: ((KeyInput) -> Void)?
    public var onInterrupted: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init() {}

    deinit {
        stop()
    }

    public func start() -> Bool {
        if tap != nil { return true }
        let kinds: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp]
        let mask = kinds.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    Unmanaged<EventTapKeyInputSource>.fromOpaque(context).takeUnretainedValue().received(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        // The main run loop: the reports are then handled where the rest of
        // the shell runs, and there are few of them.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        runLoopSource = source
        return true
    }

    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
    }

    private func received(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switches a tap off when it answers slowly, and says
            // so with an event. It is switched back on; what was pressed or
            // let go meanwhile was not reported.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            onInterrupted?()
        case .keyDown:
            onInput?(.keyDown(keyCode: keyCode(of: event)))
        case .keyUp:
            onInput?(.keyUp(keyCode: keyCode(of: event)))
        case .flagsChanged:
            onInput?(.flagsChanged(keyCode: keyCode(of: event), flags: event.flags.rawValue))
        case .otherMouseDown:
            onInput?(.mouseDown(button: Int(event.getIntegerValueField(.mouseEventButtonNumber))))
        case .otherMouseUp:
            onInput?(.mouseUp(button: Int(event.getIntegerValueField(.mouseEventButtonNumber))))
        default:
            break
        }
    }

    private func keyCode(of event: CGEvent) -> UInt16 {
        UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    }
}

/// Global keybinds: what the web client syncs is listened for while any app
/// is in front, and the web client is told when an action begins and ends.
/// The shell's side of `packages/desktop/src/keybindManager.ts`.
public final class KeybindCoordinator {
    /// An action began or ended (`keybind-action`).
    public var onEvent: ((KeybindEvent) -> Void)?
    /// Whether the system lets the shell listen, said each time listening is
    /// about to start and when the answer changes (`accessibility-status`).
    public var onPermissionStatus: ((Bool) -> Void)?
    /// The system gave the permission and still would not let the shell
    /// listen (`keybind-hook-error`).
    public var onListenerError: ((String) -> Void)?

    public private(set) var isListening = false

    private let source: KeyInputSource
    private let permission: KeybindPermission
    private let probe: KeyStateProbe
    private let reconcileInterval: TimeInterval
    private var matcher = KeybindMatcher()
    private var lastKnownPermission: Bool?
    private var reconcileTimer: Timer?

    /// - Parameter reconcileInterval: how often, while something is held,
    ///   what is believed to be down is checked against what really is.
    public init(
        source: KeyInputSource = EventTapKeyInputSource(),
        permission: KeybindPermission = InputMonitoringPermission(),
        probe: KeyStateProbe = SystemKeyStateProbe(),
        reconcileInterval: TimeInterval = 0.5
    ) {
        self.source = source
        self.permission = permission
        self.probe = probe
        self.reconcileInterval = reconcileInterval
        source.onInput = { [weak self] input in
            guard let self, self.isListening else { return }
            self.send(self.matcher.handle(input))
        }
        source.onInterrupted = { [weak self] in
            self?.reconcile()
        }
    }

    deinit {
        reconcileTimer?.invalidate()
    }

    /// Takes the web client's list. Listening starts with the first keybind
    /// and stops with the last one, so an app with none set never asks for
    /// the permission.
    ///
    /// - Returns: whether the shell is listening.
    public func sync(_ keybinds: [Keybind]) -> Bool {
        send(matcher.update(keybinds))
        if keybinds.isEmpty {
            stopListening()
        } else if !isListening {
            startListening(asking: true)
        }
        return isListening
    }

    /// Whether the system lets the shell listen. Asked by the web client's
    /// settings; when the answer has become yes, listening starts.
    public func checkPermission() -> Bool {
        let granted = permission.isGranted
        if granted, !isListening, !matcher.isEmpty {
            startListening(asking: false)
        }
        note(permission: granted)
        return granted
    }

    /// The app came forward: the user may be back from System Settings.
    public func appBecameActive() {
        guard !matcher.isEmpty, !isListening else { return }
        _ = checkPermission()
    }

    public func openPermissionSettings() {
        // Asking first puts the app in the list the user is sent to.
        if !permission.isGranted { permission.request() }
        permission.openSettings()
    }

    /// The window shows another page: its keybinds went with the last one.
    public func pageChanged() {
        _ = sync([])
    }

    private func startListening(asking: Bool) {
        let granted = permission.isGranted
        note(permission: granted, always: asking)
        guard granted else {
            if asking { permission.request() }
            return
        }
        if source.start() {
            isListening = true
            reconcileTimer = Timer.scheduledTimer(withTimeInterval: reconcileInterval, repeats: true) { [weak self] _ in
                self?.reconcile()
            }
        } else {
            onListenerError?("The system did not start the keyboard listener.")
        }
    }

    private func stopListening() {
        guard isListening else { return }
        isListening = false
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        source.stop()
        send(matcher.stop())
    }

    /// Lets go of what is believed to be held and is not. A release the
    /// system never reported (a password being typed hides the keyboard from
    /// listeners; a slow listener is switched off) would otherwise leave
    /// push-to-talk transmitting.
    private func reconcile() {
        guard isListening, matcher.hasKeysDown else { return }
        send(matcher.reconcile(
            keyIsDown: { [probe] key in
                KeyCodes.virtualKey(forHash: key).map(probe.isKeyDown) ?? true
            },
            // A keybind numbers the buttons one higher than the system does.
            buttonIsDown: { [probe] button in probe.isMouseButtonDown(button - 1) }
        ))
    }

    private func note(permission granted: Bool, always: Bool = false) {
        guard always || granted != lastKnownPermission else { return }
        lastKnownPermission = granted
        onPermissionStatus?(granted)
    }

    private func send(_ events: [KeybindEvent]) {
        for event in events {
            onEvent?(event)
        }
    }
}
