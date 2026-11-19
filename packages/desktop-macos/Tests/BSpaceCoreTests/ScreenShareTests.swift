import Foundation
import Testing
@testable import BSpaceCore

private func arguments(_ options: [String: Any]) -> BridgeArguments {
    BridgeArguments([options])
}

private let asked: [String: Any] = [
    "url": "wss://calls.example/livekit", "token": "a.b.c",
    "sourceId": "screen:1:0", "maxWidth": 2560, "maxHeight": 1440, "frameRate": 60,
    "codec": "h265", "maxBitrate": 8_000_000, "minBitrate": 1_500_000, "audio": true,
]

private func asking(_ changes: [String: Any?]) -> BridgeArguments {
    var options = asked
    for (key, value) in changes {
        if let value { options[key] = value } else { options.removeValue(forKey: key) }
    }
    return arguments(options)
}

@Suite struct ScreenShareRequestTests {
    @Test func readsWhatThePageAsksFor() throws {
        let request = try #require(ScreenShareRequest(arguments: arguments(asked)))
        #expect(request.url == "wss://calls.example/livekit")
        #expect(request.token == "a.b.c")
        #expect(request.capture == ScreenCaptureRequest(source: .display(1), maxWidth: 2560, maxHeight: 1440, framesPerSecond: 60))
        #expect(request.codec == .h265)
        #expect(request.maxBitrate == 8_000_000)
        #expect(request.minBitrate == 1_500_000)
        #expect(request.audio)
    }

    @Test func aShareNeedsSomewhereToGoAndAPassAndASource() {
        #expect(ScreenShareRequest(arguments: BridgeArguments([])) == nil)
        #expect(ScreenShareRequest(arguments: asking(["url": nil])) == nil)
        #expect(ScreenShareRequest(arguments: asking(["token": nil])) == nil)
        #expect(ScreenShareRequest(arguments: asking(["token": ""])) == nil)
        #expect(ScreenShareRequest(arguments: asking(["token": "a b"])) == nil)
        #expect(ScreenShareRequest(arguments: asking(["token": String(repeating: "a", count: 9000)])) == nil)
        #expect(ScreenShareRequest(arguments: asking(["sourceId": nil])) == nil)
        #expect(ScreenShareRequest(arguments: asking(["sourceId": "tab:1:0"])) == nil)
    }

    @Test func onlyACallServerIsConnectedTo() {
        #expect(ScreenShareRequest.isCallServer("wss://calls.example/livekit"))
        #expect(ScreenShareRequest.isCallServer("wss://calls.example:7443"))
        // Unencrypted only to this machine, for a server run for development.
        #expect(ScreenShareRequest.isCallServer("ws://localhost:7880"))
        #expect(ScreenShareRequest.isCallServer("ws://127.0.0.1:7880"))
        #expect(ScreenShareRequest.isCallServer("ws://[::1]:7880"))
        #expect(!ScreenShareRequest.isCallServer("ws://calls.example/livekit"))
        #expect(!ScreenShareRequest.isCallServer("https://calls.example/livekit"))
        #expect(!ScreenShareRequest.isCallServer("wss://user:secret@calls.example"))
        #expect(!ScreenShareRequest.isCallServer("wss://"))
        #expect(!ScreenShareRequest.isCallServer("file:///etc/passwd"))
        #expect(!ScreenShareRequest.isCallServer("not a url"))
        #expect(ScreenShareRequest(arguments: asking(["url": "ws://calls.example"])) == nil)
    }

    @Test func whatIsMissingOrOutOfBoundsIsBroughtIntoThem() throws {
        let bare = try #require(ScreenShareRequest(arguments: arguments([
            "url": "wss://calls.example", "token": "t", "sourceId": "window:7:0",
        ])))
        #expect(bare.capture.framesPerSecond == 30)
        #expect(bare.codec == .h264)
        #expect(bare.maxBitrate == ScreenShareRequest.defaultMaxBitrate)
        #expect(bare.minBitrate == 0)
        #expect(!bare.audio)

        let wild = try #require(ScreenShareRequest(arguments: asking([
            "codec": "vp9", "maxBitrate": 9_000_000_000, "minBitrate": -5, "audio": "yes",
        ])))
        #expect(wild.codec == .h264)
        #expect(wild.maxBitrate == ScreenShareRequest.bitrateRange.upperBound)
        #expect(wild.minBitrate == 0)
        #expect(!wild.audio)
    }

    @Test func theFloorIsNeverAboveTheCeiling() throws {
        let request = try #require(ScreenShareRequest(arguments: asking(["maxBitrate": 2_000_000, "minBitrate": 5_000_000])))
        #expect(request.minBitrate == 2_000_000)
    }
}

@Suite struct ScreenShareUpdateTests {
    private var running: ScreenShareRequest { ScreenShareRequest(arguments: arguments(asked))! }

    @Test func aNewCeilingChangesTheEncodingAlone() throws {
        let update = try #require(ScreenShareUpdate(arguments: arguments(["maxBitrate": 4_000_000])))
        let result = update.applied(to: running)
        #expect(result.changes == [.encoding])
        #expect(result.request.maxBitrate == 4_000_000)
        #expect(result.request.minBitrate == 1_500_000)
        #expect(result.request.capture == running.capture)
    }

    @Test func aCeilingBelowTheFloorTakesTheFloorDownWithIt() throws {
        let update = try #require(ScreenShareUpdate(arguments: arguments(["maxBitrate": 1_000_000])))
        #expect(update.applied(to: running).request.minBitrate == 1_000_000)
    }

    @Test func anotherSourceOrSizeChangesTheCapture() throws {
        let source = try #require(ScreenShareUpdate(arguments: arguments(["sourceId": "window:9:0"])))
        let moved = source.applied(to: running)
        #expect(moved.changes == [.capture])
        #expect(moved.request.capture.source == .window(9))
        #expect(moved.request.capture.maxWidth == 2560)

        let size = try #require(ScreenShareUpdate(arguments: arguments(["maxWidth": 1920, "maxHeight": 1080])))
        let smaller = size.applied(to: running)
        #expect(smaller.changes == [.capture])
        #expect(smaller.request.capture.maxWidth == 1920)
        #expect(smaller.request.capture.source == .display(1))
    }

    @Test func anotherFrameRateChangesTheCaptureAndTheEncoding() throws {
        let update = try #require(ScreenShareUpdate(arguments: arguments(["frameRate": 30])))
        let result = update.applied(to: running)
        #expect(result.changes == [.capture, .encoding])
        #expect(result.request.capture.framesPerSecond == 30)
    }

    @Test func theSoundIsTurnedOnAndOffByItself() throws {
        let off = try #require(ScreenShareUpdate(arguments: arguments(["audio": false])))
        let result = off.applied(to: running)
        #expect(result.changes == [.audio])
        #expect(!result.request.audio)
    }

    @Test func whatIsAlreadySoChangesNothing() throws {
        let update = try #require(ScreenShareUpdate(arguments: arguments([
            "sourceId": "screen:1:0", "maxWidth": 2560, "frameRate": 60, "maxBitrate": 8_000_000, "audio": true,
        ])))
        let result = update.applied(to: running)
        #expect(result.changes.isEmpty)
        #expect(result.request == running)
    }

    @Test func anUpdateThatSaysNothingOrNamesNoSourceIsNotOne() {
        #expect(ScreenShareUpdate(arguments: BridgeArguments([])) == nil)
        #expect(ScreenShareUpdate(arguments: arguments([:])) == nil)
        #expect(ScreenShareUpdate(arguments: arguments(["sourceId": "tab:1:0"])) == nil)
        #expect(ScreenShareUpdate(arguments: arguments(["codec": "h264"])) == nil)
    }

    @Test func theAddressAndThePassCannotBeChanged() throws {
        let update = try #require(ScreenShareUpdate(arguments: arguments([
            "url": "wss://elsewhere.example", "token": "other", "maxBitrate": 4_000_000,
        ])))
        let result = update.applied(to: running)
        #expect(result.request.url == "wss://calls.example/livekit")
        #expect(result.request.token == "a.b.c")
    }
}

@Suite struct ScreenShareAnswersTests {
    @Test func aStartedShareSaysTheSizeOfItsVideo() {
        let value = ScreenShareReply.running(width: 2560, height: 1440, framesPerSecond: 60).bridgeValue
        #expect(value["ok"] as? Bool == true)
        #expect(value["width"] as? Int == 2560)
        #expect(value["height"] as? Int == 1440)
        #expect(value["frameRate"] as? Int == 60)
    }

    @Test func aRefusalSaysWhy() {
        let value = ScreenShareReply.refused(.connectFailed).bridgeValue
        #expect(value["ok"] as? Bool == false)
        #expect(value["reason"] as? String == "connect-failed")
        #expect(ScreenShareFailure(.noPermission) == .noPermission)
        #expect(ScreenShareFailure(.noSource) == .noSource)
        #expect(ScreenShareFailure(.tooMany) == .failed)
    }

    @Test func eventsAreToldByTheirType() {
        #expect(ScreenShareEvent.ended(.sourceEnded).bridgeValue as NSDictionary == ["type": "ended", "reason": "source-ended"])
        #expect(ScreenShareEvent.reconnecting.bridgeValue as NSDictionary == ["type": "reconnecting"])
        #expect(ScreenShareEvent.reconnected.bridgeValue as NSDictionary == ["type": "reconnected"])
        #expect(ScreenShareEvent.resized(width: 1440, height: 900).bridgeValue as NSDictionary == ["type": "resized", "width": 1440, "height": 900])
        #expect(ScreenShareEvent.audioEnded.bridgeValue as NSDictionary == ["type": "audio-ended"])
        #expect(ScreenShareEvent.previewEnded.bridgeValue as NSDictionary == ["type": "preview-ended"])
    }

    @Test func statisticsCarryWhatTheConnectionPanelShows() {
        let stats = ScreenShareStats(
            bitrate: 4_200_000, framesPerSecond: 59.6, width: 2560, height: 1440,
            codec: "video/H265", encoder: "VideoToolbox", hardware: true,
            roundTripMilliseconds: 5.4, availableBitrate: 6_000_000, limitedBy: "none", audioBitrate: 48_000
        )
        let value = ScreenShareEvent.stats(stats).bridgeValue
        #expect(value["type"] as? String == "stats")
        #expect(value["bitrate"] as? Int == 4_200_000)
        #expect(value["frameRate"] as? Double == 59.6)
        #expect(value["width"] as? Int == 2560)
        #expect(value["codec"] as? String == "video/H265")
        #expect(value["encoder"] as? String == "VideoToolbox")
        #expect(value["hardware"] as? Bool == true)
        #expect(value["roundTripMs"] as? Double == 5.4)
        #expect(value["availableBitrate"] as? Int == 6_000_000)
        #expect(value["limitedBy"] as? String == "none")
        #expect(value["audioBitrate"] as? Int == 48_000)

        let bare = ScreenShareEvent.stats(ScreenShareStats(
            bitrate: 0, framesPerSecond: 0, width: 0, height: 0, codec: "", encoder: "", hardware: false,
            roundTripMilliseconds: nil, availableBitrate: nil, limitedBy: nil, audioBitrate: nil
        )).bridgeValue
        #expect(bare["roundTripMs"] == nil)
        #expect(bare["audioBitrate"] == nil)
    }
}

@Suite struct BitrateMeterTests {
    @Test func aRateIsWhatWasSentSinceTheLastReading() {
        var meter = BitrateMeter()
        #expect(meter.rate(bytes: 1_000_000, at: 10) == 0)
        #expect(meter.rate(bytes: 1_500_000, at: 11) == 4_000_000)
        #expect(meter.rate(bytes: 1_750_000, at: 13) == 1_000_000)
    }

    @Test func aCounterThatStartsAgainIsNotANegativeRate() {
        var meter = BitrateMeter()
        _ = meter.rate(bytes: 5_000_000, at: 1)
        #expect(meter.rate(bytes: 1_000, at: 2) == 0)
        #expect(meter.rate(bytes: 126_000, at: 3) == 1_000_000)
    }

    @Test func twoReadingsAtTheSameMomentGiveNoRate() {
        var meter = BitrateMeter()
        _ = meter.rate(bytes: 100, at: 1)
        #expect(meter.rate(bytes: 200, at: 1) == 0)
    }
}

@Suite struct SharePreviewTests {
    @Test func aBoxIsReadAsThePageMeasuresIt() {
        let frame = SharePreviewFrame(arguments: arguments(["x": 120.5, "y": 80, "width": 640, "height": 400, "radius": 10]))
        #expect(frame == SharePreviewFrame(x: 120.5, y: 80, width: 640, height: 400, cornerRadius: 10))
        #expect(SharePreviewFrame(arguments: arguments(["x": 0, "y": 0, "width": 10, "height": 10]))?.cornerRadius == 0)
    }

    @Test func whatIsNotABoxWithASizeShowsNothing() {
        #expect(SharePreviewFrame(arguments: BridgeArguments([])) == nil)
        #expect(SharePreviewFrame(arguments: BridgeArguments([NSNull()])) == nil)
        #expect(SharePreviewFrame(arguments: arguments(["x": 0, "y": 0, "width": 0, "height": 100])) == nil)
        #expect(SharePreviewFrame(arguments: arguments(["x": 0, "y": 0, "width": 100])) == nil)
        #expect(SharePreviewFrame(arguments: arguments(["x": Double.nan, "y": 0, "width": 100, "height": 100])) == nil)
        #expect(SharePreviewFrame(arguments: arguments(["x": true, "y": 0, "width": 100, "height": 100])) == nil)
        #expect(SharePreviewFrame(arguments: arguments(["x": 0, "y": 0, "width": 99_999, "height": 100])) == nil)
        #expect(SharePreviewFrame(arguments: arguments(["x": 1e9, "y": 0, "width": 100, "height": 100])) == nil)
    }

    @Test func cornersAreNoRounderThanTheBoxAllows() {
        #expect(SharePreviewFrame(arguments: arguments(["x": 0, "y": 0, "width": 100, "height": 40, "radius": 500]))?.cornerRadius == 20)
        #expect(SharePreviewFrame(arguments: arguments(["x": 0, "y": 0, "width": 100, "height": 40, "radius": -3]))?.cornerRadius == 0)
    }

    @Test func aPreviewIsACaptureOfTheSourceAtAPreviewsSize() {
        let capture = SharePreview.capture(arguments: arguments(["sourceId": "window:7:0", "maxWidth": 8000, "frameRate": 60]))
        #expect(capture == ScreenCaptureRequest(source: .window(7), maxWidth: 1280, maxHeight: 800, framesPerSecond: 30))
        #expect(SharePreview.capture(arguments: arguments(["sourceId": "tab:1:0"])) == nil)
        #expect(SharePreview.capture(arguments: BridgeArguments([])) == nil)
    }

    @Test func theAnswerSaysTheSizeOrWhyNot() {
        #expect(SharePreview.started(width: 1280, height: 800) as NSDictionary == ["ok": true, "width": 1280, "height": 800])
        #expect(SharePreview.refused(.noPermission) as NSDictionary == ["ok": false, "reason": "no-permission"])
    }
}

