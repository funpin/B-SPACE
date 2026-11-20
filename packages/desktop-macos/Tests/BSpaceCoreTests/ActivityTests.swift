import Foundation
import Testing
@testable import BSpaceCore

/// `packages/desktop/resources/games.json`, found from this file's place in
/// the repository.
private let seedDictionary = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("desktop/resources/games.json")

private func dictionary(_ json: String) -> GameDictionary? {
    GameDictionary(data: Data(json.utf8))
}

private let two = """
{ "version": 3, "games": [
  { "id": "cs2", "name": "Counter-Strike 2", "processes": ["cs2.exe", "CS2"] },
  { "id": "spotify", "name": "Spotify", "processes": ["Spotify"], "type": "listening" }
] }
"""

@Suite struct GameDictionaryTests {
    @Test func readsTheVersionedFormat() throws {
        let read = try #require(dictionary(two))
        #expect(read.version == 3)
        #expect(read.entries == [
            GameEntry(id: "cs2", name: "Counter-Strike 2", processes: ["cs2.exe", "CS2"], type: "playing"),
            GameEntry(id: "spotify", name: "Spotify", processes: ["Spotify"], type: "listening"),
        ])
    }

    @Test func readsTheOlderBareListAsVersionZero() throws {
        let read = try #require(dictionary(#"[{ "id": "a", "name": "A", "processes": ["a"] }]"#))
        #expect(read.version == 0)
        #expect(read.entries.map(\.id) == ["a"])
    }

    @Test func skipsEntriesThatAreNotGamesAndKeepsTheRest() throws {
        let read = try #require(dictionary("""
        [
          { "id": "ok", "name": "OK", "processes": ["ok"], "type": "dancing" },
          { "id": "", "name": "No id", "processes": ["x"] },
          { "id": "noname", "name": "", "processes": ["x"] },
          { "id": "noprocs", "name": "No processes", "processes": [] },
          { "id": "badprocs", "name": "Bad processes", "processes": ["x", 5] },
          { "name": "Missing id", "processes": ["x"] },
          "a string", 7, null
        ]
        """))
        // An unknown type becomes "playing".
        #expect(read.entries == [GameEntry(id: "ok", name: "OK", processes: ["ok"], type: "playing")])
    }

    @Test func refusesWhatIsNotADictionary() {
        let cases = [
            "", "not json", "null", "7", #""games""#, "{}",
            #"{ "version": "1", "games": [] }"#,
            #"{ "version": 1 }"#,
            #"{ "version": 1, "games": {} }"#,
            #"{ "version": 1.5, "games": [{ "id": "a", "name": "A", "processes": ["a"] }] }"#,
            #"{ "version": true, "games": [{ "id": "a", "name": "A", "processes": ["a"] }] }"#,
            // Nothing in it that could ever match.
            "[]",
            #"{ "version": 2, "games": [{ "id": "", "name": "A", "processes": ["a"] }] }"#,
        ]
        for json in cases {
            #expect(dictionary(json) == nil, "\(json)")
        }
    }

    @Test func readsTheDictionaryTheAppShipsWith() throws {
        let read = try #require(GameDictionary(data: Data(contentsOf: seedDictionary)))
        #expect(read.version >= 1)
        #expect(read.entries.count > 200)
        #expect(read.entries.contains { $0.id == "cs2" })
    }

    @Test func matchesTheFirstListedGameThatIsRunningWhateverTheCase() throws {
        let read = try #require(dictionary(two))
        #expect(read.match(running: ["finder", "cs2", "spotify"])?.id == "cs2")
        #expect(read.match(running: ["spotify", "dock"])?.id == "spotify")
        #expect(read.match(running: ["cs2.exe"])?.id == "cs2")
        #expect(read.match(running: ["finder", "dock"]) == nil)
        #expect(read.match(running: []) == nil)
    }
}

@Suite struct ProcessListTests {
    @Test func readsTheNamesOfWhatIsRunning() {
        let output = "COMM\nlaunchd\n  Finder  \nGoogle Chrome Helper (Renderer)\n\nCS2\n"
        #expect(ProcessList.names(fromPs: output) == ["launchd", "finder", "google chrome helper (renderer)", "cs2"])
    }

    @Test func dropsOnlyTheHeaderLine() {
        #expect(ProcessList.names(fromPs: "COMMAND\nCOMMAND\ncomm\n") == ["command", "comm"])
        #expect(ProcessList.names(fromPs: "bash\nCOMM\n") == ["bash", "comm"])
        #expect(ProcessList.names(fromPs: "").isEmpty)
    }
}

@Suite struct ActivityTrackerTests {
    private let cs2 = GameEntry(id: "cs2", name: "Counter-Strike 2", processes: ["cs2"], type: "playing")
    private let spotify = GameEntry(id: "spotify", name: "Spotify", processes: ["spotify"], type: "listening")

    @Test func reportsAGameOnceWhenItStartsAndOnceWhenItEnds() {
        var tracker = ActivityTracker()
        #expect(tracker.observe(nil, nowMilliseconds: 1000) == nil)
        let started = DetectedActivity(type: "playing", name: "Counter-Strike 2", startedAtMilliseconds: 2000)
        #expect(tracker.observe(cs2, nowMilliseconds: 2000) == .started(started))
        #expect(tracker.current == started)
        // Still running: nothing new, and the start time stays.
        #expect(tracker.observe(cs2, nowMilliseconds: 17_000) == nil)
        #expect(tracker.current?.startedAtMilliseconds == 2000)
        #expect(tracker.observe(nil, nowMilliseconds: 32_000) == .stopped)
        #expect(tracker.current == nil)
        #expect(tracker.observe(nil, nowMilliseconds: 47_000) == nil)
    }

    @Test func anotherGameReplacesTheOneBefore() {
        var tracker = ActivityTracker()
        _ = tracker.observe(cs2, nowMilliseconds: 1000)
        #expect(tracker.observe(spotify, nowMilliseconds: 5000)
            == .started(DetectedActivity(type: "listening", name: "Spotify", startedAtMilliseconds: 5000)))
    }

    @Test func saysWhatThePageIsSent() throws {
        let value = DetectedActivity(type: "playing", name: "Counter-Strike 2", startedAtMilliseconds: 1_763_400_000_123).bridgeValue
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        #expect(String(decoding: data, as: UTF8.self)
            == #"{"name":"Counter-Strike 2","timestamps":{"start":1763400000123},"type":"playing"}"#)
    }
}

@Suite struct GameDictionarySyncTests {
    private func body(version: Int) -> Data {
        Data(#"{ "version": \#(version), "games": [{ "id": "a", "name": "A", "processes": ["a"] }] }"#.utf8)
    }

    @Test func picksTheNewerOfTheSavedAndTheShippedDictionary() {
        #expect(GameDictionarySync.best(cache: body(version: 5), seed: body(version: 3))?.version == 5)
        #expect(GameDictionarySync.best(cache: body(version: 2), seed: body(version: 3))?.version == 3)
        #expect(GameDictionarySync.best(cache: nil, seed: body(version: 3))?.version == 3)
        #expect(GameDictionarySync.best(cache: Data("broken".utf8), seed: body(version: 3))?.version == 3)
        #expect(GameDictionarySync.best(cache: body(version: 4), seed: nil)?.version == 4)
        #expect(GameDictionarySync.best(cache: nil, seed: nil) == nil)
    }

    @Test func adoptsANewerDictionaryFromTheNetwork() {
        let fresh = body(version: 7)
        let outcome = GameDictionarySync.decide(status: 200, body: fresh, etag: "\"abc\"", currentVersion: 3)
        #expect(outcome == .adopt(GameDictionary(data: fresh)!, body: fresh, etag: "\"abc\""))
    }

    @Test func remembersTheTagOfOneThatIsNotNewer() {
        #expect(GameDictionarySync.decide(status: 200, body: body(version: 3), etag: "\"abc\"", currentVersion: 3) == .rememberTag("\"abc\""))
        #expect(GameDictionarySync.decide(status: 200, body: body(version: 1), etag: "\"abc\"", currentVersion: 3) == .rememberTag("\"abc\""))
        #expect(GameDictionarySync.decide(status: 200, body: body(version: 1), etag: nil, currentVersion: 3) == .keep)
    }

    @Test func keepsWhatItHasForAnythingElse() {
        #expect(GameDictionarySync.decide(status: 304, body: Data(), etag: nil, currentVersion: 3) == .keep)
        #expect(GameDictionarySync.decide(status: 404, body: body(version: 9), etag: "\"x\"", currentVersion: 3) == .keep)
        #expect(GameDictionarySync.decide(status: 500, body: Data(), etag: nil, currentVersion: 3) == .keep)
        #expect(GameDictionarySync.decide(status: 200, body: Data("<html>".utf8), etag: "\"x\"", currentVersion: 3) == .keep)
        #expect(GameDictionarySync.decide(status: 200, body: Data("[]".utf8), etag: "\"x\"", currentVersion: 3) == .keep)
    }
}
