import Foundation
import Testing
@testable import BSpaceCore

/// `packages/desktop/src/keybindManager.ts`, found from this file's place in
/// the repository.
private let electronKeybindManager = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("desktop/src/keybindManager.ts")

/// The DOM codes of the Electron build's table, read from its source: every
/// `number: 'Code'` between the table's opening line and its closing brace.
private func electronDomCodes() throws -> Set<String> {
    let source = try String(contentsOf: electronKeybindManager, encoding: .utf8)
    let start = try #require(source.range(of: "const UIOHOOK_TO_DOM_CODE: Record<number, string> = {"))
    let end = try #require(source.range(of: "\n};", range: start.upperBound..<source.endIndex))
    let table = String(source[start.upperBound..<end.lowerBound])
    let entry = try NSRegularExpression(pattern: #"\d+:\s*'([A-Za-z0-9]+)'"#)
    let matches = entry.matches(in: table, range: NSRange(table.startIndex..., in: table))
    return Set(matches.compactMap { Range($0.range(at: 1), in: table).map { String(table[$0]) } })
}

@Suite struct KeyCodesTests {
    @Test func hashesACodeTheWayTheWebClientDoes() {
        // Values from the web client's own function (djb2 over UTF-16 units,
        // wrapped to 32 bits), computed with Node.
        #expect(KeyCodes.hash("KeyA") == 2_089_282_927)
        #expect(KeyCodes.hash("Space") == 236_717_617)
        #expect(KeyCodes.hash("ControlLeft") == 12_096_465)
        #expect(KeyCodes.hash("NumpadDivide") == 572_000_063)
        #expect(KeyCodes.hash("F13") == 193_454_895)
        #expect(KeyCodes.hash("") == 5381)
        #expect(KeyCodes.hash("ArrowRightArrowRightArrowRightArrowRightArrowRight") == 4_055_810_834)
        #expect(KeyCodes.hash("ж\u{1F600}") == 196_434_552)
    }

    @Test func knowsEveryKeyOfTheElectronTableThatAMacHas() throws {
        let electron = try electronDomCodes()
        #expect(electron.count > 100)
        let native = Set(KeyCodes.domCodes.values)
        // Nothing here the web client could not have recorded for Electron,
        // and nothing of Electron's missing but the keys no Mac keyboard has.
        #expect(native.isSubset(of: electron))
        #expect(electron.subtracting(native) == KeyCodes.withoutAMacKey)
        #expect(native.isDisjoint(with: KeyCodes.withoutAMacKey))
    }

    @Test func givesEveryKeyItsOwnCode() {
        #expect(Set(KeyCodes.domCodes.values).count == KeyCodes.domCodes.count)
    }

    @Test func mapsTheSystemsKeyCodes() {
        #expect(KeyCodes.domCodes[0x00] == "KeyA")
        #expect(KeyCodes.domCodes[0x31] == "Space")
        #expect(KeyCodes.domCodes[0x24] == "Enter")
        #expect(KeyCodes.domCodes[0x33] == "Backspace")
        #expect(KeyCodes.domCodes[0x75] == "Delete")
        #expect(KeyCodes.domCodes[0x3B] == "ControlLeft")
        #expect(KeyCodes.domCodes[0x3E] == "ControlRight")
        #expect(KeyCodes.domCodes[0x37] == "MetaLeft")
        #expect(KeyCodes.domCodes[0x36] == "MetaRight")
        #expect(KeyCodes.domCodes[0x3A] == "AltLeft")
        #expect(KeyCodes.domCodes[0x7E] == "ArrowUp")
        #expect(KeyCodes.domCodes[0x4B] == "NumpadDivide")
        // As Chromium names them on a Mac keyboard.
        #expect(KeyCodes.domCodes[0x47] == "NumLock")
        #expect(KeyCodes.domCodes[0x72] == "Insert")
        #expect(KeyCodes.hash(forVirtualKey: 0x00) == 2_089_282_927)
        // The Fn key has no code a keybind could hold.
        #expect(KeyCodes.hash(forVirtualKey: 0x3F) == nil)
    }
}

private let a = KeyCodes.hash("KeyA")
private let b = KeyCodes.hash("KeyB")
private let control = KeyCodes.hash("ControlLeft")

private func bind(_ action: String, _ keys: [UInt32], mouse: Int? = nil) -> Keybind {
    Keybind(actionId: action, keys: keys, mouseButton: mouse)
}

private func on(_ action: String) -> KeybindEvent { KeybindEvent(actionId: action, pressed: true) }
private func off(_ action: String) -> KeybindEvent { KeybindEvent(actionId: action, pressed: false) }

@Suite struct KeybindTests {
    @Test func readsWhatThePageSyncs() throws {
        let list = try #require(Keybind.list(arguments: BridgeArguments([[
            ["actionId": "pushToTalk", "keys": [2_089_282_927, 12_096_465]],
            ["actionId": "toggleMute", "keys": [Int](), "mouseButton": 4],
            ["actionId": "deafen", "keys": [5381], "mouseButton": NSNull()],
        ]])))
        #expect(list == [
            bind("pushToTalk", [2_089_282_927, 12_096_465]),
            bind("toggleMute", [], mouse: 4),
            bind("deafen", [5381]),
        ])
        #expect(Keybind.list(arguments: BridgeArguments([[Any]()])) == [])
    }

    @Test func aMouseButtonOfZeroIsNoMouseButton() throws {
        let list = try #require(Keybind.list(arguments: BridgeArguments([[["actionId": "x", "keys": [1], "mouseButton": 0]]])))
        #expect(list == [bind("x", [1])])
    }

    @Test func refusesAnythingThatIsNotAListOfKeybinds() {
        let cases: [[Any]] = [
            [],
            [NSNull()],
            ["pushToTalk"],
            [["actionId": "x", "keys": [1]]],
            [[["keys": [1]]]],
            [[["actionId": "", "keys": [1]]]],
            [[["actionId": 5, "keys": [1]]]],
            [[["actionId": "x"]]],
            [[["actionId": "x", "keys": "1"]]],
            [[["actionId": "x", "keys": ["1"]]]],
            [[["actionId": "x", "keys": [-1]]]],
            [[["actionId": "x", "keys": [1.5]]]],
            [[["actionId": "x", "keys": [4_294_967_296]]]],
            [[["actionId": "x", "keys": [true]]]],
            [[["actionId": "x", "keys": [1], "mouseButton": "4"]]],
            [[["actionId": "x", "keys": [1], "mouseButton": 2.5]]],
            [[["actionId": "x", "keys": [1]], "y"]],
        ]
        for arguments in cases {
            #expect(Keybind.list(arguments: BridgeArguments(arguments)) == nil)
        }
    }

    @Test func saysWhatThePageIsSent() {
        let event = on("pushToTalk").bridgeValue
        #expect(event["actionId"] as? String == "pushToTalk")
        #expect(event["pressed"] as? Bool == true)
        #expect(off("pushToTalk").bridgeValue["pressed"] as? Bool == false)
    }
}

@Suite struct KeybindMatcherTests {
    @Test func aKeyPressesAndReleasesItsAction() {
        var matcher = KeybindMatcher()
        #expect(matcher.update([bind("talk", [a])]).isEmpty)
        #expect(matcher.keyDown(a) == [on("talk")])
        #expect(matcher.keyUp(a) == [off("talk")])
        #expect(matcher.keyUp(a).isEmpty)
    }

    @Test func aHeldKeyDoesNotPressTwice() {
        var matcher = KeybindMatcher()
        _ = matcher.update([bind("talk", [a])])
        _ = matcher.keyDown(a)
        // The system repeats the press while the key is held.
        #expect(matcher.keyDown(a).isEmpty)
        #expect(matcher.keyDown(a).isEmpty)
        #expect(matcher.keyUp(a) == [off("talk")])
    }

    @Test func aCombinationNeedsAllItsKeysAndEndsWhenOneIsLetGo() {
        var matcher = KeybindMatcher()
        _ = matcher.update([bind("talk", [control, a])])
        #expect(matcher.keyDown(control).isEmpty)
        #expect(matcher.keyDown(b).isEmpty)
        #expect(matcher.keyDown(a) == [on("talk")])
        // A key that is not part of it changes nothing.
        #expect(matcher.keyUp(b).isEmpty)
        #expect(matcher.keyUp(control) == [off("talk")])
        #expect(matcher.keyUp(a).isEmpty)
        // Pressed again in the other order.
        #expect(matcher.keyDown(a).isEmpty)
        #expect(matcher.keyDown(control) == [on("talk")])
    }

    @Test func oneKeyCanPressSeveralActionsInTheOrderTheyAreListed() {
        var matcher = KeybindMatcher()
        _ = matcher.update([bind("first", [a]), bind("second", [a]), bind("third", [control, a])])
        #expect(matcher.keyDown(a) == [on("first"), on("second")])
        #expect(matcher.keyDown(control) == [on("third")])
        #expect(matcher.keyUp(a) == [off("first"), off("second"), off("third")])
    }

    @Test func aKeybindWithNothingInItNeverFires() {
        var matcher = KeybindMatcher()
        _ = matcher.update([bind("empty", [])])
        #expect(matcher.keyDown(a).isEmpty)
        #expect(matcher.mouseDown(4).isEmpty)
    }

    @Test func aMouseButtonPressesItsActionWithTheKeysHeld() {
        var matcher = KeybindMatcher()
        _ = matcher.update([bind("talk", [], mouse: 4), bind("mute", [control], mouse: 5)])
        #expect(matcher.mouseDown(4) == [on("talk")])
        #expect(matcher.mouseDown(4).isEmpty)
        #expect(matcher.mouseUp(4) == [off("talk")])
        // The other needs Control held when the button goes down.
        #expect(matcher.mouseDown(5).isEmpty)
        _ = matcher.mouseUp(5)
        _ = matcher.keyDown(control)
        #expect(matcher.mouseDown(5) == [on("mute")])
        // Letting the key go does not end it: the button does.
        #expect(matcher.keyUp(control).isEmpty)
        #expect(matcher.mouseUp(5) == [off("mute")])
    }

    @Test func theKeysOfAMouseKeybindAloneDoNothing() {
        var matcher = KeybindMatcher()
        _ = matcher.update([bind("mute", [control], mouse: 5)])
        #expect(matcher.keyDown(control).isEmpty)
        #expect(matcher.keyUp(control).isEmpty)
    }

    @Test func theLeftAndRightButtonsAreNeverKeybinds() {
        var matcher = KeybindMatcher()
        _ = matcher.update([bind("left", [], mouse: 1), bind("right", [], mouse: 2), bind("middle", [], mouse: 3)])
        #expect(matcher.mouseDown(1).isEmpty)
        #expect(matcher.mouseDown(2).isEmpty)
        #expect(matcher.mouseUp(1).isEmpty)
        #expect(matcher.mouseDown(3) == [on("middle")])
    }

    @Test func anActionTakenAwayWhilePressedIsReleased() {
        var matcher = KeybindMatcher()
        _ = matcher.update([bind("talk", [a]), bind("mute", [b])])
        _ = matcher.keyDown(a)
        _ = matcher.keyDown(b)
        #expect(matcher.update([bind("mute", [b])]) == [off("talk")])
        // What stays keeps going.
        #expect(matcher.keyUp(b) == [off("mute")])
    }

    @Test func stoppingReleasesEverythingAndForgetsTheKeys() {
        var matcher = KeybindMatcher()
        _ = matcher.update([bind("talk", [a]), bind("mute", [], mouse: 4)])
        _ = matcher.keyDown(a)
        _ = matcher.mouseDown(4)
        #expect(matcher.stop() == [off("talk"), off("mute")])
        #expect(matcher.isEmpty)
        #expect(matcher.stop().isEmpty)
        // A key that was down when it stopped is not down afterwards.
        _ = matcher.update([bind("combo", [a, b])])
        #expect(matcher.keyDown(b).isEmpty)
    }

    @Test func saysWhetherThereIsAnythingToListenFor() {
        var matcher = KeybindMatcher()
        #expect(matcher.isEmpty)
        _ = matcher.update([bind("talk", [a])])
        #expect(!matcher.isEmpty)
        _ = matcher.update([])
        #expect(matcher.isEmpty)
    }
}
