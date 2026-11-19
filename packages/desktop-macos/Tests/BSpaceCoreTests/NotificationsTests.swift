import Foundation
import Testing
@testable import BSpaceCore

private let page = URL(string: "https://chat.example.test/channels/1/2")

@Suite struct NotificationRequestTests {
    @Test func readsTheCallsArguments() throws {
        let request = try #require(NotificationRequest(
            arguments: BridgeArguments(["Ann", "hello", ["spaceId": "1", "channelId": "2"]]),
            pageURL: page
        ))
        #expect(request.title == "Ann")
        #expect(request.body == "hello")
        #expect(request.origin == "https://chat.example.test")
        #expect(request.optionsJSON == #"{"channelId":"2","spaceId":"1"}"#)
        #expect(request.userInfo == [
            "origin": "https://chat.example.test",
            "options": #"{"channelId":"2","spaceId":"1"}"#,
        ])
    }

    @Test func doesWithoutABodyOrAPayload() throws {
        let request = try #require(NotificationRequest(arguments: BridgeArguments(["Ann"]), pageURL: page))
        #expect(request.body == "")
        #expect(request.optionsJSON == nil)
        #expect(request.userInfo == ["origin": "https://chat.example.test"])

        // `undefined` arrives as null; a payload that is not an object is none.
        let odd = try #require(NotificationRequest(arguments: BridgeArguments(["Ann", NSNull(), "channel"]), pageURL: page))
        #expect(odd.body == "")
        #expect(odd.optionsJSON == nil)
    }

    @Test func refusesANotificationWithNothingToShow() {
        #expect(NotificationRequest(arguments: BridgeArguments([]), pageURL: page) == nil)
        #expect(NotificationRequest(arguments: BridgeArguments(["", "body"]), pageURL: page) == nil)
        #expect(NotificationRequest(arguments: BridgeArguments([42, "body"]), pageURL: page) == nil)
    }

    @Test func hasNoOriginForAPageThatIsAFile() throws {
        let request = try #require(NotificationRequest(
            arguments: BridgeArguments(["Ann", "hello", ["userId": "7"]]),
            pageURL: URL(fileURLWithPath: "/Applications/picker.html")
        ))
        #expect(request.origin == nil)
        #expect(request.userInfo == ["options": #"{"userId":"7"}"#])
    }
}

@Suite struct NotificationClickTests {
    private let userInfo: [AnyHashable: Any] = [
        "origin": "https://chat.example.test",
        "options": #"{"channelId":"2","spaceId":"1"}"#,
    ]

    @Test func handsThePayloadBackToAPageOfTheSameOrigin() throws {
        let payload = try #require(NotificationRequest.clickPayload(userInfo: userInfo, currentPageURL: page))
        #expect(payload as? [String: String] == ["channelId": "2", "spaceId": "1"])
        // Anywhere on that instance.
        #expect(NotificationRequest.clickPayload(userInfo: userInfo, currentPageURL: URL(string: "https://chat.example.test/")) != nil)
    }

    @Test func keepsThePayloadFromAnotherInstance() {
        func payload(at address: String?) -> [String: Any]? {
            NotificationRequest.clickPayload(userInfo: userInfo, currentPageURL: address.flatMap { URL(string: $0) })
        }
        #expect(payload(at: "https://other.example.test/channels/1/2") == nil)
        #expect(payload(at: "http://chat.example.test/") == nil)
        #expect(payload(at: "https://chat.example.test:8443/") == nil)
        #expect(payload(at: "file:///Applications/picker.html") == nil)
        #expect(payload(at: nil) == nil)
    }

    @Test func sendsNothingForANotificationWithoutAPayloadOrAnOrigin() {
        #expect(NotificationRequest.clickPayload(userInfo: ["origin": "https://chat.example.test"], currentPageURL: page) == nil)
        #expect(NotificationRequest.clickPayload(userInfo: ["options": #"{"userId":"7"}"#], currentPageURL: page) == nil)
        #expect(NotificationRequest.clickPayload(
            userInfo: ["origin": "https://chat.example.test", "options": "not json"],
            currentPageURL: page
        ) == nil)
        #expect(NotificationRequest.clickPayload(userInfo: [:], currentPageURL: page) == nil)
    }
}

@Suite struct BadgeCountTests {
    @Test func showsAWholeNumberFromOneUp() {
        #expect(BadgeCount.label(for: 1) == "1")
        #expect(BadgeCount.label(for: 12) == "12")
        #expect(BadgeCount.label(for: 2.9) == "2")
        #expect(BadgeCount.label(for: 100_000) == "100000")
    }

    @Test func showsNoBadgeOtherwise() {
        #expect(BadgeCount.label(for: 0) == nil)
        #expect(BadgeCount.label(for: 0.5) == nil)
        #expect(BadgeCount.label(for: -3) == nil)
        #expect(BadgeCount.label(for: .nan) == nil)
        #expect(BadgeCount.label(for: .infinity) == nil)
        #expect(BadgeCount.label(for: nil) == nil)
    }

    @Test func readsANumberButNotABoolean() {
        let arguments = BridgeArguments([3, true, "4", NSNull(), 2.5])
        #expect(arguments.number(at: 0) == 3)
        #expect(arguments.number(at: 1) == nil)
        #expect(arguments.number(at: 2) == nil)
        #expect(arguments.number(at: 3) == nil)
        #expect(arguments.number(at: 4) == 2.5)
        #expect(arguments.number(at: 9) == nil)
    }
}
