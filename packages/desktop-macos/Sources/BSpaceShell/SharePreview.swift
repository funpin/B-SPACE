import AVFoundation
import AppKit
import BSpaceCore
import CoreMedia
import CoreVideo

/// What shows the live preview of a source over the page's preview box.
public protocol SharePreviewPresenter: AnyObject {
    /// The view to lay over the page; nil for a presenter that has none (a
    /// test run's, which only remembers what it was asked to show).
    var view: NSView? { get }

    /// Puts the picture over this rectangle of the window's content, in its
    /// top-left coordinates, with corners of this radius. Main queue.
    func show(in frame: NSRect, cornerRadius: CGFloat)

    /// Shows nothing; the picture goes on arriving. Main queue.
    func hide()

    /// One frame of the source. Called on a queue of the capturer's own.
    func draw(_ frame: CVPixelBuffer, at time: CMTime)

    /// Forgets the picture: the preview is over. Main queue.
    func clear()
}

/// The preview as the app shows it: a view over the web view with a layer
/// the capture's frames are handed to as they are. No encoder, no copy, and
/// nothing of it passes through the page, which is why it does not stutter
/// when the page is busy.
///
/// It lies over the page, so whatever the page draws on top of its preview
/// box would be covered: the page shows the preview only while nothing of
/// its own is over that box. Clicks go through it to the page.
public final class SystemSharePreview: SharePreviewPresenter {
    private let surface = PreviewView()

    public init() {}

    public var view: NSView? { surface }

    public func show(in frame: NSRect, cornerRadius: CGFloat) {
        if surface.frame != frame { surface.frame = frame }
        surface.layer?.cornerRadius = cornerRadius
        surface.isHidden = false
    }

    public func hide() {
        surface.isHidden = true
    }

    public func draw(_ frame: CVPixelBuffer, at time: CMTime) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame, formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: frame, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return }
        // Shown as it arrives: a preview has no clock to wait for.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        let renderer = surface.display.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    public func clear() {
        surface.isHidden = true
        surface.display.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}

/// The view the preview is drawn in.
private final class PreviewView: NSView {
    let display = AVSampleBufferDisplayLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        display.videoGravity = .resizeAspect
        display.frame = bounds
        display.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(display)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The page's box is under it, and the clicks are the page's.
    override func hitTest(_: NSPoint) -> NSView? { nil }
}
