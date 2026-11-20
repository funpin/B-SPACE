import Foundation

/// The keys a global keybind can be made of.
///
/// The web client records a keybind as hashes of DOM `KeyboardEvent.code`
/// strings (`KeybindsPanel.tsx`). The system reports a key by its virtual key
/// code, so this table names the DOM code of each, as Chromium names it on a
/// Mac keyboard. The Electron build has the same table for the codes of
/// `uiohook` (`packages/desktop/src/keybindManager.ts`); a test holds the two
/// to the same DOM codes.
public enum KeyCodes {
    /// The system's virtual key code → the DOM code of that key.
    public static let domCodes: [UInt16: String] = [
        // Letters
        0x00: "KeyA", 0x0B: "KeyB", 0x08: "KeyC", 0x02: "KeyD", 0x0E: "KeyE",
        0x03: "KeyF", 0x05: "KeyG", 0x04: "KeyH", 0x22: "KeyI", 0x26: "KeyJ",
        0x28: "KeyK", 0x25: "KeyL", 0x2E: "KeyM", 0x2D: "KeyN", 0x1F: "KeyO",
        0x23: "KeyP", 0x0C: "KeyQ", 0x0F: "KeyR", 0x01: "KeyS", 0x11: "KeyT",
        0x20: "KeyU", 0x09: "KeyV", 0x0D: "KeyW", 0x07: "KeyX", 0x10: "KeyY",
        0x06: "KeyZ",
        // Digits
        0x1D: "Digit0", 0x12: "Digit1", 0x13: "Digit2", 0x14: "Digit3", 0x15: "Digit4",
        0x17: "Digit5", 0x16: "Digit6", 0x1A: "Digit7", 0x1C: "Digit8", 0x19: "Digit9",
        // Function keys
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18",
        0x50: "F19", 0x5A: "F20",
        // Modifiers
        0x3B: "ControlLeft", 0x3E: "ControlRight",
        0x3A: "AltLeft", 0x3D: "AltRight",
        0x38: "ShiftLeft", 0x3C: "ShiftRight",
        0x37: "MetaLeft", 0x36: "MetaRight",
        // Special keys
        0x33: "Backspace", 0x30: "Tab", 0x24: "Enter", 0x39: "CapsLock", 0x35: "Escape", 0x31: "Space",
        // Navigation
        0x74: "PageUp", 0x79: "PageDown", 0x77: "End", 0x73: "Home",
        0x7B: "ArrowLeft", 0x7E: "ArrowUp", 0x7C: "ArrowRight", 0x7D: "ArrowDown",
        // The Help key of a full-size keyboard sits where Insert is.
        0x72: "Insert", 0x75: "Delete",
        // Punctuation
        0x29: "Semicolon", 0x18: "Equal", 0x2B: "Comma", 0x1B: "Minus", 0x2F: "Period",
        0x2C: "Slash", 0x32: "Backquote", 0x21: "BracketLeft", 0x2A: "Backslash",
        0x1E: "BracketRight", 0x27: "Quote",
        // Numpad
        0x52: "Numpad0", 0x53: "Numpad1", 0x54: "Numpad2", 0x55: "Numpad3",
        0x56: "Numpad4", 0x57: "Numpad5", 0x58: "Numpad6", 0x59: "Numpad7",
        0x5B: "Numpad8", 0x5C: "Numpad9", 0x43: "NumpadMultiply", 0x45: "NumpadAdd",
        0x4E: "NumpadSubtract", 0x41: "NumpadDecimal", 0x4B: "NumpadDivide",
        // The Clear key of the numpad sits where Num Lock is.
        0x47: "NumLock",
    ]

    /// The DOM codes of the Electron build's table that no Mac keyboard
    /// sends: the system has no virtual key code for them. On a Mac the keys
    /// printed F13 and F14 are where Print Screen and Scroll Lock would be,
    /// and they report as F13 and F14.
    public static let withoutAMacKey: Set<String> = ["F21", "F22", "F23", "F24", "ScrollLock", "PrintScreen"]

    /// The number the web client stores for a DOM code: djb2 over the
    /// string's UTF-16 units, wrapped to 32 bits (`codeToNumeric` in
    /// `KeybindsPanel.tsx`, `djb2` in `keybindManager.ts`).
    public static func hash(_ code: String) -> UInt32 {
        var hash: UInt32 = 5381
        for unit in code.utf16 {
            hash = (hash << 5) &+ hash &+ UInt32(unit)
        }
        return hash
    }

    /// The number a keybind holds for this key, or nil for a key that has no
    /// DOM code here.
    public static func hash(forVirtualKey key: UInt16) -> UInt32? {
        hashes[key]
    }

    /// The system's key for the number a keybind holds, or nil for a number
    /// that is no key here.
    public static func virtualKey(forHash hash: UInt32) -> UInt16? {
        virtualKeys[hash]
    }

    private static let hashes: [UInt16: UInt32] = domCodes.mapValues(hash)
    private static let virtualKeys: [UInt32: UInt16] = Dictionary(
        uniqueKeysWithValues: hashes.map { ($0.value, $0.key) }
    )
}

/// One global keybind, as the web client syncs it over `keybinds-sync`.
public struct Keybind: Equatable {
    public let actionId: String
    /// The keys that have to be down, as `KeyCodes.hash` numbers.
    public let keys: [UInt32]
    /// The mouse button that fires it with those keys held, numbered as
    /// `uiohook` numbers them (3 middle, 4 back, 5 forward), or nil for a
    /// keybind of keys alone.
    public let mouseButton: Int?

    public init(actionId: String, keys: [UInt32], mouseButton: Int? = nil) {
        self.actionId = actionId
        self.keys = keys
        self.mouseButton = mouseButton
    }

    /// Reads the call's one argument, a list of keybinds. Anything that is
    /// not one is refused whole: the shell keeps listening for what it had.
    /// A mouse button of zero is no mouse button, as the web client's own
    /// check has it.
    public static func list(arguments: BridgeArguments) -> [Keybind]? {
        guard let values = arguments.array(at: 0) else { return nil }
        var keybinds: [Keybind] = []
        for value in values {
            guard
                let fields = value as? [String: Any],
                let actionId = fields["actionId"] as? String, !actionId.isEmpty,
                let listed = fields["keys"] as? [Any]
            else { return nil }

            var keys: [UInt32] = []
            for entry in listed {
                guard let number = wholeNumber(entry), let key = UInt32(exactly: number) else { return nil }
                keys.append(key)
            }

            let button: Int?
            switch fields["mouseButton"] {
            case nil, is NSNull:
                button = nil
            case let given:
                guard let number = wholeNumber(given), number >= 0, let whole = Int(exactly: number) else { return nil }
                button = whole == 0 ? nil : whole
            }
            keybinds.append(Keybind(actionId: actionId, keys: keys, mouseButton: button))
        }
        return keybinds
    }

    /// A JavaScript number with no fraction. A boolean is not one.
    private static func wholeNumber(_ value: Any?) -> Double? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite,
            number.doubleValue == number.doubleValue.rounded()
        else { return nil }
        return number.doubleValue
    }
}

/// What the web client is told over `keybind-action`: an action began or
/// ended.
public struct KeybindEvent: Equatable {
    public let actionId: String
    public let pressed: Bool

    public init(actionId: String, pressed: Bool) {
        self.actionId = actionId
        self.pressed = pressed
    }

    public var bridgeValue: [String: Any] {
        ["actionId": actionId, "pressed": pressed]
    }
}

/// Decides which actions the keys and mouse buttons that are down press. It
/// listens to nothing itself: the shell feeds it what the system reports and
/// sends on what it answers. A port of the matching in
/// `packages/desktop/src/keybindManager.ts`.
///
/// An action is pressed once when all its keys are down and released once
/// when one of them goes up, however often the system repeats a held key:
/// push-to-talk depends on never getting two presses for one.
public struct KeybindMatcher {
    private var keybinds: [Keybind] = []
    private var pressedKeys = Set<UInt32>()
    /// The actions that are pressed, in the order they were.
    private var active: [String] = []

    public init() {}

    /// Whether there is nothing to listen for.
    public var isEmpty: Bool {
        keybinds.isEmpty
    }

    /// Takes a new list. An action that is pressed and no longer listed is
    /// released.
    public mutating func update(_ keybinds: [Keybind]) -> [KeybindEvent] {
        self.keybinds = keybinds
        let gone = active.filter { actionId in !keybinds.contains { $0.actionId == actionId } }
        active.removeAll(where: gone.contains)
        return gone.map { KeybindEvent(actionId: $0, pressed: false) }
    }

    public mutating func keyDown(_ key: UInt32) -> [KeybindEvent] {
        pressedKeys.insert(key)
        return press { $0.mouseButton == nil && !$0.keys.isEmpty }
    }

    public mutating func keyUp(_ key: UInt32) -> [KeybindEvent] {
        pressedKeys.remove(key)
        let down = pressedKeys
        return release { keybind in
            keybind.mouseButton == nil && !keybind.keys.allSatisfy(down.contains)
        }
    }

    /// - Parameter button: numbered as in `Keybind.mouseButton`. The left
    ///   and right buttons (1 and 2) are never keybinds.
    public mutating func mouseDown(_ button: Int) -> [KeybindEvent] {
        guard button > 2 else { return [] }
        return press { $0.mouseButton == button }
    }

    public mutating func mouseUp(_ button: Int) -> [KeybindEvent] {
        guard button > 2 else { return [] }
        return release { $0.mouseButton == button }
    }

    /// Releases everything that is pressed and forgets the list and the keys
    /// that were down.
    public mutating func stop() -> [KeybindEvent] {
        let released = active.map { KeybindEvent(actionId: $0, pressed: false) }
        active = []
        pressedKeys = []
        keybinds = []
        return released
    }

    /// Whether a key or a keybind's mouse button is believed to be down:
    /// whether there is anything `reconcile` could find let go.
    public var hasKeysDown: Bool {
        !pressedKeys.isEmpty || !active.isEmpty
    }

    /// Checks what is believed to be down against what really is, and lets
    /// go of what is not. The system can lose a release: while a password is
    /// typed it hides the keyboard from listeners, and it switches a
    /// listener off when it answers slowly. Without this a lost release
    /// would leave push-to-talk transmitting.
    ///
    /// - Parameters:
    ///   - keyIsDown: whether the key a keybind holds by this number is down.
    ///   - buttonIsDown: whether this mouse button, numbered as in
    ///     `Keybind.mouseButton`, is down.
    public mutating func reconcile(keyIsDown: (UInt32) -> Bool, buttonIsDown: (Int) -> Bool) -> [KeybindEvent] {
        var events: [KeybindEvent] = []
        for key in pressedKeys.sorted() where !keyIsDown(key) {
            events += keyUp(key)
        }
        let buttons = Set(active.compactMap { actionId in
            keybinds.first { $0.actionId == actionId }?.mouseButton
        })
        for button in buttons.sorted() where !buttonIsDown(button) {
            events += mouseUp(button)
        }
        return events
    }

    /// Presses the listed keybinds of this kind that are not pressed yet and
    /// have all their keys down.
    private mutating func press(_ isCandidate: (Keybind) -> Bool) -> [KeybindEvent] {
        var events: [KeybindEvent] = []
        for keybind in keybinds where isCandidate(keybind) && !active.contains(keybind.actionId) {
            guard keybind.keys.allSatisfy(pressedKeys.contains) else { continue }
            active.append(keybind.actionId)
            events.append(KeybindEvent(actionId: keybind.actionId, pressed: true))
        }
        return events
    }

    /// Releases the pressed actions whose keybind is over.
    private mutating func release(_ isOver: (Keybind) -> Bool) -> [KeybindEvent] {
        let ended = active.filter { actionId in
            guard let keybind = keybinds.first(where: { $0.actionId == actionId }) else { return false }
            return isOver(keybind)
        }
        active.removeAll(where: ended.contains)
        return ended.map { KeybindEvent(actionId: $0, pressed: false) }
    }
}

/// The modifier keys, which the system reports differently from the others:
/// not as a key going down or up but as a change of the flags, with the key
/// that changed them.
public enum ModifierKeys {
    /// The bit of the flags that is set while this very key is held. The
    /// flags have a shared bit for "a Shift is down" and, lower, a bit for
    /// each side; only the side's own bit says which key went up when both
    /// were held.
    private static let ownBits: [UInt16: UInt64] = [
        0x3B: 0x0001, // left Control
        0x38: 0x0002, // left Shift
        0x3C: 0x0004, // right Shift
        0x37: 0x0008, // left Command
        0x36: 0x0010, // right Command
        0x3A: 0x0020, // left Option
        0x3D: 0x0040, // right Option
        0x3E: 0x2000, // right Control
        0x39: 0x10000, // Caps Lock: set while its light is on
    ]

    /// Whether the modifier key with this code is down, by the flags that
    /// came with the change. Nil for a key that is not a modifier a keybind
    /// can hold.
    public static func isDown(keyCode: UInt16, flags: UInt64) -> Bool? {
        ownBits[keyCode].map { flags & $0 != 0 }
    }
}

/// What the system reports of the keyboard and the mouse, as the shell's
/// listener passes it on.
public enum KeyInput: Equatable {
    case keyDown(keyCode: UInt16)
    case keyUp(keyCode: UInt16)
    /// A modifier key changed the flags.
    case flagsChanged(keyCode: UInt16, flags: UInt64)
    /// A mouse button other than the left and the right one, numbered as the
    /// system numbers them: 2 is the middle button.
    case mouseDown(button: Int)
    case mouseUp(button: Int)
}

extension KeybindMatcher {
    /// Takes one report of the system and answers with the actions that
    /// begin or end. A key that has no code a keybind could hold is ignored.
    public mutating func handle(_ input: KeyInput) -> [KeybindEvent] {
        switch input {
        case .keyDown(let keyCode):
            return KeyCodes.hash(forVirtualKey: keyCode).map { keyDown($0) } ?? []
        case .keyUp(let keyCode):
            return KeyCodes.hash(forVirtualKey: keyCode).map { keyUp($0) } ?? []
        case .flagsChanged(let keyCode, let flags):
            guard
                let isDown = ModifierKeys.isDown(keyCode: keyCode, flags: flags),
                let key = KeyCodes.hash(forVirtualKey: keyCode)
            else { return [] }
            return isDown ? keyDown(key) : keyUp(key)
        // A keybind numbers the buttons from 1, as the Electron build's
        // listener does: the middle button is 3 there.
        case .mouseDown(let button):
            return mouseDown(button + 1)
        case .mouseUp(let button):
            return mouseUp(button + 1)
        }
    }
}
