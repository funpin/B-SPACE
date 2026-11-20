import Foundation
import Testing
@testable import BSpaceCore

private func window(
    title: String = "Document",
    hasApplication: Bool = true,
    bundleIdentifier: String = "com.example.editor",
    layer: Int = 0,
    isOnScreen: Bool = true,
    width: Double = 800,
    height: Double = 600
) -> ShareableWindow {
    ShareableWindow(
        id: 7, title: title, hasApplication: hasApplication, bundleIdentifier: bundleIdentifier, layer: layer,
        isOnScreen: isOnScreen,
        width: width, height: height
    )
}

@Suite struct ScreenSourceTests {
    private let picture = Data([0x89, 0x50, 0x4e, 0x47])

    @Test func idsAreSpelledAsTheElectronBuildSpellsThem() {
        #expect(ScreenSource(kind: .display(1), name: "Built-in", thumbnailPNG: picture).id == "screen:1:0")
        #expect(ScreenSource(kind: .window(48213), name: "Notes", thumbnailPNG: picture).id == "window:48213:0")
    }

    @Test func anIdNamesWhatItWasMadeFrom() {
        #expect(ScreenSource.kind(ofID: "screen:1:0") == .display(1))
        #expect(ScreenSource.kind(ofID: "window:48213:0") == .window(48213))
    }

    @Test func anIdSpelledAnyOtherWayNamesNothing() {
        for id in ["", "screen", "screen:1", "screen:1:1", "screen:-1:0", "screen:one:0", "tab:1:0", "window:1:0:0", "window::0"] {
            #expect(ScreenSource.kind(ofID: id) == nil, "\(id)")
        }
    }

    @Test func aDisplayReachesThePageAsAScreenWithoutAnIcon() throws {
        let value = ScreenSource(kind: .display(2), name: "Studio Display", thumbnailPNG: picture).bridgeValue
        #expect(value["id"] as? String == "screen:2:0")
        #expect(value["name"] as? String == "Studio Display")
        #expect(value["isScreen"] as? Bool == true)
        #expect(value["thumbnailDataUrl"] as? String == "data:image/png;base64,iVBORw==")
        #expect(value["appIconDataUrl"] is NSNull)
        #expect(Set(value.keys) == ["id", "name", "thumbnailDataUrl", "appIconDataUrl", "isScreen"])
        // What goes over the bridge has to be JSON.
        #expect(JSONSerialization.isValidJSONObject(value))
    }

    @Test func aWindowReachesThePageWithItsApplicationsIcon() {
        let value = ScreenSource(
            kind: .window(9), name: "Notes", thumbnailPNG: picture, appIconPNG: Data([1, 2, 3])
        ).bridgeValue
        #expect(value["isScreen"] as? Bool == false)
        #expect(value["appIconDataUrl"] as? String == "data:image/png;base64,AQID")
    }
}

@Suite struct ScreenSourceRulesTests {
    @Test func anOrdinaryWindowIsListed() {
        #expect(ScreenSourceRules.isListed(window()))
    }

    @Test func whatIsNotAnOrdinaryWindowIsNot() {
        // The menu bar, the Dock and floating panels are on other levels.
        #expect(!ScreenSourceRules.isListed(window(layer: 25)))
        #expect(!ScreenSourceRules.isListed(window(layer: -2_147_483_623)))
        // Minimised, or on another Space.
        #expect(!ScreenSourceRules.isListed(window(isOnScreen: false)))
        // The system's own surfaces.
        #expect(!ScreenSourceRules.isListed(window(hasApplication: false)))
        // Nothing to call the tile.
        #expect(!ScreenSourceRules.isListed(window(title: "")))
        #expect(!ScreenSourceRules.isListed(window(title: "  \n")))
        // Helper surfaces an application keeps around.
        #expect(!ScreenSourceRules.isListed(window(width: 1, height: 1)))
        #expect(!ScreenSourceRules.isListed(window(width: 800, height: 20)))
    }

    @Test func theSystemsFurnitureIsNot() {
        // Stage Manager keeps a titled copy of every window in its strip.
        #expect(!ScreenSourceRules.isListed(window(bundleIdentifier: "com.apple.WindowManager", width: 127, height: 147)))
        #expect(!ScreenSourceRules.isListed(window(bundleIdentifier: "com.apple.dock")))
        #expect(!ScreenSourceRules.isListed(window(bundleIdentifier: "com.apple.controlcenter")))
        // The window itself, small in the strip, still is.
        #expect(ScreenSourceRules.isListed(window(bundleIdentifier: "com.apple.Safari", width: 139, height: 172)))
        // So is the window of something that is not a bundle at all.
        #expect(ScreenSourceRules.isListed(window(bundleIdentifier: "")))
    }

    @Test func aThumbnailFitsTheBoxWithItsProportionsKept() {
        // A 16:10 display fills the height.
        #expect(ScreenSourceRules.thumbnailSize(width: 3024, height: 1964) == (277, 180))
        // A 16:9 one fills the box.
        #expect(ScreenSourceRules.thumbnailSize(width: 2560, height: 1440) == (320, 180))
        // A tall window fills the height, a wide one the width.
        #expect(ScreenSourceRules.thumbnailSize(width: 400, height: 1200) == (60, 180))
        #expect(ScreenSourceRules.thumbnailSize(width: 1600, height: 200) == (320, 40))
    }

    @Test func aThumbnailIsNeverLargerThanTheThingOrEmpty() {
        #expect(ScreenSourceRules.thumbnailSize(width: 100, height: 60) == (100, 60))
        #expect(ScreenSourceRules.thumbnailSize(width: 4000, height: 2) == (320, 1))
        #expect(ScreenSourceRules.thumbnailSize(width: 0, height: 0) == (1, 1))
    }
}

@Suite struct ScreenSourceGateTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let list = [ScreenSource(kind: .display(1), name: "Built-in", thumbnailPNG: Data([1]))]

    @Test func theFirstRequestOfAFocusedWindowTakesPictures() {
        #expect(ScreenSourceGate().decision(windowFocused: true, now: start) == .enumerate)
    }

    @Test func aWindowThatIsNotFocusedGetsTheListItHad() {
        var gate = ScreenSourceGate()
        #expect(gate.decision(windowFocused: false, now: start) == .serveLast)
        #expect(gate.last.isEmpty)
        gate.served(list, at: start)
        #expect(gate.decision(windowFocused: false, now: start.addingTimeInterval(60)) == .serveLast)
        #expect(gate.last == list)
    }

    @Test func requestsWithinASecondGetTheSameList() {
        var gate = ScreenSourceGate()
        gate.served(list, at: start)
        #expect(gate.decision(windowFocused: true, now: start.addingTimeInterval(0.2)) == .serveLast)
        #expect(gate.decision(windowFocused: true, now: start.addingTimeInterval(0.999)) == .serveLast)
        #expect(gate.decision(windowFocused: true, now: start.addingTimeInterval(1)) == .enumerate)
    }

    @Test func aNewPageStartsWithNothing() {
        var gate = ScreenSourceGate()
        gate.served(list, at: start)
        gate.reset()
        #expect(gate.last.isEmpty)
        #expect(gate.decision(windowFocused: true, now: start.addingTimeInterval(0.1)) == .enumerate)
    }
}
