import Foundation
import Testing
@testable import ProbeSupport

@Suite struct ProbeOptionsTests {
    @Test func parsesEveryOption() throws {
        let options = try ProbeOptions.parse([
            "--url", "http://localhost:5173/dev-voice-grid.html",
            "--size", "940x500",
            "--script", "probe.js",
            "--call", "window.runProbe()",
            "--out", "out.json",
            "--snapshot", "shot.png",
            "--window-capture", "window.png",
            "--settle-ms", "1500",
            "--timeout", "20",
            "--ua-app-name", "Version/27.2 Safari/605.1.15 BSpaceDesktop/2.3.2",
            "--titlebar", "hiddenInset",
            "--activate",
            "--ephemeral",
            "--unfiltered-ice",
            "--download-dir", "/tmp/downloads",
            "--default", "WebAutomaticQuoteSubstitutionEnabled=false",
            "--default", "Name=a=b",
        ])

        #expect(options.url.absoluteString == "http://localhost:5173/dev-voice-grid.html")
        #expect(options.width == 940)
        #expect(options.height == 500)
        #expect(options.scriptPath == "probe.js")
        #expect(options.callExpression == "window.runProbe()")
        #expect(options.outPath == "out.json")
        #expect(options.snapshotPath == "shot.png")
        #expect(options.windowCapturePath == "window.png")
        #expect(options.settleMilliseconds == 1500)
        #expect(options.timeoutSeconds == 20)
        #expect(options.applicationNameForUserAgent == "Version/27.2 Safari/605.1.15 BSpaceDesktop/2.3.2")
        #expect(options.titleBar == .hiddenInset)
        #expect(options.activate)
        #expect(options.ephemeral)
        #expect(options.unfilteredICE)
        #expect(options.downloadDirectory == "/tmp/downloads")
        #expect(options.defaults == ["WebAutomaticQuoteSubstitutionEnabled": "false", "Name": "a=b"])
    }

    @Test func defaultsMatchTheAppWindow() throws {
        let options = try ProbeOptions.parse(["--url", "https://example.org/"])
        #expect(options.width == 1280)
        #expect(options.height == 800)
        #expect(options.titleBar == .standard)
        #expect(options.scriptPath == nil)
        #expect(options.callExpression == nil)
        #expect(!options.activate)
        #expect(!options.ephemeral)
        #expect(!options.unfilteredICE)
        #expect(options.defaults.isEmpty)
    }

    @Test func rejectsWhatItCannotUse() {
        #expect(throws: ProbeOptions.ParseError.missingURL) { try ProbeOptions.parse([]) }
        #expect(throws: ProbeOptions.ParseError.missingValue("--url")) { try ProbeOptions.parse(["--url"]) }
        #expect(throws: ProbeOptions.ParseError.unknownOption("--nope")) {
            try ProbeOptions.parse(["--url", "https://example.org/", "--nope"])
        }
        #expect(throws: ProbeOptions.ParseError.invalid(option: "--url", value: "no-scheme")) {
            try ProbeOptions.parse(["--url", "no-scheme"])
        }
        #expect(throws: ProbeOptions.ParseError.invalid(option: "--size", value: "1280")) {
            try ProbeOptions.parse(["--url", "https://example.org/", "--size", "1280"])
        }
        #expect(throws: ProbeOptions.ParseError.invalid(option: "--size", value: "0x500")) {
            try ProbeOptions.parse(["--url", "https://example.org/", "--size", "0x500"])
        }
        #expect(throws: ProbeOptions.ParseError.invalid(option: "--settle-ms", value: "-1")) {
            try ProbeOptions.parse(["--url", "https://example.org/", "--settle-ms", "-1"])
        }
        #expect(throws: ProbeOptions.ParseError.invalid(option: "--titlebar", value: "glass")) {
            try ProbeOptions.parse(["--url", "https://example.org/", "--titlebar", "glass"])
        }
        #expect(throws: ProbeOptions.ParseError.invalid(option: "--default", value: "novalue")) {
            try ProbeOptions.parse(["--url", "https://example.org/", "--default", "novalue"])
        }
    }

    @Test func convertsPageCoordinatesToWindowCoordinates() {
        let top = windowPoint(clientX: 10, clientY: 0, contentHeight: 800)
        #expect(top.x == 10)
        #expect(top.y == 800)
        let middle = windowPoint(clientX: 640.5, clientY: 300, contentHeight: 800)
        #expect(middle.x == 640.5)
        #expect(middle.y == 500)
    }
}
