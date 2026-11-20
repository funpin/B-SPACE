import Foundation

/// What the B:SPACE character in the menu bar is showing. The web client
/// decides the state and reports it over `set-tray-state`; the shell plays
/// the state's animation one frame image at a time. A port of
/// `packages/desktop/src/trayState.ts`.
public enum TrayState: String, CaseIterable {
    case idle
    case look
    case notify
    case typing
    case voice
    case screen
    case joy
    case dnd
    case offline

    /// Reads the call's one argument. Anything that is not a state's name is
    /// refused, and the character keeps doing what it did.
    public init?(arguments: BridgeArguments) {
        guard let name = arguments.string(at: 0), let state = TrayState(rawValue: name) else { return nil }
        self = state
    }
}

/// Every frame image the tray can show. The images are generated into
/// `packages/desktop/resources` (`tray-<frame>Template.png` and `@2x`), the
/// same files the Electron build loads.
public enum TrayFrame: String, CaseIterable {
    case idle
    case blink
    case lookLeft = "look-left"
    case lookRight = "look-right"
    case notify
    case notifyUp = "notify-up"
    case typingA = "typing-a"
    case typingB = "typing-b"
    case typing
    case voice
    case screen
    case screenDim = "screen-dim"
    case joy
    case joyUp = "joy-up"
    case dnd
    case offline

    /// The name of the frame's template image, without the extension: the
    /// system picks the `@2x` file by itself.
    public var resourceName: String {
        "tray-\(rawValue)Template"
    }
}

public struct TrayFrameStep: Equatable {
    public let frame: TrayFrame
    /// How long the frame stays up.
    public let milliseconds: Int

    public init(_ frame: TrayFrame, _ milliseconds: Int) {
        self.frame = frame
        self.milliseconds = milliseconds
    }
}

public enum TrayAnimations {
    /// One loop per state. A loop of one step is a still image. The first
    /// step is also the state's still frame when the system asks for reduced
    /// motion.
    public static func loop(for state: TrayState) -> [TrayFrameStep] {
        switch state {
        case .idle:
            // Blinks every 3–4 s.
            return [TrayFrameStep(.idle, 3400), TrayFrameStep(.blink, 150)]
        case .look:
            // Loading, connecting: looks left, then right, about 4.5 s a cycle.
            return [
                TrayFrameStep(.lookLeft, 1300),
                TrayFrameStep(.idle, 300),
                TrayFrameStep(.lookRight, 1300),
                TrayFrameStep(.idle, 1450),
                TrayFrameStep(.blink, 150),
            ]
        case .notify:
            // Unread or a mention: wider eyes and the dot, a double hop now and then.
            return [
                TrayFrameStep(.notify, 1900),
                TrayFrameStep(.notifyUp, 160),
                TrayFrameStep(.notify, 110),
                TrayFrameStep(.notifyUp, 110),
            ]
        case .typing:
            // Someone is typing: eyes down, the dots appear one by one.
            return [TrayFrameStep(.typingA, 300), TrayFrameStep(.typingB, 300), TrayFrameStep(.typing, 600)]
        case .voice:
            // The user is speaking in a voice channel: the ring pulses.
            return [TrayFrameStep(.voice, 450), TrayFrameStep(.idle, 250)]
        case .screen:
            // The user is sharing their screen: the live dot in the screen blinks.
            return [TrayFrameStep(.screen, 1000), TrayFrameStep(.screenDim, 600)]
        case .joy:
            // A message was sent, signed in: one hop, then "^ ^". The web
            // client holds this state for a moment and moves on.
            return [TrayFrameStep(.joyUp, 180), TrayFrameStep(.joy, 1600)]
        case .dnd:
            return [TrayFrameStep(.dnd, 0)]
        case .offline:
            return [TrayFrameStep(.offline, 0)]
        }
    }
}

/// Plays a state's loop. It owns no timer and no image: each call answers
/// with what the shell has to do. Only frame changes are shown, and a state
/// that is set again while it is already playing keeps its place in the
/// loop, so the web client may report the same state as often as it likes.
public struct TrayAnimator {
    public enum Command: Equatable {
        case show(TrayFrame)
        /// Call `timerFired` after this long.
        case schedule(milliseconds: Int)
        /// Drop the timer that was scheduled.
        case cancel
    }

    public private(set) var state: TrayState?
    private var step = 0
    private var shown: TrayFrame?
    private var timerIsPending = false

    public init() {}

    /// - Parameter reducedMotion: whether the system asks apps to keep still.
    ///   Read at every step, so turning the setting on stops the motion at
    ///   the next change.
    public mutating func set(_ state: TrayState, reducedMotion: Bool) -> [Command] {
        guard state != self.state else { return [] }
        var commands = stop()
        self.state = state
        step = 0
        commands += play(reducedMotion: reducedMotion)
        return commands
    }

    public mutating func timerFired(reducedMotion: Bool) -> [Command] {
        guard timerIsPending, let state else { return [] }
        timerIsPending = false
        step = (step + 1) % TrayAnimations.loop(for: state).count
        return play(reducedMotion: reducedMotion)
    }

    /// Stops the motion without forgetting the state.
    public mutating func stop() -> [Command] {
        guard timerIsPending else { return [] }
        timerIsPending = false
        return [.cancel]
    }

    private mutating func play(reducedMotion: Bool) -> [Command] {
        guard let state else { return [] }
        let loop = TrayAnimations.loop(for: state)
        let current = loop[step % loop.count]
        var commands: [Command] = []
        if current.frame != shown {
            shown = current.frame
            commands.append(.show(current.frame))
        }
        if loop.count > 1, !reducedMotion {
            timerIsPending = true
            commands.append(.schedule(milliseconds: current.milliseconds))
        }
        return commands
    }
}

/// The user's own status, as the tray menu offers it.
public enum TrayStatus: String, CaseIterable {
    case online
    case idle
    case dnd
}

/// What the tray menu needs from the web client to offer the quick controls:
/// the voice connection, mute and deafen, the user's own status, and what is
/// going on in the call. The web client reports it over `set-tray-context`.
///
/// The first five fields are those of `packages/desktop/src/trayContext.ts`,
/// which the Electron build's menu is made from. The last three are read by
/// this shell alone; a server whose web client is older does not send them.
public struct TrayContext: Equatable {
    /// Longest channel name the menu shows before cutting it with an ellipsis.
    public static let maxChannelName = 40

    /// Before sign-in and on the instance picker: no controls.
    public static let empty = TrayContext(signedIn: false, voiceChannelName: nil, muted: false, deafened: false, status: nil)

    public var signedIn: Bool
    /// The voice channel or call the user is in, or nil.
    public var voiceChannelName: String?
    public var muted: Bool
    public var deafened: Bool
    public var status: TrayStatus?
    /// Whether the user's camera is on. Nil when the web client does not say.
    public var cameraOn: Bool?
    /// Whether the user is sharing their screen. Nil when the web client does not say.
    public var screenSharing: Bool?
    /// The web client's "Show viewers' pointers" setting. Nil when it does not say.
    public var showPointers: Bool?

    public init(
        signedIn: Bool,
        voiceChannelName: String?,
        muted: Bool,
        deafened: Bool,
        status: TrayStatus?,
        cameraOn: Bool? = nil,
        screenSharing: Bool? = nil,
        showPointers: Bool? = nil
    ) {
        self.signedIn = signedIn
        self.voiceChannelName = voiceChannelName
        self.muted = muted
        self.deafened = deafened
        self.status = status
        self.cameraOn = cameraOn
        self.screenSharing = screenSharing
        self.showPointers = showPointers
    }

    /// Reads what the page sent. Anything malformed is refused whole and the
    /// shell keeps the context it had: a menu is never built from an
    /// unchecked shape. `voice` and `status` have to be there, as a value or
    /// as null. The three fields only this shell reads may be left out, and
    /// have to be booleans when they are there.
    public init?(arguments: BridgeArguments) {
        guard
            let value = arguments.object(at: 0),
            let signedIn = Self.bool(value["signedIn"]),
            let muted = Self.bool(value["muted"]),
            let deafened = Self.bool(value["deafened"]),
            let cameraOn = Self.optionalBool(value["cameraOn"]),
            let screenSharing = Self.optionalBool(value["screenSharing"]),
            let showPointers = Self.optionalBool(value["showPointers"])
        else { return nil }

        let status: TrayStatus?
        switch value["status"] {
        case is NSNull:
            status = nil
        case let name as String:
            guard let known = TrayStatus(rawValue: name) else { return nil }
            status = known
        default:
            return nil
        }

        let channel: String?
        switch value["voice"] {
        case is NSNull:
            channel = nil
        case let voice as [String: Any]:
            guard let name = voice["channelName"] as? String else { return nil }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            channel = trimmed.count > Self.maxChannelName
                ? String(trimmed.prefix(Self.maxChannelName - 1)) + "…"
                : trimmed
        default:
            return nil
        }

        self.init(
            signedIn: signedIn, voiceChannelName: channel, muted: muted, deafened: deafened, status: status,
            cameraOn: cameraOn, screenSharing: screenSharing, showPointers: showPointers
        )
    }

    /// A JavaScript boolean. A number is not one.
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A boolean that may be left out: the outer nil is a value that is
    /// there and is not a boolean.
    private static func optionalBool(_ value: Any?) -> Bool?? {
        guard let value else { return .some(nil) }
        guard let read = bool(value) else { return nil }
        return .some(read)
    }
}

/// What a click on a quick control sends back to the web client over
/// `tray-action`; the web client carries it out exactly as the voice bar or
/// the status picker would. The tray can turn the camera off and stop a
/// screen share, and cannot start either.
public enum TrayAction: Equatable {
    case toggleMute
    case toggleDeafen
    case disconnect
    case setStatus(TrayStatus)
    case toggleShowPointers
    case stopCamera
    case stopScreenShare

    public var bridgeValue: [String: Any] {
        switch self {
        case .toggleMute:
            return ["type": "toggleMute"]
        case .toggleDeafen:
            return ["type": "toggleDeafen"]
        case .disconnect:
            return ["type": "disconnect"]
        case .setStatus(let status):
            return ["type": "setStatus", "status": status.rawValue]
        case .toggleShowPointers:
            return ["type": "toggleShowPointers"]
        case .stopCamera:
            return ["type": "stopCamera"]
        case .stopScreenShare:
            return ["type": "stopScreenShare"]
        }
    }
}

/// What choosing an item of the tray menu does.
public enum TrayMenuCommand: Equatable {
    /// One of the web client's quick controls.
    case control(TrayAction)
    /// Show the window and bring the app forward.
    case show
    case quit
}

/// One round button of the row at the top of the tray menu.
public struct TrayControl: Equatable {
    public enum Kind: Equatable {
        case microphone(isOn: Bool)
        case sound(isOn: Bool)
        /// Whether the pointers of those who watch the user's screen are shown.
        case pointers(isOn: Bool)
        case stopCamera
        case stopScreenShare
        case disconnect
    }

    /// How the button is coloured: red for something switched off that the
    /// user should notice or something that is being stopped, the accent for
    /// something switched on.
    public enum Tone: Equatable {
        case plain
        case danger
        case accent
    }

    public let kind: Kind
    public let tone: Tone
    /// What the button is and the state it is in: its tooltip and its name
    /// for VoiceOver.
    public let title: String
    public let command: TrayMenuCommand
    /// A switch leaves the menu open, so the new state is seen; an action
    /// that ends something closes it.
    public let closesMenu: Bool
}

/// One item of the tray menu, with its title already in the shell's language.
public enum TrayMenuItem: Equatable {
    case separator
    /// A line that says something and cannot be chosen.
    case label(String)
    /// The row of round buttons.
    case controls([TrayControl])
    /// An item with a check mark.
    case toggle(title: String, isOn: Bool, command: TrayMenuCommand)
    case action(title: String, command: TrayMenuCommand)
}

public enum TrayMenu {
    /// The tray menu of this shell: the name of the call, a row of round
    /// buttons for what is done in one press, Do Not Disturb, and the two
    /// things the app itself does from here, open and quit. Changing the
    /// instance, the source code and updates are in the app's menu, where
    /// macOS has them; the Electron build keeps them in its tray menu because
    /// Windows has no other place for them.
    ///
    /// Mute and deafen are offered outside a call too: there they set how the
    /// user joins the next one, the same as the buttons in the voice bar.
    public static func items(context: TrayContext, strings: DesktopStrings, language: DesktopLanguage) -> [TrayMenuItem] {
        func text(_ key: DesktopStrings.Key, _ values: [String: String] = [:]) -> String {
            strings.text(key, in: language, values)
        }
        var items: [TrayMenuItem] = []

        if context.signedIn {
            let inCall = context.voiceChannelName != nil
            if let channel = context.voiceChannelName {
                items.append(.label(text(.trayInVoice, ["channel": channel])))
            }

            var row = [
                TrayControl(
                    kind: .microphone(isOn: !context.muted),
                    tone: context.muted ? .danger : .plain,
                    title: text(context.muted ? .trayMicrophoneOff : .trayMicrophoneOn),
                    command: .control(.toggleMute),
                    closesMenu: false
                ),
                TrayControl(
                    kind: .sound(isOn: !context.deafened),
                    tone: context.deafened ? .danger : .plain,
                    title: text(context.deafened ? .traySoundOff : .traySoundOn),
                    command: .control(.toggleDeafen),
                    closesMenu: false
                ),
            ]
            if inCall, let shown = context.showPointers {
                row.append(TrayControl(
                    kind: .pointers(isOn: shown),
                    tone: shown ? .accent : .plain,
                    title: text(shown ? .trayPointersOn : .trayPointersOff),
                    command: .control(.toggleShowPointers),
                    closesMenu: false
                ))
            }
            if context.cameraOn == true {
                row.append(TrayControl(
                    kind: .stopCamera, tone: .danger, title: text(.trayStopCamera),
                    command: .control(.stopCamera), closesMenu: true
                ))
            }
            if context.screenSharing == true {
                row.append(TrayControl(
                    kind: .stopScreenShare, tone: .danger, title: text(.trayStopScreenShare),
                    command: .control(.stopScreenShare), closesMenu: true
                ))
            }
            if inCall {
                row.append(TrayControl(
                    kind: .disconnect, tone: .plain, title: text(.trayDisconnect),
                    command: .control(.disconnect), closesMenu: true
                ))
            }
            items.append(.controls(row))
            items.append(.separator)

            if let status = context.status {
                // Off goes to Online: what the status was before is not known here.
                let isOn = status == .dnd
                items.append(.toggle(
                    title: text(.trayStatusDnd),
                    isOn: isOn,
                    command: .control(.setStatus(isOn ? .online : .dnd))
                ))
            }
        }

        items += [
            .action(title: text(.trayShow), command: .show),
            .separator,
            .action(title: text(.trayQuit), command: .quit),
        ]
        return items
    }
}
