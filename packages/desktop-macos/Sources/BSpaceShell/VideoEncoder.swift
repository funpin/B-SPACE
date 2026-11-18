import BSpaceCore
import CoreMedia
import Foundation
import VideoToolbox

/// Encodes frames as H.264 for the local media channel, on the hardware
/// encoder, in real time and with no frame waiting for a later one.
///
/// The low-latency rate control is not asked for. It is what the audit's
/// prototype used, but on macOS 27.2 asking for it selects another encoder
/// (`h264.rtvc`) that holds the caller for 25 ms a frame and makes 39 frames a
/// second at 1080p where 60 are given, 29 at 3024 by 1964. The hardware
/// encoder (`ave.avc`) keeps 60 at every size tried and has a frame out 18 ms
/// after it went in at 1080p, 23 at 1440p, 35 at 3024 by 1964 (the numbers
/// are in the package's README).
public final class VideoEncoder {
    public enum Failure: Error, Equatable {
        case sessionRefused(OSStatus)
    }

    public struct Settings: Equatable {
        public var width: Int
        public var height: Int
        public var framesPerSecond: Int

        public init(width: Int, height: Int, framesPerSecond: Int) {
            self.width = width
            self.height = height
            self.framesPerSecond = framesPerSecond
        }
    }

    /// Called with the format of the frames that follow, before the first of
    /// them and whenever it changes. On the encoder's thread.
    public var onFormat: ((MediaWire.VideoFormat) -> Void)?
    /// Called with each encoded frame as a message for the channel. On the
    /// encoder's thread, in the order the frames were given.
    public var onFrame: ((Data) -> Void)?

    public let settings: Settings
    private let session: VTCompressionSession
    private let lock = NSLock()
    private var wantsKeyFrame = true
    private var dropped = 0
    private var announced: Data?

    /// How many frames the encoder gave back without encoding them.
    public var framesDropped: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    public init(settings: Settings) throws {
        self.settings = settings
        // The hardware encoder is required; only when the machine has none
        // to give is whatever the system offers taken.
        func makeSession(requiringHardware: Bool) -> (VTCompressionSession?, OSStatus) {
            var made: VTCompressionSession?
            var specification: [CFString: Any] = [:]
            if requiringHardware {
                specification[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = true
                specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
            }
            let status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(settings.width),
                height: Int32(settings.height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &made
            )
            return (made, status)
        }
        var (made, status) = makeSession(requiringHardware: true)
        if made == nil {
            NSLog("[capture] no hardware encoder for %dx%d (%d)", settings.width, settings.height, status)
            (made, status) = makeSession(requiringHardware: false)
        }
        guard status == noErr, let made else { throw Failure.sessionRefused(status) }
        session = made

        let bitsPerSecond = VideoShape.bitsPerSecond(
            width: settings.width, height: settings.height, framesPerSecond: settings.framesPerSecond
        )
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
            // No frame waits for a later one.
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ExpectedFrameRate, settings.framesPerSecond as CFNumber),
            (kVTCompressionPropertyKey_AverageBitRate, bitsPerSecond as CFNumber),
            // The channel loses nothing, so key frames are for a decoder
            // that asks; this one is only a floor.
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10 as CFNumber),
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr {
                NSLog("[capture] the encoder did not take %@ (%d)", key as String, status)
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)

        var hardware: CFTypeRef?
        withUnsafeMutablePointer(to: &hardware) { value in
            _ = VTSessionCopyProperty(
                made, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil,
                valueOut: value
            )
        }
        isHardware = (hardware as? Bool) ?? false
        NSLog(
            "[capture] encoding %dx%d at %d frames a second, %d bits a second, %@",
            settings.width, settings.height, settings.framesPerSecond, bitsPerSecond,
            isHardware ? "on the hardware encoder" : "in software"
        )
    }

    /// Whether the system gave the session its hardware encoder.
    public let isHardware: Bool

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// The next frame will be one a decoder can start from.
    public func requestKeyFrame() {
        lock.lock()
        wantsKeyFrame = true
        lock.unlock()
    }

    /// Encodes one frame. Safe from any one thread at a time.
    /// - Parameters:
    ///   - presentationTime: the frame's place in the stream.
    ///   - capturedAt: when it was captured, milliseconds since 1970; it
    ///     travels with the frame to the page.
    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, capturedAt: Double) {
        lock.lock()
        let keyFrame = wantsKeyFrame
        wantsKeyFrame = false
        lock.unlock()
        let frameProperties = keyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime, duration: .invalid,
            frameProperties: frameProperties, infoFlagsOut: nil
        ) { [weak self] status, flags, sampleBuffer in
            guard let self else { return }
            guard status == noErr, !flags.contains(.frameDropped), let sampleBuffer else {
                self.lock.lock()
                self.dropped += 1
                self.lock.unlock()
                return
            }
            self.deliver(sampleBuffer, capturedAt: capturedAt)
        }
        if status != noErr {
            // The frame is lost; the next one has to stand on its own.
            requestKeyFrame()
        }
    }

    /// Waits for the frames still inside the encoder.
    public func finish() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    private func deliver(_ sampleBuffer: CMSampleBuffer, capturedAt: Double) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        if isKeyFrame, let description = CMSampleBufferGetFormatDescription(sampleBuffer),
           let record = Self.decoderConfiguration(of: description), record != announced {
            let size = CMVideoFormatDescriptionGetDimensions(description)
            if let format = MediaWire.VideoFormat(
                decoderConfiguration: record, width: Int(size.width), height: Int(size.height)
            ) {
                announced = record
                onFormat?(format)
            }
        }

        let length = CMBlockBufferGetDataLength(block)
        var payload = Data(count: length)
        let copied = payload.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return }
        onFrame?(MediaWire.message(
            kind: isKeyFrame ? .videoKeyFrame : .videoDeltaFrame, capturedAt: capturedAt, payload: payload
        ))
    }

    /// The `avcC` record the encoder attaches to its format: the parameter
    /// sets, as a decoder is configured with them, with one thing added.
    /// The encoder does not reorder frames and does not say so, and a
    /// decoder that is not told holds frames back (`H264ParameterSets`).
    private static func decoderConfiguration(of description: CMFormatDescription) -> Data? {
        let atoms = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any]
        guard let record = atoms?["avcC"] as? Data else { return nil }
        do {
            return try H264ParameterSets.withoutReordering(decoderConfiguration: record)
        } catch {
            NSLog("[capture] the encoder's parameter sets could not be read: the page will show frames late")
            return record
        }
    }
}
