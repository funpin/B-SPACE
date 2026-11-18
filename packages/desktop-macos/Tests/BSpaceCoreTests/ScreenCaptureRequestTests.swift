import Foundation
import Testing
@testable import BSpaceCore

private func arguments(_ options: [String: Any]) -> BridgeArguments {
    BridgeArguments([options])
}

@Suite struct ScreenCaptureRequestTests {
    @Test func readsWhatThePageAsksFor() {
        let request = ScreenCaptureRequest(arguments: arguments([
            "sourceId": "screen:1:0", "maxWidth": 2560, "maxHeight": 1440, "frameRate": 60,
        ]))
        #expect(request == ScreenCaptureRequest(source: .display(1), maxWidth: 2560, maxHeight: 1440, framesPerSecond: 60))
        #expect(ScreenCaptureRequest(arguments: arguments(["sourceId": "window:4821:0"]))?.source == .window(4821))
    }

    @Test func aRequestWithoutASourceIsNotOne() {
        #expect(ScreenCaptureRequest(arguments: BridgeArguments([])) == nil)
        #expect(ScreenCaptureRequest(arguments: BridgeArguments(["screen:1:0"])) == nil)
        #expect(ScreenCaptureRequest(arguments: arguments(["maxWidth": 1920])) == nil)
        #expect(ScreenCaptureRequest(arguments: arguments(["sourceId": 1])) == nil)
        #expect(ScreenCaptureRequest(arguments: arguments(["sourceId": "tab:1:0"])) == nil)
    }

    @Test func whatIsMissingOrOutOfBoundsIsBroughtIntoThem() throws {
        let bare = try #require(ScreenCaptureRequest(arguments: arguments(["sourceId": "screen:1:0"])))
        #expect(bare.maxWidth == 8192)
        #expect(bare.maxHeight == 8192)
        #expect(bare.framesPerSecond == 30)

        let wild = try #require(ScreenCaptureRequest(arguments: arguments([
            "sourceId": "screen:1:0", "maxWidth": 1, "maxHeight": 1_000_000, "frameRate": 240,
        ])))
        #expect(wild.maxWidth == 160)
        #expect(wild.maxHeight == 8192)
        #expect(wild.framesPerSecond == 60)

        let odd = try #require(ScreenCaptureRequest(arguments: arguments([
            "sourceId": "screen:1:0", "maxWidth": "1920", "maxHeight": true, "frameRate": 0,
        ])))
        #expect(odd.maxWidth == 8192)
        #expect(odd.maxHeight == 8192)
        #expect(odd.framesPerSecond == 1)

        let fraction = try #require(ScreenCaptureRequest(arguments: arguments([
            "sourceId": "screen:1:0", "maxWidth": 1919.6, "frameRate": 59.94,
        ])))
        #expect(fraction.maxWidth == 1920)
        #expect(fraction.framesPerSecond == 60)
    }
}

@Suite struct ScreenCaptureReplyTests {
    @Test func aStartedCaptureTellsThePageWhereToConnect() {
        let value = ScreenCaptureReply.started(
            url: "wss://127.0.0.1:50123/", token: "abc", width: 1670, height: 1080, framesPerSecond: 60
        ).bridgeValue
        #expect(value["ok"] as? Bool == true)
        #expect(value["url"] as? String == "wss://127.0.0.1:50123/")
        #expect(value["token"] as? String == "abc")
        #expect(value["width"] as? Int == 1670)
        #expect(value["height"] as? Int == 1080)
        #expect(value["frameRate"] as? Int == 60)
        #expect(JSONSerialization.isValidJSONObject(value))
    }

    @Test func aRefusalSaysWhy() {
        for (failure, reason) in [
            (ScreenCaptureFailure.badRequest, "bad-request"), (.noPermission, "no-permission"),
            (.noSource, "no-source"), (.unsupported, "unsupported"), (.failed, "failed"),
        ] {
            let value = ScreenCaptureReply.refused(failure).bridgeValue
            #expect(value["ok"] as? Bool == false)
            #expect(value["reason"] as? String == reason)
            #expect(value.count == 2)
        }
    }
}

@Suite struct ScreenSharePickerModeTests {
    @Test func aClientThatTakesNativeCaptureGetsTheAppsOwnList() {
        #expect(ScreenSharePickerMode.answer(arguments: arguments(["nativeCapture": true]), shellCanCapture: true) == .app)
    }

    @Test func aClientFromBeforeItGetsTheSystemsPicker() {
        #expect(ScreenSharePickerMode.answer(arguments: BridgeArguments([]), shellCanCapture: true) == .system)
        #expect(ScreenSharePickerMode.answer(arguments: arguments([:]), shellCanCapture: true) == .system)
        #expect(ScreenSharePickerMode.answer(arguments: arguments(["nativeCapture": false]), shellCanCapture: true) == .system)
        #expect(ScreenSharePickerMode.answer(arguments: arguments(["nativeCapture": 1]), shellCanCapture: true) == .system)
        #expect(ScreenSharePickerMode.answer(arguments: BridgeArguments([true]), shellCanCapture: true) == .system)
    }

    @Test func aShellThatCannotCaptureSaysSo() {
        #expect(ScreenSharePickerMode.answer(arguments: arguments(["nativeCapture": true]), shellCanCapture: false) == .system)
    }
}
