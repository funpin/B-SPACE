import Foundation

/// Lets through the frames of a rate, and no more.
///
/// ScreenCaptureKit does not give the rate it is asked for. Asked to leave a
/// sixtieth of a second between frames on a display that refreshes 120 times
/// a second, it gives about 56 a second, and 28.8 when asked for 30: a frame
/// that comes a hair before its time is skipped, and the next one is a whole
/// refresh later. Asked for a shorter interval it gives more than the rate,
/// by an amount that depends on the display. So the capture asks for frames
/// with room to spare, and this picks the rate's own out of them.
///
/// The schedule moves by whole intervals from the first frame, so a frame
/// taken a little early or late does not shift the ones after it: over a
/// second the count is the rate, whatever grid the display's refreshes fall
/// on. A source that gives fewer frames than the rate has all of them taken.
public struct FramePacer {
    /// Seconds between two frames of the rate.
    public let interval: Double
    private var due: Double?

    /// How much of an interval a frame may be early and still be the one
    /// that was due. Less than half, or two frames of a source twice as fast
    /// would both be taken.
    static let early = 0.25

    public init(framesPerSecond: Int) {
        interval = 1 / Double(max(1, framesPerSecond))
    }

    /// Whether the frame captured at `time`, in seconds on any clock that
    /// only goes forward, is one of the rate's.
    public mutating func takes(at time: Double) -> Bool {
        guard let due else {
            self.due = time + interval
            return true
        }
        guard time >= due - interval * Self.early else { return false }
        // After a gap (a screen that stood still) the schedule starts again
        // from this frame rather than hurry to make up for the frames that
        // never were.
        self.due = time - due > interval ? time + interval : due + interval
        return true
    }
}
