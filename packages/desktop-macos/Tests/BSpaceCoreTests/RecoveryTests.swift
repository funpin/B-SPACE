import Foundation
import Testing
@testable import BSpaceCore

private let instance = URL(string: "https://chat.example.test/channels/1")
private let picker = URL(fileURLWithPath: "/Applications/B-SPACE.app/Contents/Resources/instance-picker.html")

@Suite struct RecoveryStateTests {
    @Test func saysNothingWentWrongToStartWith() {
        let value = RecoveryState().bridgeValue
        #expect(value["mode"] as? String == "normal")
        #expect(value["reason"] is NSNull)
        #expect(value["updateState"] as? String == "idle")
        #expect(value["updateVersion"] is NSNull)
        #expect(value["lastUpdateError"] is NSNull)
        #expect(value["lastCheckResult"] is NSNull)
        #expect(JSONSerialization.isValidJSONObject(value))
    }

    @Test func carriesTheReasonInTheShapeThePageReads() {
        let state = RecoveryState(reason: RecoveryReason(code: .rendererStalled, detail: "no rendererReady within 20000ms"))
        let value = state.bridgeValue
        #expect(value["mode"] as? String == "recovery")
        #expect(value["reason"] as? [String: String] == ["code": "renderer-stalled", "detail": "no rendererReady within 20000ms"])
    }

    @Test func usesTheCodesTheRecoveryPageKnows() {
        #expect(RecoveryReason.Code.loadFailed.rawValue == "load-failed")
        #expect(RecoveryReason.Code.renderGone.rawValue == "render-gone")
        #expect(RecoveryReason.Code.unresponsive.rawValue == "unresponsive")
        #expect(RecoveryReason.Code.rendererStalled.rawValue == "renderer-stalled")
    }

    @Test func readsOnlyTheActionsThePageCanAskFor() {
        #expect(RecoveryAction(rawValue: "reload") == .reload)
        #expect(RecoveryAction(rawValue: "check-update") == .checkUpdate)
        #expect(RecoveryAction(rawValue: "install-update") == .installUpdate)
        #expect(RecoveryAction(rawValue: "change-instance") == .changeInstance)
        #expect(RecoveryAction(rawValue: "open-releases") == .openReleases)
        #expect(RecoveryAction(rawValue: "quit") == .quit)
        #expect(RecoveryAction(rawValue: "format-disk") == nil)
        #expect(RecoveryAction(rawValue: "") == nil)
    }
}

@Suite struct RecoveryModeTests {
    private let failed = RecoveryReason(code: .loadFailed, detail: "-1009 offline @ https://chat.example.test/")
    private let stalled = RecoveryReason(code: .rendererStalled, detail: "no rendererReady within 20000ms")

    @Test func loadsTheRecoveryPageOnce() {
        var mode = RecoveryMode()
        #expect(mode.enter(failed) == true)
        #expect(mode.state.reason == failed)
        // Already in recovery: the reason changes, nothing is loaded again.
        // This is what stops a loop when the recovery page itself fails.
        #expect(mode.enter(stalled) == false)
        #expect(mode.state.reason == stalled)
    }

    @Test func entersAfreshAfterLeaving() {
        var mode = RecoveryMode()
        _ = mode.enter(failed)
        mode.exit()
        #expect(!mode.state.isRecovery)
        #expect(mode.enter(stalled) == true)
    }
}

@Suite struct BootWatchTests {
    @Test func startsTheClockWhenAnInstancePageHasLoaded() {
        var watch = BootWatch()
        #expect(watch.pageCommitted() == nil)
        #expect(watch.loadFinished(url: instance) == .arm)
        #expect(watch.isArmed)
        #expect(watch.timedOut() == true)
        #expect(!watch.isArmed)
    }

    @Test func stopsTheClockWhenTheWebClientReports() {
        var watch = BootWatch()
        _ = watch.pageCommitted()
        _ = watch.loadFinished(url: instance)
        #expect(watch.rendererReady() == .disarm)
        // A clock that fires after it was stopped means nothing.
        #expect(watch.timedOut() == false)
    }

    @Test func doesNotStartTheClockForAReportThatCameBeforeTheLoadEnded() {
        // The usual order: the web client's effect runs while the document is
        // still loading.
        var watch = BootWatch()
        _ = watch.pageCommitted()
        #expect(watch.rendererReady() == nil)
        #expect(watch.loadFinished(url: instance) == nil)
        #expect(!watch.isArmed)
    }

    @Test func forgetsTheReportWhenANewPageIsCommitted() {
        var watch = BootWatch()
        _ = watch.pageCommitted()
        _ = watch.rendererReady()
        _ = watch.loadFinished(url: instance)
        // A reload: the new document has to report for itself.
        #expect(watch.pageCommitted() == nil)
        #expect(watch.loadFinished(url: instance) == .arm)
    }

    @Test func stopsARunningClockWhenThePageIsReplaced() {
        var watch = BootWatch()
        _ = watch.pageCommitted()
        _ = watch.loadFinished(url: instance)
        #expect(watch.pageCommitted() == .disarm)
        #expect(watch.timedOut() == false)
    }

    @Test func doesNotWatchThePickerOrTheRecoveryPage() {
        var watch = BootWatch()
        _ = watch.pageCommitted()
        #expect(watch.loadFinished(url: picker) == nil)
        _ = watch.pageCommitted()
        #expect(watch.loadFinished(url: nil) == nil)
        #expect(!watch.isArmed)
    }

    @Test func startsTheClockOncePerPage() {
        // A load end with no commit before it (a frame inside the page) is
        // not a new page.
        var watch = BootWatch()
        _ = watch.pageCommitted()
        _ = watch.loadFinished(url: instance)
        _ = watch.rendererReady()
        #expect(watch.loadFinished(url: instance) == nil)
    }
}

@Suite struct HangWatchTests {
    private let start = Date(timeIntervalSince1970: 10_000)
    private func step(_ watch: inout HangWatch, at seconds: TimeInterval) -> HangWatch.Step {
        watch.tick(at: start.addingTimeInterval(seconds), pollInterval: 5, grace: 25)
    }

    @Test func asksAndAsksAgainOnceAnswered() {
        var watch = HangWatch()
        #expect(step(&watch, at: 0) == .ask)
        watch.answered()
        #expect(step(&watch, at: 5) == .ask)
    }

    @Test func waitsThroughTheGracePeriodThenCallsThePageHung() {
        var watch = HangWatch()
        #expect(step(&watch, at: 0) == .ask)
        #expect(step(&watch, at: 5) == .wait)
        #expect(step(&watch, at: 20) == .wait)
        #expect(step(&watch, at: 25) == .hung)
    }

    @Test func forgivesAnAnswerThatCameLate() {
        var watch = HangWatch()
        _ = step(&watch, at: 0)
        _ = step(&watch, at: 5)
        _ = step(&watch, at: 10)
        watch.answered()
        #expect(step(&watch, at: 15) == .ask)
        #expect(step(&watch, at: 30) == .wait)
    }

    @Test func doesNotCountTheTimeTheMachineSlept() {
        var watch = HangWatch()
        #expect(step(&watch, at: 0) == .ask)
        #expect(step(&watch, at: 5) == .wait)
        // An hour later: the poll did not run because nothing did.
        #expect(step(&watch, at: 3_605) == .ask)
        #expect(step(&watch, at: 3_610) == .wait)
    }

    @Test func startsOverAfterAReset() {
        var watch = HangWatch()
        _ = step(&watch, at: 0)
        _ = step(&watch, at: 20)
        watch.reset()
        #expect(step(&watch, at: 25) == .ask)
        // Counted from the new question, not from the one before the reset.
        #expect(step(&watch, at: 30) == .wait)
        #expect(step(&watch, at: 45) == .wait)
        #expect(step(&watch, at: 50) == .hung)
    }
}

@Suite struct CrashLoopGuardTests {
    private let start = Date(timeIntervalSince1970: 10_000)

    @Test func reloadsAfterTheFirstEnding() {
        var crashes = CrashLoopGuard()
        #expect(crashes.processEnded(at: start, window: 60) == false)
    }

    @Test func stopsReloadingWhenTheProcessEndsAgainSoon() {
        var crashes = CrashLoopGuard()
        _ = crashes.processEnded(at: start, window: 60)
        #expect(crashes.processEnded(at: start.addingTimeInterval(12), window: 60) == true)
    }

    @Test func treatsEndingsFarApartAsSeparate() {
        var crashes = CrashLoopGuard()
        _ = crashes.processEnded(at: start, window: 60)
        #expect(crashes.processEnded(at: start.addingTimeInterval(60), window: 60) == false)
        #expect(crashes.processEnded(at: start.addingTimeInterval(4_000), window: 60) == false)
        #expect(crashes.processEnded(at: start.addingTimeInterval(4_030), window: 60) == true)
    }
}

@Suite struct RecoveryTimingsTests {
    @Test func defaultToTheElectronBuildsClocks() {
        let timings = RecoveryTimings()
        #expect(timings.bootTimeout == 20)
        #expect(timings.hangGrace > timings.hangPollInterval * 3)
        #expect(timings.watchesHangsOnlyWhenVisible)
    }
}
