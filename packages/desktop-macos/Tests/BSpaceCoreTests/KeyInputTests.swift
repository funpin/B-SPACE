import Foundation
import Testing
@testable import BSpaceCore

private let leftControl: UInt16 = 0x3B
private let rightControl: UInt16 = 0x3E
private let leftShift: UInt16 = 0x38
private let rightShift: UInt16 = 0x3C
private let leftCommand: UInt16 = 0x37
private let rightCommand: UInt16 = 0x36
private let leftOption: UInt16 = 0x3A
private let rightOption: UInt16 = 0x3D
private let capsLock: UInt16 = 0x39

@Suite struct ModifierKeysTests {
    @Test func tellsALeftKeyFromARightOne() {
        // The system reports each side with a bit of its own.
        #expect(ModifierKeys.isDown(keyCode: leftControl, flags: 0x40101) == true)
        #expect(ModifierKeys.isDown(keyCode: rightControl, flags: 0x40101) == false)
        #expect(ModifierKeys.isDown(keyCode: rightControl, flags: 0x42100) == true)
        #expect(ModifierKeys.isDown(keyCode: leftShift, flags: 0x20102) == true)
        #expect(ModifierKeys.isDown(keyCode: rightShift, flags: 0x20104) == true)
        #expect(ModifierKeys.isDown(keyCode: rightShift, flags: 0x20102) == false)
        #expect(ModifierKeys.isDown(keyCode: leftCommand, flags: 0x100108) == true)
        #expect(ModifierKeys.isDown(keyCode: rightCommand, flags: 0x100110) == true)
        #expect(ModifierKeys.isDown(keyCode: leftOption, flags: 0x80120) == true)
        #expect(ModifierKeys.isDown(keyCode: rightOption, flags: 0x80140) == true)
    }

    @Test func oneSideLetGoWhileTheOtherIsHeldIsUp() {
        // Both Shifts down, then the left one released: the shared Shift bit
        // stays set, the left key's own bit is gone.
        #expect(ModifierKeys.isDown(keyCode: leftShift, flags: 0x20104) == false)
        #expect(ModifierKeys.isDown(keyCode: rightShift, flags: 0x20104) == true)
    }

    @Test func capsLockIsDownWhileItsLightIsOn() {
        #expect(ModifierKeys.isDown(keyCode: capsLock, flags: 0x10100) == true)
        #expect(ModifierKeys.isDown(keyCode: capsLock, flags: 0x100) == false)
    }

    @Test func aKeyThatIsNotAModifierHasNoAnswer() {
        #expect(ModifierKeys.isDown(keyCode: 0x00, flags: 0x100) == nil)
        // Fn changes the flags and is no key a keybind can hold.
        #expect(ModifierKeys.isDown(keyCode: 0x3F, flags: 0x800100) == nil)
    }
}

private let a = KeyCodes.hash("KeyA")
private let control = KeyCodes.hash("ControlLeft")

@Suite struct KeyInputTests {
    private func matcher(_ keybinds: [Keybind]) -> KeybindMatcher {
        var matcher = KeybindMatcher()
        _ = matcher.update(keybinds)
        return matcher
    }

    @Test func aKeyOfTheSystemPressesAndReleasesItsAction() {
        var matcher = matcher([Keybind(actionId: "talk", keys: [a])])
        #expect(matcher.handle(.keyDown(keyCode: 0x00)) == [KeybindEvent(actionId: "talk", pressed: true)])
        #expect(matcher.handle(.keyDown(keyCode: 0x00)).isEmpty)
        #expect(matcher.handle(.keyUp(keyCode: 0x00)) == [KeybindEvent(actionId: "talk", pressed: false)])
    }

    @Test func aModifierGoesDownAndUpByItsOwnBit() {
        var matcher = matcher([Keybind(actionId: "talk", keys: [control, a])])
        #expect(matcher.handle(.flagsChanged(keyCode: leftControl, flags: 0x40101)).isEmpty)
        #expect(matcher.handle(.keyDown(keyCode: 0x00)) == [KeybindEvent(actionId: "talk", pressed: true)])
        #expect(matcher.handle(.flagsChanged(keyCode: leftControl, flags: 0x100)) == [KeybindEvent(actionId: "talk", pressed: false)])
    }

    @Test func aKeyWithNoCodeIsIgnored() {
        var matcher = matcher([Keybind(actionId: "talk", keys: [a])])
        // 0x0A is the key beside the left Shift of an ISO keyboard.
        #expect(matcher.handle(.keyDown(keyCode: 0x0A)).isEmpty)
        #expect(matcher.handle(.flagsChanged(keyCode: 0x3F, flags: 0x800100)).isEmpty)
    }

    @Test func theSystemsMouseButtonsAreNumberedOneLower() {
        var matcher = matcher([
            Keybind(actionId: "middle", keys: [], mouseButton: 3),
            Keybind(actionId: "back", keys: [], mouseButton: 4),
        ])
        // The system counts from 0: 2 is the middle button, 3 the one after it.
        #expect(matcher.handle(.mouseDown(button: 2)) == [KeybindEvent(actionId: "middle", pressed: true)])
        #expect(matcher.handle(.mouseUp(button: 2)) == [KeybindEvent(actionId: "middle", pressed: false)])
        #expect(matcher.handle(.mouseDown(button: 3)) == [KeybindEvent(actionId: "back", pressed: true)])
        // The left and right buttons never reach a keybind.
        #expect(matcher.handle(.mouseDown(button: 0)).isEmpty)
        #expect(matcher.handle(.mouseDown(button: 1)).isEmpty)
    }
}

@Suite struct KeybindReconcileTests {
    private let shift = KeyCodes.hash("ShiftLeft")

    @Test func namesTheSystemsKeyOfACode() {
        #expect(KeyCodes.virtualKey(forHash: KeyCodes.hash("KeyA")) == 0x00)
        #expect(KeyCodes.virtualKey(forHash: KeyCodes.hash("ControlLeft")) == 0x3B)
        #expect(KeyCodes.virtualKey(forHash: 12345) == nil)
    }

    @Test func aKeyThatIsNoLongerDownReleasesItsAction() {
        var matcher = KeybindMatcher()
        _ = matcher.update([Keybind(actionId: "talk", keys: [a]), Keybind(actionId: "combo", keys: [control, shift])])
        _ = matcher.keyDown(a)
        _ = matcher.keyDown(control)
        _ = matcher.keyDown(shift)
        #expect(!matcher.hasKeysDown == false)
        // Everything is still held: nothing changes.
        #expect(matcher.reconcile(keyIsDown: { _ in true }, buttonIsDown: { _ in true }).isEmpty)
        // The release of A never arrived.
        let released = matcher.reconcile(keyIsDown: { $0 != a }, buttonIsDown: { _ in true })
        #expect(released == [KeybindEvent(actionId: "talk", pressed: false)])
        // It is not released twice, and the key can be pressed again.
        #expect(matcher.reconcile(keyIsDown: { $0 != a }, buttonIsDown: { _ in true }).isEmpty)
        #expect(matcher.keyDown(a) == [KeybindEvent(actionId: "talk", pressed: true)])
    }

    @Test func aMouseButtonThatIsNoLongerDownReleasesItsAction() {
        var matcher = KeybindMatcher()
        _ = matcher.update([Keybind(actionId: "side", keys: [], mouseButton: 4)])
        _ = matcher.mouseDown(4)
        #expect(matcher.hasKeysDown)
        #expect(matcher.reconcile(keyIsDown: { _ in true }, buttonIsDown: { _ in true }).isEmpty)
        #expect(matcher.reconcile(keyIsDown: { _ in true }, buttonIsDown: { $0 != 4 })
            == [KeybindEvent(actionId: "side", pressed: false)])
        #expect(!matcher.hasKeysDown)
    }

    @Test func withNothingDownThereIsNothingToAsk() {
        var matcher = KeybindMatcher()
        _ = matcher.update([Keybind(actionId: "talk", keys: [a])])
        #expect(!matcher.hasKeysDown)
        var asked = 0
        _ = matcher.reconcile(keyIsDown: { _ in asked += 1; return false }, buttonIsDown: { _ in asked += 1; return false })
        #expect(asked == 0)
    }
}
