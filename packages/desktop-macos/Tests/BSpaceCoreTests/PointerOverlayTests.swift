import Foundation
import Testing
@testable import BSpaceCore

@Suite struct OverlayPointersTests {
    private func entry(_ changes: [String: Any?] = [:]) -> [String: Any] {
        var entry: [String: Any] = [
            "id": "alice", "name": "Alice", "color": "rgb(110 91 239)", "x": 0.25, "y": 0.75, "idle": false, "ping": 0,
        ]
        for (key, value) in changes {
            entry[key] = value
        }
        return entry
    }

    @Test func readsAPointerAsThePageSendsIt() {
        let pointers = OverlayPointers.sanitized([entry(["idle": true, "ping": 1731950000000.0])])
        #expect(pointers == [OverlayPointer(
            id: "alice", name: "Alice", color: OverlayColor(red: 110, green: 91, blue: 239),
            x: 0.25, y: 0.75, isIdle: true, ping: 1731950000000
        )])
    }

    @Test func whatIsNotAListIsNoPointers() {
        #expect(OverlayPointers.sanitized(nil).isEmpty)
        #expect(OverlayPointers.sanitized("pointers").isEmpty)
        #expect(OverlayPointers.sanitized(["id": "alice"]).isEmpty)
    }

    @Test func leavesOutAnEntryWithoutAnIDOrAPlace() {
        let pointers = OverlayPointers.sanitized([
            "alice", NSNull(),
            entry(["id": ""]), entry(["id": 7]), entry(["id": nil]),
            entry(["id": String(repeating: "a", count: 129)]),
            entry(["x": 1.01]), entry(["y": -0.01]), entry(["x": "0.5"]), entry(["x": true]),
            entry(["y": Double.nan]), entry(["x": Double.infinity]), entry(["y": nil]),
            entry(["id": "kept"]),
        ])
        #expect(pointers.map(\.id) == ["kept"])
    }

    @Test func theEdgesOfThePictureAreInIt() {
        let pointers = OverlayPointers.sanitized([entry(["x": 0, "y": 1])])
        #expect(pointers.first?.x == 0)
        #expect(pointers.first?.y == 1)
    }

    @Test func anIDMayBeAsLongAsTheLimit() {
        #expect(OverlayPointers.sanitized([entry(["id": String(repeating: "a", count: 128)])]).count == 1)
    }

    @Test func showsNoMoreThanTheLimit() {
        let many = (0..<40).map { entry(["id": "p\($0)"]) }
        let pointers = OverlayPointers.sanitized(many)
        #expect(pointers.count == OverlayPointers.most)
        #expect(pointers.last?.id == "p31")
    }

    @Test func cutsANameThatIsTooLong() {
        let long = OverlayPointers.sanitized([entry(["name": String(repeating: "я", count: 100)])])
        #expect(long.first?.name == String(repeating: "я", count: 64))
        // An emoji is two UTF-16 units: 32 of them fill the limit, and the
        // cut never ends in half of one.
        let emoji = OverlayPointers.sanitized([entry(["name": "a" + String(repeating: "😀", count: 40)])])
        #expect(emoji.first?.name == "a" + String(repeating: "😀", count: 31))
    }

    @Test func aNameThatIsNotTextIsNoName() {
        #expect(OverlayPointers.sanitized([entry(["name": 5])]).first?.name == "")
        #expect(OverlayPointers.sanitized([entry(["name": nil])]).first?.name == "")
    }

    @Test func aColourThatCannotBeReadIsReplaced() {
        for color in ["red", "#6e5bef", "rgb(1 2)", "rgba(1, 2, 3, 0.5)", "rgb(1 2 3); x", " rgb(1 2 3)", "rgb(1.5 2 3)", "rgb(-1 2 3)"] {
            #expect(OverlayPointers.sanitized([entry(["color": color])]).first?.color == .fallback, "\(color)")
        }
        #expect(OverlayPointers.sanitized([entry(["color": 3])]).first?.color == .fallback)
    }

    @Test func readsBothFormsOfAComputedColour() {
        #expect(OverlayColor(css: "rgb(1 2 3)") == OverlayColor(red: 1, green: 2, blue: 3))
        #expect(OverlayColor(css: "rgb(1, 2, 3)") == OverlayColor(red: 1, green: 2, blue: 3))
        #expect(OverlayColor(css: "rgb( 255 ,0,  128 )") == OverlayColor(red: 255, green: 0, blue: 128))
        #expect(OverlayColor(css: "rgb(999 256 0)") == OverlayColor(red: 255, green: 255, blue: 0))
    }

    @Test func onlyTrueIsIdleAndOnlyAPositiveNumberIsAClick() {
        let pointers = OverlayPointers.sanitized([
            entry(["id": "a", "idle": 1, "ping": -5]),
            entry(["id": "b", "idle": "true", "ping": "7"]),
            entry(["id": "c", "idle": nil, "ping": Double.infinity]),
            entry(["id": "d", "idle": true, "ping": true]),
        ])
        #expect(pointers.map(\.isIdle) == [false, false, false, true])
        #expect(pointers.map(\.ping) == [0, 0, 0, 0])
    }
}

@Suite struct PointerOverlayTargetTests {
    @Test func noCaptureIsNoDisplay() {
        #expect(PointerOverlayTarget().display == nil)
    }

    @Test func aShareOfADisplayPutsThePointersOnIt() {
        var target = PointerOverlayTarget()
        target.started("a", display: 1)
        #expect(target.display == 1)
        target.stopped("a")
        #expect(target.display == nil)
    }

    @Test func aShareOfAWindowHasNone() {
        var target = PointerOverlayTarget()
        target.started("a", display: nil)
        #expect(target.display == nil)
    }

    @Test func theSameDisplayAtAnotherSizeKeepsThePointersWhereTheyAre() {
        var target = PointerOverlayTarget()
        target.started("a", display: 1)
        target.started("b", display: 1)
        target.stopped("a")
        #expect(target.display == 1)
    }

    @Test func aPreviewOfAnotherDisplayTakesThemAndGivesThemBack() {
        var target = PointerOverlayTarget()
        target.started("share", display: 1)
        target.started("preview", display: 2)
        #expect(target.display == 2)
        target.stopped("preview")
        #expect(target.display == 1)
    }

    @Test func aPreviewOfAWindowLeavesThemOnTheSharedDisplay() {
        var target = PointerOverlayTarget()
        target.started("share", display: 1)
        target.started("preview", display: nil)
        #expect(target.display == 1)
        // The share moved to the window.
        target.stopped("share")
        #expect(target.display == nil)
    }

    @Test func stoppingWhatNeverStartedChangesNothing() {
        var target = PointerOverlayTarget()
        target.started("a", display: 1)
        target.stopped("b")
        #expect(target.display == 1)
    }
}
