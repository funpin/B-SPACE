import Foundation

// Recovery mode: what the shell does when the web client cannot be shown. The
// page fails to load, never finishes starting, stops answering, or its
// process dies again and again; the window then shows `recovery.html` (the
// page the Electron build uses, from `packages/desktop/resources`), which
// says what happened and offers to reload, to change the instance or to quit.
// This file is the port of `packages/desktop/src/recovery.ts` without the
// parts that touch a window; those are in `MainWindowController`.

/// Why the shell went into recovery. The codes are the ones the recovery page
/// knows.
public struct RecoveryReason: Equatable {
    public enum Code: String {
        /// The page did not load.
        case loadFailed = "load-failed"
        /// The process drawing the page ended.
        case renderGone = "render-gone"
        /// The page stopped answering.
        case unresponsive
        /// The page loaded but the web client never said it had started.
        case rendererStalled = "renderer-stalled"
    }

    public let code: Code
    /// For the diagnostic block of the recovery page; not translated.
    public let detail: String

    public init(code: Code, detail: String) {
        self.code = code
        self.detail = detail
    }
}

/// The state the recovery page and the web client read with
/// `getRecoveryState()` and follow on `recovery-state-changed`.
///
/// The update fields belong to the updater, which the native shell gets in
/// stage 5; until then they say what a build with nothing to report says.
public struct RecoveryState: Equatable {
    public var reason: RecoveryReason?

    public init(reason: RecoveryReason? = nil) {
        self.reason = reason
    }

    public var isRecovery: Bool { reason != nil }

    /// The object the page receives: the shape of `RecoveryState` in
    /// `recovery.ts`.
    public var bridgeValue: [String: Any] {
        [
            "mode": isRecovery ? "recovery" : "normal",
            "reason": reason.map { ["code": $0.code.rawValue, "detail": $0.detail] as [String: Any] } ?? NSNull(),
            "updateState": "idle",
            "updateVersion": NSNull(),
            "lastUpdateError": NSNull(),
            "lastCheckResult": NSNull(),
        ]
    }
}

/// What the recovery page (and the menu) can ask for on `recovery-action`.
public enum RecoveryAction: String {
    case reload
    case checkUpdate = "check-update"
    case installUpdate = "install-update"
    case changeInstance = "change-instance"
    case openReleases = "open-releases"
    case quit

    /// Where "open the releases page" goes.
    public static let releasesAddress = "https://github.com/funpin/B-SPACE/releases/latest"
}

/// Whether the shell is in recovery, and the one rule that keeps it from
/// looping: going into recovery while already there changes what the page
/// says and loads nothing. If the recovery page itself cannot load, the
/// window stays as it is instead of loading it over and over.
public struct RecoveryMode: Equatable {
    public private(set) var state = RecoveryState()
    private var isShowingRecovery = false

    public init() {}

    /// Records the reason. True when the recovery page has to be loaded now;
    /// false when the shell is already in recovery.
    public mutating func enter(_ reason: RecoveryReason) -> Bool {
        state.reason = reason
        guard !isShowingRecovery else { return false }
        isShowingRecovery = true
        return true
    }

    /// Leaves recovery before trying again: if the next load fails or stalls,
    /// recovery is entered afresh.
    public mutating func exit() {
        state.reason = nil
        isShowingRecovery = false
    }
}

/// Watches for a web client that loads and never starts. After a page of an
/// instance has finished loading, the web client has `timeout` to report
/// `rendererReady()`; the shell owns the clock and is told here when to start
/// and stop it.
///
/// The web client usually reports before the load has finished (its effect
/// runs while the document is still loading), so a report is remembered for
/// the current page: a load that finishes after it must not start the clock.
public struct BootWatch: Equatable {
    public enum Command: Equatable {
        /// Start the clock (replacing one that is running).
        case arm
        /// Stop the clock.
        case disarm
    }

    private var isWaitingForLoadEnd = false
    private var hasReportedReady = false
    public private(set) var isArmed = false

    public init() {}

    /// A new document was committed in the main frame. In-page navigation of
    /// the web client does not count and must not be reported here.
    public mutating func pageCommitted() -> Command? {
        isWaitingForLoadEnd = true
        hasReportedReady = false
        return disarm()
    }

    /// The main frame finished loading `url`. Only a web page is watched: the
    /// picker and the recovery page are files and never report.
    public mutating func loadFinished(url: URL?) -> Command? {
        guard isWaitingForLoadEnd else { return nil }
        isWaitingForLoadEnd = false
        guard let url, WebOrigin.of(url) != nil, !hasReportedReady else { return nil }
        isArmed = true
        return .arm
    }

    /// The web client reported that it has started.
    public mutating func rendererReady() -> Command? {
        hasReportedReady = true
        return disarm()
    }

    /// The clock ran out. True when that means the web client stalled; false
    /// for a clock that was stopped in the meantime.
    public mutating func timedOut() -> Bool {
        guard isArmed else { return false }
        isArmed = false
        return true
    }

    private mutating func disarm() -> Command? {
        guard isArmed else { return nil }
        isArmed = false
        return .disarm
    }
}

/// Watches for a page that stops answering. A `WKWebView` does not say when
/// its page hangs (Electron's does), so the shell asks the page a trivial
/// question at intervals; a question unanswered for `grace` means the page's
/// thread is stuck.
public struct HangWatch: Equatable {
    public enum Step: Equatable {
        /// Ask the page now.
        case ask
        /// A question is out and has not waited too long yet.
        case wait
        /// The question has gone unanswered for the whole grace period.
        case hung
    }

    private var askedAt: Date?
    private var lastTick: Date?

    public init() {}

    /// Called at every poll while a page is being watched. Says what to do.
    ///
    /// A tick that comes much later than the poll interval means the clock
    /// jumped: the machine slept, with the question and the answer both
    /// frozen. The time asleep is not time the page spent stuck, so the
    /// question is asked again instead of being held against the page.
    public mutating func tick(at now: Date, pollInterval: TimeInterval, grace: TimeInterval) -> Step {
        defer { lastTick = now }
        if let lastTick, now.timeIntervalSince(lastTick) > pollInterval * 3 {
            askedAt = nil
        }
        guard let askedAt else {
            self.askedAt = now
            return .ask
        }
        return now.timeIntervalSince(askedAt) >= grace ? .hung : .wait
    }

    /// The page answered.
    public mutating func answered() {
        askedAt = nil
    }

    /// The page was replaced or is not being watched: start over.
    public mutating func reset() {
        askedAt = nil
        lastTick = nil
    }
}

/// What to do when the process drawing the page ends. WebKit ends these
/// processes for reasons that have nothing to do with the page (the system is
/// short of memory), so the first time the page is simply loaded again. A
/// process that ends again soon after is a page that keeps crashing, and
/// that goes to recovery instead of reloading for ever.
public struct CrashLoopGuard: Equatable {
    private var lastEnded: Date?

    public init() {}

    /// Records that the process ended. True when it ended within `window` of
    /// the time before: stop reloading.
    public mutating func processEnded(at now: Date, window: TimeInterval) -> Bool {
        defer { lastEnded = now }
        guard let lastEnded else { return false }
        return now.timeIntervalSince(lastEnded) < window
    }
}

/// The clocks of recovery, gathered so that a test run can shorten them.
public struct RecoveryTimings: Equatable {
    /// How long the web client has to report that it started (20 s in the
    /// Electron build).
    public var bootTimeout: TimeInterval
    /// How often the page is asked whether it still answers.
    public var hangPollInterval: TimeInterval
    /// How long a question may stay unanswered. Chromium takes about as long
    /// to call a page unresponsive, and the Electron build then waits ten
    /// seconds more.
    public var hangGrace: TimeInterval
    /// Two process endings closer together than this are a crash loop.
    public var crashLoopWindow: TimeInterval
    /// The page is asked only while the window is on screen: a hidden page
    /// runs slowed down, and waking nobody for a page nobody sees is right.
    /// A test run has no window on screen and switches this off.
    public var watchesHangsOnlyWhenVisible: Bool

    public init(
        bootTimeout: TimeInterval = 20,
        hangPollInterval: TimeInterval = 5,
        hangGrace: TimeInterval = 25,
        crashLoopWindow: TimeInterval = 60,
        watchesHangsOnlyWhenVisible: Bool = true
    ) {
        self.bootTimeout = bootTimeout
        self.hangPollInterval = hangPollInterval
        self.hangGrace = hangGrace
        self.crashLoopWindow = crashLoopWindow
        self.watchesHangsOnlyWhenVisible = watchesHangsOnlyWhenVisible
    }
}
