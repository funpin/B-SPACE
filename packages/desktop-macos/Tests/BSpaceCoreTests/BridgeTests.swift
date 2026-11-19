import Foundation
import Testing
@testable import BSpaceCore

/// `packages/desktop/src/bridgeContract.json`, found from this file's place in
/// the repository: the tests read the description both shells are held to, not
/// a copy of it.
private func repositoryContractData() throws -> Data {
    let packages = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // BSpaceCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // desktop-macos
        .deletingLastPathComponent() // packages
    return try Data(contentsOf: packages.appendingPathComponent("desktop/src/bridgeContract.json"))
}

private func contract(_ json: String) throws -> BridgeContract {
    try BridgeContract(data: Data(json.utf8))
}

private let small = """
{
  "backspace": [
    { "name": "platform", "kind": "value" },
    { "name": "ping", "kind": "fire", "channel": "ping" },
    { "name": "ask", "kind": "invoke", "channel": "ask" },
    { "name": "onNews", "kind": "subscribe", "channel": "news", "unsubscribe": true }
  ],
  "bspaceUpdate": []
}
"""

@Suite struct BridgeContractTests {
    @Test func readsTheRepositoryContract() throws {
        let contract = try BridgeContract(data: repositoryContractData())
        #expect(contract.members(of: .backspace).count == 71)
        #expect(contract.members(of: .backspace).filter { $0.nativeOnly == true }.map(\.name) == [
            "setDragRegions", "openKeybindPermissionSettings",
            "startNativeScreenCapture", "stopNativeScreenCapture", "onNativeScreenCaptureEnded",
            "startNativeSystemAudio", "stopNativeSystemAudio", "onNativeSystemAudioEnded",
            "startNativeScreenShare", "updateNativeScreenShare", "stopNativeScreenShare", "onNativeScreenShareEvent",
        ])
        #expect(contract.callChannels(of: .backspace)["set-drag-regions"] == .fire)
        #expect(contract.eventChannels(of: .backspace).count == 20)
        #expect(contract.members(of: .bspaceUpdate).count == 6)
        #expect(contract.callChannels(of: .backspace)["get-app-version"] == .invoke)
        #expect(contract.callChannels(of: .backspace)["minimize-window"] == .fire)
    }

    @Test func rejectsAMalformedDescription() {
        let cases = [
            #"{"backspace": []}"#,
            #"{"backspace": [], "bspaceUpdate": [], "other": []}"#,
            #"{"backspace": [{"name": "a", "kind": "stream", "channel": "a"}], "bspaceUpdate": []}"#,
            #"{"backspace": [{"name": "a", "kind": "fire"}], "bspaceUpdate": []}"#,
            #"{"backspace": [{"name": "a", "kind": "value", "channel": "a"}], "bspaceUpdate": []}"#,
            #"{"backspace": [{"name": "a", "kind": "subscribe", "channel": "a"}], "bspaceUpdate": []}"#,
            #"{"backspace": [{"name": "a", "kind": "fire", "channel": "a", "unsubscribe": true}], "bspaceUpdate": []}"#,
            #"{"backspace": [{"name": "a", "kind": "fire", "channel": "a"}, {"name": "a", "kind": "fire", "channel": "b"}], "bspaceUpdate": []}"#,
            #"{"backspace": [{"name": "a", "kind": "fire", "channel": "a"}, {"name": "b", "kind": "invoke", "channel": "a"}], "bspaceUpdate": []}"#,
            #"{"backspace": [{"name": "a b", "kind": "fire", "channel": "a"}], "bspaceUpdate": []}"#,
            #"{"backspace": [{"name": "a", "kind": "fire", "channel": "a", "nativeOnly": false}], "bspaceUpdate": []}"#,
            #"{"backspace": [{"name": "a", "kind": "fire", "channel": "a", "nativeOnly": "yes"}], "bspaceUpdate": []}"#,
        ]
        for json in cases {
            #expect(throws: BridgeContract.Malformed.self) { try contract(json) }
        }
    }
}

@Suite struct BridgeScriptTests {
    @Test func embedsEveryMemberAndTheValues() throws {
        let source = try BridgeScript.source(bridge: .backspace, contract: contract(small), values: ["platform": "darwin"])
        #expect(source.contains(#"{"kind":"value","name":"platform"}"#))
        #expect(source.contains(#"{"channel":"news","kind":"subscribe","name":"onNews","unsubscribe":true}"#))
        // The page tells the shell when it starts listening on a channel.
        #expect(source.contains("send('subscribe', member.channel, [])"))
        #expect(source.contains(#"const values = {"platform":"darwin"};"#))
        #expect(source.contains(#"window.webkit.messageHandlers["backspace"]"#))
        #expect(source.contains(#"Object.defineProperty(window, "__backspaceDeliver""#))
    }

    @Test func refusesAValueMemberTheShellGivesNoValue() throws {
        #expect(throws: BridgeContract.Malformed.self) {
            try BridgeScript.source(bridge: .backspace, contract: contract(small), values: [:])
        }
    }

    @Test func escapesWhatCannotStandInAStringLiteral() throws {
        let literal = try BridgeScript.literal("a\u{2028}b\u{2029}c\"d")
        // Neither separator survives as itself; each is spelled as an escape.
        #expect(!literal.unicodeScalars.contains { $0.value == 0x2028 || $0.value == 0x2029 })
        #expect(literal.contains("u2028b") && literal.contains("u2029c"))
        // And the literal still reads back as the string it was made from.
        let decoded = try JSONSerialization.jsonObject(with: Data(literal.utf8), options: [.fragmentsAllowed]) as? String
        #expect(decoded?.unicodeScalars.map(\.value) == [0x61, 0x2028, 0x62, 0x2029, 0x63, 0x22, 0x64])
    }
}

@Suite struct BridgeRouterTests {
    private func router() throws -> BridgeRouter {
        BridgeRouter(contract: try contract(small), bridge: .backspace)
    }

    private func message(_ router: BridgeRouter, kind: String, channel: String, args: String = "[]") throws -> BridgeMessage {
        try router.decode(["kind": kind, "channel": channel, "args": args]).get()
    }

    @Test func listsTheChannelsNobodyAnswers() throws {
        let router = try router()
        #expect(router.unhandledChannels == ["ask", "ping"])
        router.onFire("ping") { _ in }
        router.onInvoke("ask", answering: { _ in .null })
        #expect(router.unhandledChannels.isEmpty)
    }

    @Test func runsAFireHandlerAndAnswersUndefined() throws {
        let router = try router()
        var seen: [String] = []
        router.onFire("ping") { arguments in seen.append(arguments.string(at: 0) ?? "none") }

        var replies: [BridgeReply] = []
        router.dispatch(try message(router, kind: "fire", channel: "ping", args: #"["hello"]"#)) { replies.append($0) }

        #expect(seen == ["hello"])
        guard replies.count == 1, case .undefined = replies[0] else {
            Issue.record("expected one undefined reply, got \(replies)")
            return
        }
    }

    @Test func answersAnInvokeExactlyOnce() throws {
        let router = try router()
        router.onInvoke("ask") { _, reply in
            reply(.value("first"))
            reply(.value("second"))
        }
        var replies: [BridgeReply] = []
        router.dispatch(try message(router, kind: "invoke", channel: "ask")) { replies.append($0) }

        guard replies.count == 1, case .value(let value) = replies[0] else {
            Issue.record("expected one reply, got \(replies)")
            return
        }
        #expect(value as? String == "first")
    }

    @Test func tellsWhenThePageSubscribes() throws {
        let router = try router()
        var subscriptions = 0
        router.onSubscribe("news") { subscriptions += 1 }

        var replies: [BridgeReply] = []
        let subscription = try message(router, kind: "subscribe", channel: "news")
        router.dispatch(subscription) { replies.append($0) }
        router.dispatch(subscription) { replies.append($0) }

        #expect(subscriptions == 2)
        guard replies.count == 2, case .undefined = replies[0], case .undefined = replies[1] else {
            Issue.record("expected two undefined replies, got \(replies)")
            return
        }
    }

    @Test func acceptsASubscriptionNobodyWaitsFor() throws {
        let router = try router()
        var replies: [BridgeReply] = []
        router.dispatch(try message(router, kind: "subscribe", channel: "news")) { replies.append($0) }
        guard replies.count == 1, case .undefined = replies[0] else {
            Issue.record("expected one undefined reply, got \(replies)")
            return
        }
    }

    @Test func refusesWhatTheContractDoesNotAllow() throws {
        let router = try router()
        router.onFire("ping") { _ in }
        router.onInvoke("ask", answering: { _ in .null })

        #expect(router.decode("not an object").failure != nil)
        #expect(router.decode(["kind": "fire", "channel": "ping"]).failure != nil)
        #expect(router.decode(["kind": "fire", "channel": "unknown", "args": "[]"]).failure == BridgeError("No handler registered for 'unknown'"))
        #expect(router.decode(["kind": "invoke", "channel": "ping", "args": "[]"]).failure != nil)
        #expect(router.decode(["kind": "fire", "channel": "ask", "args": "[]"]).failure != nil)
        #expect(router.decode(["kind": "subscribe", "channel": "ping", "args": "[]"]).failure == BridgeError("'ping' is not an event channel"))
        #expect(router.decode(["kind": "subscribe", "channel": "unknown", "args": "[]"]).failure != nil)
        #expect(router.decode(["kind": "value", "channel": "news", "args": "[]"]).failure != nil)
        #expect(router.decode(["kind": "fire", "channel": "ping", "args": "{}"]).failure != nil)
        #expect(router.decode(["kind": "fire", "channel": "ping", "args": "not json"]).failure != nil)
    }

    @Test func readsArgumentsByTheirJavaScriptType() {
        let arguments = BridgeArguments(["text", true, 1, NSNull(), ["a", "b"], ["key": "value"]] as [Any])
        #expect(arguments.string(at: 0) == "text")
        #expect(arguments.bool(at: 1) == true)
        #expect(arguments.bool(at: 2) == nil)
        #expect(arguments.string(at: 3) == nil)
        #expect(arguments.array(at: 4)?.count == 2)
        #expect(arguments.object(at: 5)?["key"] as? String == "value")
        #expect(arguments.string(at: 9) == nil)
    }
}

@Suite struct InterimRepliesTests {
    /// The channels `MainWindowController` answers for real in stage 1. Listed
    /// here so the test fails when the interim table and the real handlers
    /// stop adding up to the whole contract.
    private let ported: Set<String> = [
        "minimize-window", "maximize-window", "close-window", "set-connected-origins",
        "get-app-version", "is-sandboxed", "get-instance-url", "set-instance-url", "clear-instance-url",
        "get-auto-launch-settings", "set-auto-launch-settings",
        "show-notification", "set-badge-count", "set-language",
        "renderer-ready", "recovery-action", "get-recovery-state",
        "set-drag-regions", "set-tray-state", "set-tray-context", "get-current-activity",
        "keybinds-sync", "check-accessibility", "keybind-portal-status", "keybind-portal-retry",
        "open-keybind-permission-settings", "get-screen-sources", "get-screen-share-picker-mode",
        "native-screen-capture-start", "native-screen-capture-stop",
        "get-system-audio-capability", "native-system-audio-start", "native-system-audio-stop",
        "native-screen-share-start", "native-screen-share-update", "native-screen-share-stop",
        "stream-pointer-overlay", "stream-pointer-overlay-end",
    ]

    @Test func coverExactlyTheChannelsThatAreNotPortedYet() throws {
        let contract = try BridgeContract(data: repositoryContractData())
        let channels = contract.callChannels(of: .backspace)
        let interimInvokes = Set(InterimReplies.invokeReplies().keys)

        #expect(InterimReplies.fireChannels.isDisjoint(with: interimInvokes))
        #expect(InterimReplies.fireChannels.allSatisfy { channels[$0] == .fire })
        #expect(interimInvokes.allSatisfy { channels[$0] == .invoke })

        let interim = InterimReplies.fireChannels.union(interimInvokes)
        #expect(interim.isDisjoint(with: ported))
        #expect(interim.union(ported) == Set(channels.keys))
    }

    @Test func leaveNothingUnhandledOnceRegistered() throws {
        let contract = try BridgeContract(data: repositoryContractData())
        let router = BridgeRouter(contract: contract, bridge: .backspace)
        InterimReplies.register(on: router)
        #expect(Set(router.unhandledChannels) == ported)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
