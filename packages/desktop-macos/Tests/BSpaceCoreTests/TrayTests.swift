import Foundation
import Testing
@testable import BSpaceCore

/// `packages/desktop`, found from this file's place in the repository.
private let desktopPackage = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("desktop")

private func strings() throws -> DesktopStrings {
    try DesktopStrings(data: Data(contentsOf: desktopPackage.appendingPathComponent("src/desktopStrings.json")))
}

@Suite struct TrayStateTests {
    @Test func readsEveryStateThePageCanReport() {
        for name in ["idle", "look", "notify", "typing", "voice", "screen", "joy", "dnd", "offline"] {
            #expect(TrayState(arguments: BridgeArguments([name]))?.rawValue == name)
        }
        #expect(TrayState.allCases.count == 9)
    }

    @Test func refusesAnythingElse() {
        let cases: [[Any]] = [[], [""], ["Idle"], ["busy"], [1], [NSNull()], [["state": "idle"]], [true]]
        for arguments in cases {
            #expect(TrayState(arguments: BridgeArguments(arguments)) == nil)
        }
    }
}

@Suite struct TrayFrameTests {
    @Test func namesTheTemplateImageOfAFrame() {
        #expect(TrayFrame.idle.resourceName == "tray-idleTemplate")
        #expect(TrayFrame.lookLeft.resourceName == "tray-look-leftTemplate")
        #expect(TrayFrame.allCases.count == 16)
    }

    @Test func everyFrameHasItsImagesInTheDesktopPackage() {
        let resources = desktopPackage.appendingPathComponent("resources")
        for frame in TrayFrame.allCases {
            for suffix in ["", "@2x"] {
                let file = resources.appendingPathComponent("\(frame.resourceName)\(suffix).png")
                #expect(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) is missing")
            }
        }
    }

    @Test func noFrameIsLeftUnplayed() {
        let played = Set(TrayState.allCases.flatMap { TrayAnimations.loop(for: $0).map(\.frame) })
        #expect(played == Set(TrayFrame.allCases))
    }
}

@Suite struct TrayAnimationsTests {
    @Test func everyFrameOfAMovingLoopHasADuration() {
        for state in TrayState.allCases {
            let loop = TrayAnimations.loop(for: state)
            #expect(!loop.isEmpty)
            if loop.count > 1 {
                #expect(loop.allSatisfy { $0.milliseconds > 0 }, "\(state.rawValue)")
            }
        }
    }

    @Test func blinksWhileIdleOnceEveryThreeToFourSeconds() {
        let loop = TrayAnimations.loop(for: .idle)
        #expect(loop.map(\.frame) == [.idle, .blink])
        let cycle = loop.reduce(0) { $0 + $1.milliseconds }
        #expect(cycle >= 3000 && cycle <= 4000)
    }

    @Test func matchesTheLoopsOfTheElectronBuild() {
        func steps(_ state: TrayState) -> [String] {
            TrayAnimations.loop(for: state).map { "\($0.frame.rawValue):\($0.milliseconds)" }
        }
        #expect(steps(.look) == ["look-left:1300", "idle:300", "look-right:1300", "idle:1450", "blink:150"])
        #expect(steps(.notify) == ["notify:1900", "notify-up:160", "notify:110", "notify-up:110"])
        #expect(steps(.typing) == ["typing-a:300", "typing-b:300", "typing:600"])
        #expect(steps(.voice) == ["voice:450", "idle:250"])
        #expect(steps(.screen) == ["screen:1000", "screen-dim:600"])
        #expect(steps(.joy) == ["joy-up:180", "joy:1600"])
        #expect(steps(.dnd) == ["dnd:0"])
        #expect(steps(.offline) == ["offline:0"])
    }
}

@Suite struct TrayAnimatorTests {
    @Test func playsAStatesLoopFrameByFrameAndStartsOver() {
        var animator = TrayAnimator()
        #expect(animator.set(.typing, reducedMotion: false) == [.show(.typingA), .schedule(milliseconds: 300)])
        #expect(animator.timerFired(reducedMotion: false) == [.show(.typingB), .schedule(milliseconds: 300)])
        #expect(animator.timerFired(reducedMotion: false) == [.show(.typing), .schedule(milliseconds: 600)])
        #expect(animator.timerFired(reducedMotion: false) == [.show(.typingA), .schedule(milliseconds: 300)])
    }

    @Test func keepsItsPlaceWhenTheSameStateIsReportedAgain() {
        var animator = TrayAnimator()
        _ = animator.set(.typing, reducedMotion: false)
        _ = animator.timerFired(reducedMotion: false)
        #expect(animator.set(.typing, reducedMotion: false).isEmpty)
        #expect(animator.timerFired(reducedMotion: false) == [.show(.typing), .schedule(milliseconds: 600)])
    }

    @Test func dropsTheOldLoopsTimerWhenTheStateChanges() {
        var animator = TrayAnimator()
        _ = animator.set(.typing, reducedMotion: false)
        #expect(animator.set(.dnd, reducedMotion: false) == [.cancel, .show(.dnd)])
        // A still state has no timer to drop.
        #expect(animator.set(.offline, reducedMotion: false) == [.show(.offline)])
        #expect(animator.state == .offline)
    }

    @Test func skipsAFrameThatIsAlreadyOnScreen() {
        var animator = TrayAnimator()
        _ = animator.set(.voice, reducedMotion: false)
        // The voice loop ends on the idle frame, which is where idle starts.
        #expect(animator.timerFired(reducedMotion: false) == [.show(.idle), .schedule(milliseconds: 250)])
        #expect(animator.set(.idle, reducedMotion: false) == [.cancel, .schedule(milliseconds: 3400)])
    }

    @Test func showsOnlyTheStillFrameUnderReducedMotion() {
        var animator = TrayAnimator()
        #expect(animator.set(.typing, reducedMotion: true) == [.show(.typingA)])
        // The setting is read at each step: turned on mid-loop, the loop stops there.
        #expect(animator.set(.look, reducedMotion: false) == [.show(.lookLeft), .schedule(milliseconds: 1300)])
        #expect(animator.timerFired(reducedMotion: true) == [.show(.idle)])
    }

    @Test func stopsWithoutForgettingTheState() {
        var animator = TrayAnimator()
        _ = animator.set(.typing, reducedMotion: false)
        #expect(animator.stop() == [.cancel])
        #expect(animator.stop().isEmpty)
        #expect(animator.state == .typing)
        #expect(animator.set(.typing, reducedMotion: false).isEmpty)
    }

    @Test func aTimerThatFiresWithNothingPlayingDoesNothing() {
        var animator = TrayAnimator()
        #expect(animator.timerFired(reducedMotion: false).isEmpty)
        _ = animator.set(.dnd, reducedMotion: false)
        #expect(animator.timerFired(reducedMotion: false).isEmpty)
    }
}

private func readContext(_ value: [String: Any]) -> TrayContext? {
    TrayContext(arguments: BridgeArguments([value]))
}

private let inCall: [String: Any] = [
    "signedIn": true, "voice": ["channelName": "General"], "muted": true, "deafened": false, "status": "online",
]

@Suite struct TrayContextTests {
    @Test func readsAWellFormedContext() throws {
        let read = try #require(readContext(inCall))
        #expect(read == TrayContext(signedIn: true, voiceChannelName: "General", muted: true, deafened: false, status: .online))

        let signedOut = try #require(readContext(["signedIn": false, "voice": NSNull(), "muted": false, "deafened": false, "status": NSNull()]))
        #expect(signedOut == .empty)
    }

    @Test func refusesAnythingMalformed() {
        func changed(_ key: String, _ value: Any?) -> [String: Any] {
            var copy = inCall
            copy[key] = value
            return copy
        }
        let cases: [[String: Any]] = [
            [:],
            changed("signedIn", nil),
            changed("signedIn", "yes"),
            changed("signedIn", 1),
            changed("muted", NSNull()),
            changed("deafened", 0),
            changed("status", "busy"),
            changed("status", nil),
            changed("voice", nil),
            changed("voice", "General"),
            changed("voice", ["name": "General"]),
            changed("voice", ["channelName": 5]),
        ]
        for value in cases {
            #expect(readContext(value) == nil)
        }
        #expect(TrayContext(arguments: BridgeArguments([])) == nil)
        #expect(TrayContext(arguments: BridgeArguments(["context"])) == nil)
    }

    @Test func shortensALongChannelNameForTheMenu() throws {
        var long = inCall
        long["voice"] = ["channelName": "  " + String(repeating: "x", count: 60) + "  "]
        let name = try #require(readContext(long)?.voiceChannelName)
        #expect(name == String(repeating: "x", count: 39) + "…")

        var exact = inCall
        exact["voice"] = ["channelName": String(repeating: "y", count: 40)]
        #expect(readContext(exact)?.voiceChannelName == String(repeating: "y", count: 40))
    }
}

@Suite struct TrayContextNativeFieldsTests {
    @Test func readsAContextOfAnOlderWebClient() throws {
        let read = try #require(readContext(inCall))
        #expect(read.cameraOn == nil)
        #expect(read.screenSharing == nil)
        #expect(read.showPointers == nil)
    }

    @Test func readsTheNewFields() throws {
        var value = inCall
        value["cameraOn"] = true
        value["screenSharing"] = false
        value["showPointers"] = true
        let read = try #require(readContext(value))
        #expect(read.cameraOn == true)
        #expect(read.screenSharing == false)
        #expect(read.showPointers == true)
    }

    @Test func refusesANewFieldOfTheWrongType() {
        let wrong: [(String, Any)] = [("cameraOn", "yes"), ("screenSharing", 1), ("showPointers", NSNull())]
        for (key, value) in wrong {
            var context = inCall
            context[key] = value
            #expect(readContext(context) == nil, "\(key)")
        }
    }
}

@Suite struct TrayActionTests {
    @Test func saysWhatThePageIsSent() {
        #expect(TrayAction.toggleMute.bridgeValue as? [String: String] == ["type": "toggleMute"])
        #expect(TrayAction.toggleDeafen.bridgeValue as? [String: String] == ["type": "toggleDeafen"])
        #expect(TrayAction.disconnect.bridgeValue as? [String: String] == ["type": "disconnect"])
        #expect(TrayAction.setStatus(.dnd).bridgeValue as? [String: String] == ["type": "setStatus", "status": "dnd"])
        #expect(TrayAction.toggleShowPointers.bridgeValue as? [String: String] == ["type": "toggleShowPointers"])
        #expect(TrayAction.stopCamera.bridgeValue as? [String: String] == ["type": "stopCamera"])
        #expect(TrayAction.stopScreenShare.bridgeValue as? [String: String] == ["type": "stopScreenShare"])
    }
}

@Suite struct TrayMenuTests {
    /// One string per item. A row of controls is in brackets: each control
    /// by its kind, "/red" or "/accent" for its tone, "!" when choosing it
    /// closes the menu.
    private func describe(_ items: [TrayMenuItem]) -> [String] {
        items.map {
            switch $0 {
            case .separator: return "—"
            case .label(let title): return "(\(title))"
            case .action(let title, _): return title
            case .toggle(let title, let isOn, _): return (isOn ? "✓ " : "") + title
            case .controls(let controls):
                let parts: [String] = controls.map { control in
                    let kind: String
                    switch control.kind {
                    case .microphone(let isOn): kind = "mic:" + (isOn ? "on" : "off")
                    case .sound(let isOn): kind = "sound:" + (isOn ? "on" : "off")
                    case .pointers(let isOn): kind = "pointers:" + (isOn ? "on" : "off")
                    case .stopCamera: kind = "camera"
                    case .stopScreenShare: kind = "share"
                    case .disconnect: kind = "leave"
                    }
                    let tone: String
                    switch control.tone {
                    case .plain: tone = ""
                    case .danger: tone = "/red"
                    case .accent: tone = "/accent"
                    }
                    return kind + tone + (control.closesMenu ? "!" : "")
                }
                return "[" + parts.joined(separator: " ") + "]"
            }
        }
    }

    private func controls(_ items: [TrayMenuItem]) -> [TrayControl] {
        items.flatMap { item -> [TrayControl] in
            if case .controls(let row) = item { return row }
            return []
        }
    }

    private let everything = TrayContext(
        signedIn: true, voiceChannelName: "General", muted: true, deafened: false, status: .online,
        cameraOn: true, screenSharing: true, showPointers: true
    )

    @Test func offersOnlyOpenAndQuitBeforeSignIn() throws {
        let strings = try strings()
        let items = TrayMenu.items(context: .empty, strings: strings, language: strings.english)
        #expect(describe(items) == ["Show B:SPACE", "—", "Quit"])
    }

    @Test func showsTheRowOfControlsInACall() throws {
        let strings = try strings()
        let items = TrayMenu.items(context: everything, strings: strings, language: strings.english)
        #expect(describe(items) == [
            "(In voice: General)",
            "[mic:off/red sound:on pointers:on/accent camera/red! share/red! leave!]",
            "—", "Do Not Disturb", "Show B:SPACE", "—", "Quit",
        ])
    }

    @Test func anOlderWebClientGetsTheControlsItKnows() throws {
        let strings = try strings()
        let context = try #require(readContext(inCall))
        let items = TrayMenu.items(context: context, strings: strings, language: strings.english)
        #expect(describe(items)[1] == "[mic:off/red sound:on leave!]")
    }

    @Test func leavesOutWhatIsNotGoingOn() throws {
        let strings = try strings()
        // In a call with the camera off, nothing shared and the pointers hidden.
        var quiet = everything
        quiet.cameraOn = false
        quiet.screenSharing = false
        quiet.showPointers = false
        quiet.muted = false
        #expect(describe(TrayMenu.items(context: quiet, strings: strings, language: strings.english))[1]
            == "[mic:on sound:on pointers:off leave!]")

        // Outside a call: no call to name, to point in or to leave.
        let outside = TrayContext(
            signedIn: true, voiceChannelName: nil, muted: false, deafened: true, status: nil,
            cameraOn: false, screenSharing: false, showPointers: true
        )
        #expect(describe(TrayMenu.items(context: outside, strings: strings, language: strings.english))
            == ["[mic:on sound:off/red]", "—", "Show B:SPACE", "—", "Quit"])
    }

    @Test func doNotDisturbTogglesBetweenDndAndOnline() throws {
        let strings = try strings()
        func row(_ status: TrayStatus?) -> TrayMenuItem? {
            var context = everything
            context.status = status
            return TrayMenu.items(context: context, strings: strings, language: strings.english).first {
                if case .toggle = $0 { return true }
                return false
            }
        }
        #expect(row(.online) == .toggle(title: "Do Not Disturb", isOn: false, command: .control(.setStatus(.dnd))))
        #expect(row(.idle) == .toggle(title: "Do Not Disturb", isOn: false, command: .control(.setStatus(.dnd))))
        #expect(row(.dnd) == .toggle(title: "Do Not Disturb", isOn: true, command: .control(.setStatus(.online))))
        #expect(row(nil) == nil)
    }

    @Test func eachItemCarriesWhatItDoes() throws {
        let strings = try strings()
        let items = TrayMenu.items(context: everything, strings: strings, language: strings.english)
        #expect(controls(items).map(\.command) == [
            .control(.toggleMute), .control(.toggleDeafen), .control(.toggleShowPointers),
            .control(.stopCamera), .control(.stopScreenShare), .control(.disconnect),
        ])
        let rest: [TrayMenuCommand] = items.compactMap {
            if case .action(_, let command) = $0 { return command }
            return nil
        }
        #expect(rest == [.show, .quit])
    }

    @Test func aControlSaysWhatItIsAndTheStateItIsIn() throws {
        let strings = try strings()
        let items = TrayMenu.items(context: everything, strings: strings, language: strings.english)
        #expect(controls(items).map(\.title) == [
            "Microphone is off", "Sound is on", "Viewers' pointers are shown",
            "Turn off camera", "Stop sharing", "Disconnect",
        ])
        var other = everything
        other.muted = false
        other.deafened = true
        other.showPointers = false
        let titles = controls(TrayMenu.items(context: other, strings: strings, language: strings.english)).map(\.title)
        #expect(Array(titles.prefix(3)) == ["Microphone is on", "Sound is off", "Viewers' pointers are hidden"])
    }

    @Test func speaksTheSelectedLanguage() throws {
        let strings = try strings()
        let russian = try #require(strings.language(code: "ru"))
        let items = TrayMenu.items(context: everything, strings: strings, language: russian)
        #expect(describe(items).first == "(В голосовом: General)")
        #expect(controls(items).first?.title == "Микрофон выключен")
        for language in strings.languages {
            let all = TrayMenu.items(context: everything, strings: strings, language: language)
            let titles = describe(all) + controls(all).map(\.title)
            #expect(titles.allSatisfy { !$0.isEmpty && !$0.contains("{") }, "\(language.code)")
        }
    }
}
