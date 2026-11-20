import CoreVideo
import Foundation

/// A black picture, in the format the capture's frames have.
///
/// A call's video track takes its size from its first frame and is not
/// published without one, and a source the system does not draw gives none:
/// a window in another of Stage Manager's sets, or on another desktop. A
/// share of such a source starts with this for a first frame, so that it is
/// in the call, showing nothing, when the window comes to the screen.
enum BlankFrame {
    static func make(width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }
        var made: CVPixelBuffer?
        // Backed by an IOSurface, as captured frames are: the hardware
        // encoder takes those without a copy.
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &made
        )
        guard status == kCVReturnSuccess, let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // Video range: black is 16 of luma and no colour, which is 128.
        for (plane, value) in [(0, Int32(16)), (1, Int32(128))] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return nil }
            memset(base, value, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        return buffer
    }
}
