import Foundation
import Testing
@testable import BSpaceCore

@Suite struct SystemAudioTests {
    private func floats(_ data: Data) -> [Float32] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
    }

    private func interleaved(_ planes: [[Float32]], channels: Int) -> Data? {
        // The pointers are only good inside the closures that lend them.
        func lend(_ rest: ArraySlice<[Float32]>, _ lent: [UnsafeBufferPointer<Float32>]) -> Data? {
            guard let next = rest.first else { return SystemAudio.interleaved(lent, channels: channels) }
            return next.withUnsafeBufferPointer { lend(rest.dropFirst(), lent + [$0]) }
        }
        return lend(planes[...], [])
    }

    @Test func laysTheChannelsOutFrameAfterFrame() throws {
        let data = try #require(interleaved([[1, 2, 3], [-1, -2, -3]], channels: 2))
        #expect(floats(data) == [1, -1, 2, -2, 3, -3])
    }

    @Test func oneChannelIsItself() throws {
        let data = try #require(interleaved([[0.25, 0.5]], channels: 1))
        #expect(floats(data) == [0.25, 0.5])
    }

    @Test func noFramesIsNoBytes() throws {
        let data = try #require(interleaved([[], []], channels: 2))
        #expect(data.isEmpty)
    }

    @Test func refusesChannelsThatAreNotTheOnesAnnounced() {
        #expect(interleaved([[1, 2]], channels: 2) == nil)
        #expect(interleaved([[1], [2], [3]], channels: 2) == nil)
        #expect(interleaved([], channels: 2) == nil)
        #expect(interleaved([[1]], channels: 0) == nil)
    }

    @Test func refusesChannelsOfDifferentLengths() {
        #expect(interleaved([[1, 2, 3], [1, 2]], channels: 2) == nil)
    }

    @Test func theSamplesAreLittleEndianFloats() throws {
        let data = try #require(interleaved([[1], [-2]], channels: 2))
        // 1.0 is 0x3f800000, -2.0 is 0xc0000000.
        #expect([UInt8](data) == [0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x00, 0xc0])
    }

    @Test func aClientThatTakesTheNativeCaptureIsToldItsOwnSoundIsLeftOut() {
        let native = BridgeArguments([["nativeAudio": true]])
        #expect(SystemAudio.capability(arguments: native, shellCanCapture: true) == "excluded")
        #expect(SystemAudio.capability(arguments: native, shellCanCapture: false) == "unavailable")
    }

    @Test func aClientFromBeforeTheNativeCaptureIsToldThereIsNoSystemAudio() {
        // The Electron-era argument is a boolean, or nothing at all.
        #expect(SystemAudio.capability(arguments: BridgeArguments([true]), shellCanCapture: true) == "unavailable")
        #expect(SystemAudio.capability(arguments: BridgeArguments([]), shellCanCapture: true) == "unavailable")
        #expect(SystemAudio.capability(arguments: BridgeArguments([["nativeAudio": 1]]), shellCanCapture: true) == "unavailable")
        #expect(SystemAudio.capability(arguments: BridgeArguments([["nativeAudio": false]]), shellCanCapture: true) == "unavailable")
    }

    @Test func tellsThePageWhereTheSoundIsAndWhatShapeItHas() {
        let reply = SystemAudioReply.started(
            id: "a", url: "wss://127.0.0.1:1/", token: "t", format: SystemAudio.format
        ).bridgeValue
        #expect(reply["ok"] as? Bool == true)
        #expect(reply["id"] as? String == "a")
        #expect(reply["url"] as? String == "wss://127.0.0.1:1/")
        #expect(reply["token"] as? String == "t")
        #expect(reply["sampleRate"] as? Int == 48_000)
        #expect(reply["channels"] as? Int == 2)
    }

    @Test func tellsThePageWhyThereIsNoSound() {
        let reply = SystemAudioReply.refused(.noPermission).bridgeValue
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["reason"] as? String == "no-permission")
    }

    @Test func announcesTheFormatAsTheReaderExpectsIt() throws {
        let message = MediaWire.AudioFormat(sampleRate: 48_000, channels: 2).message
        let object = try #require(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "audio")
        #expect(object["sampleRate"] as? Int == 48_000)
        #expect(object["channels"] as? Int == 2)
    }

    @Test func aSoundMessageCarriesItsKindAndItsTime() {
        let message = MediaWire.message(kind: .audio, capturedAt: 1.5, payload: Data([9, 8, 7, 6]))
        #expect(message.first == 3)
        #expect(message.count == MediaWire.headerLength + 4)
        #expect(message.suffix(4) == Data([9, 8, 7, 6]))
    }
}
