import Foundation
import Testing
@testable import BSpaceCore

/// A 1512×982 primary display with a 38 pt menu bar and an 80 pt Dock, in
/// Electron coordinates.
private let primary = DisplayGeometry(
    frame: PlainRect(x: 0, y: 0, width: 1512, height: 982),
    workArea: PlainRect(x: 0, y: 38, width: 1512, height: 864)
)
/// A 2560×1440 display to the right of it, its top edge 200 pt above the
/// primary's.
private let external = DisplayGeometry(
    frame: PlainRect(x: 1512, y: -200, width: 2560, height: 1440),
    workArea: PlainRect(x: 1512, y: -175, width: 2560, height: 1415)
)

@Suite struct WindowPlacementTests {
    @Test func flipsBetweenAppKitAndElectronCoordinates() {
        // A window whose top edge is 100 pt below the top of a 982 pt display.
        let electron = PlainRect(x: 40, y: 100, width: 1280, height: 800)
        let appKit = WindowPlacement.flipped(electron, primaryDisplayHeight: 982)
        #expect(appKit == PlainRect(x: 40, y: 82, width: 1280, height: 800))
        #expect(WindowPlacement.flipped(appKit, primaryDisplayHeight: 982) == electron)
    }

    @Test func flipsADisplayAboveBelowAndBesideThePrimary() {
        // AppKit puts a display that sits above the primary at positive Y.
        let above = PlainRect(x: 0, y: 982, width: 1920, height: 1080)
        #expect(WindowPlacement.flipped(above, primaryDisplayHeight: 982) == PlainRect(x: 0, y: -1080, width: 1920, height: 1080))
        let below = PlainRect(x: 0, y: -1080, width: 1920, height: 1080)
        #expect(WindowPlacement.flipped(below, primaryDisplayHeight: 982) == PlainRect(x: 0, y: 982, width: 1920, height: 1080))
        // A taller display to the left, bottom edges aligned.
        let left = PlainRect(x: -2560, y: 0, width: 2560, height: 1440)
        #expect(WindowPlacement.flipped(left, primaryDisplayHeight: 982) == PlainRect(x: -2560, y: -458, width: 2560, height: 1440))
        // The primary itself maps onto itself.
        let own = PlainRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(WindowPlacement.flipped(own, primaryDisplayHeight: 982) == own)
    }

    private func restorable(_ state: WindowState, displays: [DisplayGeometry] = [primary, external]) -> WindowState {
        WindowPlacement.restorable(state, displays: displays, minimumWidth: 940, minimumHeight: 500)
    }

    @Test func keepsAPlaceThatIsOnADisplay() {
        let onPrimary = WindowState(width: 1280, height: 800, x: 100, y: 60, isMaximized: false)
        #expect(restorable(onPrimary) == onPrimary)
        let onExternal = WindowState(width: 1600, height: 1000, x: 2000, y: 0, isMaximized: true)
        #expect(restorable(onExternal) == onExternal)
        // Mostly off the edge, but part of it is still in the work area.
        let partly = WindowState(width: 1280, height: 800, x: -1200, y: 400, isMaximized: false)
        #expect(restorable(partly) == partly)
    }

    @Test func dropsAPlaceThatIsOnNoDisplay() {
        let gone = WindowState(width: 1600, height: 1000, x: 2000, y: 0, isMaximized: false)
        let restored = restorable(gone, displays: [primary])
        #expect(restored == WindowState(width: 1600, height: 1000, x: nil, y: nil, isMaximized: false))
        let far = WindowState(width: 1280, height: 800, x: 9000, y: 9000, isMaximized: true)
        #expect(restorable(far) == WindowState(width: 1280, height: 800, x: nil, y: nil, isMaximized: true))
    }

    @Test func dropsAPlaceThatOnlyTouchesTheMenuBarOrTheDock() {
        // Entirely above the work area: only its last 20 pt are on the display,
        // under the menu bar.
        let underMenuBar = WindowState(width: 1280, height: 800, x: 100, y: -780, isMaximized: false)
        #expect(restorable(underMenuBar, displays: [primary]).x == nil)
        // Entirely below it, behind the Dock.
        let behindDock = WindowState(width: 1280, height: 800, x: 100, y: 910, isMaximized: false)
        #expect(restorable(behindDock, displays: [primary]).x == nil)
    }

    @Test func choosesTheDisplayTheWindowMostlyLiesOn() {
        // Straddles both displays, mostly on the external one, where it is
        // inside the work area.
        let straddling = WindowState(width: 1280, height: 800, x: 1300, y: 100, isMaximized: false)
        #expect(restorable(straddling) == straddling)
    }

    @Test func neverRestoresBelowTheMinimumSize() {
        let small = WindowState(width: 300, height: 200, x: 100, y: 60, isMaximized: false)
        #expect(restorable(small) == WindowState(width: 940, height: 500, x: 100, y: 60, isMaximized: false))
    }

    @Test func treatsHalfAPositionAsNone() {
        let half = WindowState(width: 1280, height: 800, x: 100, y: nil, isMaximized: false)
        #expect(restorable(half) == WindowState(width: 1280, height: 800, x: nil, y: nil, isMaximized: false))
    }
}

@Suite struct WindowStateStoreTests {
    private func store() -> (WindowStateStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bspace-window-\(UUID().uuidString)", isDirectory: true)
        return (WindowStateStore(directory: directory), directory)
    }

    @Test func givesTheDefaultWhenThereIsNoFile() {
        let (store, _) = store()
        #expect(store.load() == WindowState(width: 1280, height: 800, x: nil, y: nil, isMaximized: false))
    }

    @Test func readsWhatElectronWrites() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data(#"{"width":1440,"height":900,"x":-1200,"y":38,"isMaximized":true}"#.utf8).write(to: store.fileURL)
        #expect(store.load() == WindowState(width: 1440, height: 900, x: -1200, y: 38, isMaximized: true))
    }

    @Test func writesWhatElectronReads() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.save(WindowState(width: 1440, height: 900, x: -1200, y: 38, isMaximized: true))
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == #"{"height":900,"isMaximized":true,"width":1440,"x":-1200,"y":38}"#)

        try store.save(WindowState(width: 1280.5, height: 800, x: nil, y: nil, isMaximized: false))
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == #"{"height":800,"isMaximized":false,"width":1280.5}"#)
        #expect(store.load() == WindowState(width: 1280.5, height: 800, x: nil, y: nil, isMaximized: false))
    }

    @Test func takesTheDefaultForAFieldOfTheWrongType() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data(#"{"width":"wide","height":true,"x":"left","y":null,"isMaximized":1}"#.utf8).write(to: store.fileURL)
        #expect(store.load() == WindowState.default)

        for content in ["", "not json", "[]", "42"] {
            try Data(content.utf8).write(to: store.fileURL)
            #expect(store.load() == WindowState.default)
        }
    }
}
