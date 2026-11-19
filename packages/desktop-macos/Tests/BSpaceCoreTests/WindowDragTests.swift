import Foundation
import Testing
@testable import BSpaceCore

private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [String: Any] {
    ["x": x, "y": y, "width": width, "height": height]
}

@Suite struct DragRegionsTests {
    @Test func readsWhatThePageReports() throws {
        let regions = try #require(DragRegions(arguments: BridgeArguments([[
            "drag": [rect(0, 0, 1280, 33)],
            "noDrag": [rect(1200, 4, 60, 24)],
        ]])))
        #expect(regions.drag == [PlainRect(x: 0, y: 0, width: 1280, height: 33)])
        #expect(regions.noDrag == [PlainRect(x: 1200, y: 4, width: 60, height: 24)])
    }

    @Test func doesWithoutAListOfExceptions() throws {
        let regions = try #require(DragRegions(arguments: BridgeArguments([["drag": [rect(0, 0, 10, 10)]]])))
        #expect(regions.noDrag.isEmpty)

        // A page with nothing to drag by says so with an empty list.
        let none = try #require(DragRegions(arguments: BridgeArguments([["drag": [Any]()]])))
        #expect(none.drag.isEmpty)
    }

    @Test func dropsRectanglesWithNoArea() throws {
        let regions = try #require(DragRegions(arguments: BridgeArguments([[
            "drag": [rect(0, 0, 0, 33), rect(0, 0, 1280, 0), rect(0, 0, 1280, 33)],
            "noDrag": [rect(5, 5, 0, 0)],
        ]])))
        #expect(regions.drag == [PlainRect(x: 0, y: 0, width: 1280, height: 33)])
        #expect(regions.noDrag.isEmpty)
    }

    @Test func refusesAnythingThatIsNotAReport() {
        let many = Array(repeating: rect(0, 0, 1, 1), count: DragRegions.limit + 1)
        let cases: [[Any]] = [
            [],
            [NSNull()],
            ["drag"],
            [[rect(0, 0, 10, 10)]],
            [["noDrag": [rect(0, 0, 10, 10)]]],
            [["drag": rect(0, 0, 10, 10)]],
            [["drag": [rect(0, 0, 10, 10)], "noDrag": "none"]],
            [["drag": [["x": 0, "y": 0, "width": 10]]]],
            [["drag": [["x": "0", "y": 0, "width": 10, "height": 10]]]],
            [["drag": [["x": true, "y": 0, "width": 10, "height": 10]]]],
            [["drag": [rect(0, 0, -10, 10)]]],
            [["drag": [rect(0, 0, 10, -10)]]],
            [["drag": [rect(.nan, 0, 10, 10)]]],
            [["drag": [rect(0, 0, .infinity, 10)]]],
            [["drag": ["0,0,10,10"]]],
            [["drag": many]],
            [["drag": [Any](), "noDrag": many]],
        ]
        for arguments in cases {
            #expect(DragRegions(arguments: BridgeArguments(arguments)) == nil)
        }
    }

    @Test func takesAsManyRectanglesAsTheLimit() {
        let full = Array(repeating: rect(0, 0, 1, 1), count: DragRegions.limit)
        #expect(DragRegions(arguments: BridgeArguments([["drag": full, "noDrag": full]])) != nil)
    }

    @Test func aPointDragsInsideARegionAndOutsideEveryException() {
        let regions = DragRegions(
            drag: [PlainRect(x: 0, y: 0, width: 1280, height: 33), PlainRect(x: 300, y: 100, width: 50, height: 50)],
            noDrag: [PlainRect(x: 1200, y: 4, width: 60, height: 24)]
        )
        #expect(regions.contains(x: 640, y: 10))
        #expect(regions.contains(x: 0, y: 0))
        #expect(regions.contains(x: 320, y: 120))
        // The far edges are outside, like the edges of an element.
        #expect(!regions.contains(x: 640, y: 33))
        #expect(!regions.contains(x: 1280, y: 10))
        #expect(!regions.contains(x: 640, y: 60))
        // An exception wins over the region it sits in.
        #expect(!regions.contains(x: 1210, y: 10))
        #expect(regions.contains(x: 1210, y: 30))
        #expect(regions.contains(x: 1199, y: 10))
    }
}

@Suite struct WindowDragMapTests {
    @Test func aPageThatReportedNothingDragsByTheTopStrip() {
        let map = WindowDragMap()
        #expect(map.canDrag(x: 640, y: 0))
        #expect(map.canDrag(x: 0, y: 31.5))
        #expect(map.canDrag(x: 5000, y: 10))
        #expect(!map.canDrag(x: 640, y: 32))
        #expect(!map.canDrag(x: 640, y: 400))
        #expect(!map.canDrag(x: 640, y: -1))
        #expect(!map.canDrag(x: -1, y: 10))
    }

    @Test func aReportReplacesTheTopStrip() {
        var map = WindowDragMap()
        map.report(DragRegions(drag: [PlainRect(x: 100, y: 50, width: 200, height: 20)]))
        #expect(!map.canDrag(x: 640, y: 10))
        #expect(map.canDrag(x: 150, y: 60))

        // A page that says it has nothing to drag by is believed.
        map.report(DragRegions(drag: []))
        #expect(!map.canDrag(x: 150, y: 60))
        #expect(!map.canDrag(x: 640, y: 10))
    }

    @Test func anotherPageStartsFromTheTopStripAgain() {
        var map = WindowDragMap()
        map.report(DragRegions(drag: []))
        map.pageChanged()
        #expect(map.canDrag(x: 640, y: 10))
    }
}

@Suite struct StayRectsTests {
    /// Whether a point is covered by one of the rectangles.
    private func covered(_ rects: [PlainRect], _ x: Double, _ y: Double) -> Bool {
        rects.contains { x >= $0.x && x < $0.x + $0.width && y >= $0.y && y < $0.y + $0.height }
    }

    @Test func aPageThatReportedNothingStaysAPageBelowTheTopStrip() {
        #expect(WindowDragMap().stayRects(width: 1280, height: 800) == [PlainRect(x: 0, y: 32, width: 1280, height: 768)])
    }

    @Test func theExceptionsAreAddedToWhatIsLeftOfThePage() {
        var map = WindowDragMap()
        map.report(DragRegions(
            drag: [PlainRect(x: 0, y: 0, width: 1280, height: 33)],
            noDrag: [PlainRect(x: 1200, y: 4, width: 60, height: 24)]
        ))
        #expect(map.stayRects(width: 1280, height: 800) == [
            PlainRect(x: 0, y: 33, width: 1280, height: 767),
            PlainRect(x: 1200, y: 4, width: 60, height: 24),
        ])
    }

    @Test func aRegionInTheMiddleLeavesFourPiecesAroundIt() {
        var map = WindowDragMap()
        map.report(DragRegions(drag: [PlainRect(x: 200, y: 300, width: 100, height: 40)]))
        #expect(map.stayRects(width: 1280, height: 800) == [
            PlainRect(x: 0, y: 0, width: 1280, height: 300),
            PlainRect(x: 0, y: 340, width: 1280, height: 460),
            PlainRect(x: 0, y: 300, width: 200, height: 40),
            PlainRect(x: 300, y: 300, width: 980, height: 40),
        ])
    }

    @Test func aPageWithNothingToDragByStaysAPageEverywhere() {
        var map = WindowDragMap()
        map.report(DragRegions(drag: []))
        #expect(map.stayRects(width: 1280, height: 800) == [PlainRect(x: 0, y: 0, width: 1280, height: 800)])
    }

    @Test func aWindowWiderThanTheReportStaysAPageBesideIt() {
        // The window grew and the page has not measured itself again yet.
        var map = WindowDragMap()
        map.report(DragRegions(drag: [PlainRect(x: 0, y: 0, width: 1280, height: 33)]))
        #expect(map.stayRects(width: 1500, height: 800) == [
            PlainRect(x: 0, y: 33, width: 1500, height: 767),
            PlainRect(x: 1280, y: 0, width: 220, height: 33),
        ])
    }

    @Test func whatLiesOutsideTheViewIsCutOff() {
        var map = WindowDragMap()
        map.report(DragRegions(
            drag: [PlainRect(x: -50, y: -10, width: 2000, height: 43)],
            noDrag: [PlainRect(x: 1250, y: 4, width: 100, height: 24), PlainRect(x: 3000, y: 0, width: 10, height: 10)]
        ))
        #expect(map.stayRects(width: 1280, height: 800) == [
            PlainRect(x: 0, y: 33, width: 1280, height: 767),
            PlainRect(x: 1250, y: 4, width: 30, height: 24),
        ])
        #expect(map.stayRects(width: 0, height: 0).isEmpty)
    }

    @Test func everyPointEitherDragsOrIsCovered() {
        var map = WindowDragMap()
        map.report(DragRegions(
            drag: [
                PlainRect(x: 0, y: 0, width: 640, height: 33),
                PlainRect(x: 600, y: 20, width: 300, height: 60),
                PlainRect(x: 100, y: 400, width: 50, height: 50),
            ],
            noDrag: [PlainRect(x: 610, y: 10, width: 40, height: 40), PlainRect(x: 120, y: 420, width: 100, height: 10)]
        ))
        for candidate in [WindowDragMap(), map] {
            let stay = candidate.stayRects(width: 1000, height: 600)
            for x in stride(from: 0.5, to: 1000, by: 7) {
                for y in stride(from: 0.5, to: 600, by: 5) {
                    #expect(covered(stay, x, y) != candidate.canDrag(x: x, y: y), "at \(x), \(y)")
                }
            }
        }
    }
}

@Suite struct TitleBarDoubleClickTests {
    @Test func followsTheSystemSetting() {
        #expect(TitleBarDoubleClick.action(setting: "Maximize", minimizesOnDoubleClick: false) == .zoom)
        #expect(TitleBarDoubleClick.action(setting: "Minimize", minimizesOnDoubleClick: false) == .minimize)
        #expect(TitleBarDoubleClick.action(setting: "None", minimizesOnDoubleClick: false) == .nothing)
    }

    @Test func theSettingWinsOverTheOlderOne() {
        #expect(TitleBarDoubleClick.action(setting: "Maximize", minimizesOnDoubleClick: true) == .zoom)
        #expect(TitleBarDoubleClick.action(setting: "None", minimizesOnDoubleClick: true) == .nothing)
    }

    @Test func fallsBackToTheOlderSettingAndThenToZoom() {
        #expect(TitleBarDoubleClick.action(setting: nil, minimizesOnDoubleClick: true) == .minimize)
        #expect(TitleBarDoubleClick.action(setting: nil, minimizesOnDoubleClick: false) == .zoom)
        // "Fill", and whatever a later system adds, has no public call: zoom
        // is the nearest thing the window can do.
        #expect(TitleBarDoubleClick.action(setting: "Fill", minimizesOnDoubleClick: false) == .zoom)
        #expect(TitleBarDoubleClick.action(setting: "Fill", minimizesOnDoubleClick: true) == .zoom)
    }
}
