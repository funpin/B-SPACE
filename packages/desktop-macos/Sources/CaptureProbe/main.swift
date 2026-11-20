// CaptureProbe answers the question stage 4 of the native client starts with:
// when a ScreenCaptureKit capture of system audio leaves this application out,
// does it also leave out what the application's web view plays?
//
// A web view does not play sound in the application's own process: WebKit's
// helper processes do. The client streams system audio next to a voice call,
// and if the call's own sound came back through the capture, everybody would
// hear themselves.
//
// The probe opens a page that plays quiet tones, one through each way a page
// makes sound (Web Audio, a media element playing a file, a media element
// playing a live stream, a media element playing a WebRTC track), records
// system audio under each way of excluding the application, and reports which
// tones each recording holds. A second copy of the probe, in a bundle with
// another identifier, plays the same four paths at other frequencies. It is
// "some other application", whose sound a recording has to keep, and, being
// started through LaunchServices whatever the probe was started by, it is
// also the subject of the question: excluding it shows what excluding an
// application does to its web view's sound.
//
// Run it through scripts/capture-probe.sh. What the system counts as "this
// application" depends on how the process was started: started from a
// terminal, the probe and WebKit's helpers answer to the terminal's
// application; started through LaunchServices, to the probe itself, as the
// client will.

import AppKit
import CoreMedia
import ProbeSupport
import ScreenCaptureKit
import WebKit

private struct Options {
    /// Ask the system for the Screen Recording permission when it is missing.
    /// Off by default: the request puts a system dialog on the screen.
    var requestPermission = false
    /// Run as an ordinary application (a Dock icon), as the client does.
    var regular = false
    /// Amplitude of each tone; 0.05 is about 26 dB under full scale.
    var gain = 0.05
    /// Length of each recording.
    var seconds = 2.5
    var outPath: String?
    /// Bundle of the second copy, which plays the other application's tones.
    var companionPath: String?
    /// Be that second copy: play the tones from this frequency up, record nothing.
    var playOnly: Double?
    /// How long the second copy plays before it exits by itself.
    var toneSeconds = 60.0

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var index = 0
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        func number(_ range: ClosedRange<Double>) -> Double? {
            guard let raw = value(), let parsed = Double(raw), range.contains(parsed) else { return nil }
            return parsed
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--request-permission": options.requestPermission = true
            case "--regular": options.regular = true
            case "--gain":
                guard let gain = number(0.001...0.5) else { return nil }
                options.gain = gain
            case "--seconds":
                guard let seconds = number(1...30) else { return nil }
                options.seconds = seconds
            case "--out":
                guard let path = value() else { return nil }
                options.outPath = path
            case "--companion":
                guard let path = value() else { return nil }
                options.companionPath = path
            case "--play-only":
                guard let frequency = number(100...8000) else { return nil }
                options.playOnly = frequency
            case "--tone-seconds":
                guard let seconds = number(1...600) else { return nil }
                options.toneSeconds = seconds
            default:
                return nil
            }
            index += 1
        }
        return options
    }
}

/// The audio paths of a page, in the order the page gives them frequencies:
/// the first plays the base frequency, each next one 400 Hz higher.
private let audioPaths = ["webAudio", "mediaElement", "mediaStream", "webRTC"]
private let pathSpacing = 400.0
/// The probe's own tones start here, the second copy's above them.
private let ownBaseFrequency = 700.0
private let otherBaseFrequency = 2300.0

private func tones(of owner: String, from base: Double) -> [(name: String, frequency: Double)] {
    audioPaths.enumerated().map { index, path in
        ("\(owner).\(path)", base + Double(index) * pathSpacing)
    }
}

private let toneFrequencies = tones(of: "own", from: ownBaseFrequency) + tones(of: "other", from: otherBaseFrequency)

private let pageSource = """
<!doctype html>
<meta charset="utf-8">
<title>CaptureProbe</title>
<body>
<script>
// Four tones, 400 Hz apart from `base` up, one through each audio path.
window.startTones = async (gain, base) => {
  const report = {};
  const context = new AudioContext();
  await context.resume();
  report.contextState = context.state;
  report.contextSampleRate = context.sampleRate;

  const tone = (frequency, destination) => {
    const oscillator = context.createOscillator();
    oscillator.frequency.value = frequency;
    const level = context.createGain();
    level.gain.value = gain;
    oscillator.connect(level).connect(destination);
    oscillator.start();
  };
  const play = async (element) => {
    try {
      await element.play();
      return element.paused ? 'paused' : 'playing';
    } catch (error) {
      return 'refused: ' + error.name;
    }
  };

  // 1. Web Audio straight to the output.
  tone(base, context.destination);

  // 2. A media element playing a file: two minutes of a sine, longer than
  // the probe runs. A short file on a loop does not do: the element starts
  // it late, or sits at zero while it claims to play.
  const rate = 48000;
  const pcm = new Int16Array(rate * 120);
  for (let i = 0; i < pcm.length; i++) {
    pcm[i] = Math.round(32767 * gain * Math.sin(2 * Math.PI * (base + 400) * i / rate));
  }
  const header = new DataView(new ArrayBuffer(44));
  const text = (offset, value) => {
    for (let i = 0; i < value.length; i++) header.setUint8(offset + i, value.charCodeAt(i));
  };
  text(0, 'RIFF');
  header.setUint32(4, 36 + pcm.byteLength, true);
  text(8, 'WAVE');
  text(12, 'fmt ');
  header.setUint32(16, 16, true);
  header.setUint16(20, 1, true);
  header.setUint16(22, 1, true);
  header.setUint32(24, rate, true);
  header.setUint32(28, rate * 2, true);
  header.setUint16(32, 2, true);
  header.setUint16(34, 16, true);
  text(36, 'data');
  header.setUint32(40, pcm.byteLength, true);
  const file = new Audio();
  file.preload = 'auto';
  const loaded = new Promise((resolve) => {
    file.addEventListener('canplaythrough', () => resolve('loaded'), { once: true });
    file.addEventListener('error', () => resolve('error ' + (file.error ? file.error.code : '?')), { once: true });
    setTimeout(() => resolve('not loaded in 10 s'), 10000);
  });
  file.src = URL.createObjectURL(new Blob([header, pcm], { type: 'audio/wav' }));
  report.mediaElementLoad = await loaded;
  report.mediaElement = await play(file);

  // 3. A media element playing a live stream made in this page. The voices of
  // a call reach their elements as streams too; this path needs no connection.
  const liveOutput = context.createMediaStreamDestination();
  tone(base + 800, liveOutput);
  const live = new Audio();
  live.srcObject = liveOutput.stream;
  report.mediaStream = await play(live);

  // 4. A media element playing a track that arrived over WebRTC, the way the
  // voices of a call do. Two peer connections in this page, joined directly.
  let rtc = null;
  try {
    const outgoing = context.createMediaStreamDestination();
    tone(base + 1200, outgoing);
    const sender = new RTCPeerConnection();
    const receiver = new RTCPeerConnection();
    // What kind of candidates WebKit offered, without the addresses themselves.
    const candidates = [];
    const describe = (candidate) => [
      candidate.type || '?',
      candidate.protocol || '?',
      /\\.local$/.test(candidate.address || '') ? 'mdns name' : (candidate.address ? 'address' : 'no address'),
    ].join(' ');
    sender.onicecandidate = (event) => {
      if (!event.candidate) return;
      candidates.push(describe(event.candidate));
      receiver.addIceCandidate(event.candidate);
    };
    receiver.onicecandidate = (event) => { if (event.candidate) sender.addIceCandidate(event.candidate); };
    const remote = new Audio();
    receiver.ontrack = (event) => {
      remote.srcObject = event.streams[0] || new MediaStream([event.track]);
      remote.play().catch((error) => { report.webRTCElementError = error.name; });
    };
    for (const track of outgoing.stream.getTracks()) sender.addTrack(track, outgoing.stream);
    const offer = await sender.createOffer();
    await sender.setLocalDescription(offer);
    await receiver.setRemoteDescription(offer);
    const answer = await receiver.createAnswer();
    await receiver.setLocalDescription(answer);
    await sender.setRemoteDescription(answer);
    rtc = { sender, receiver, remote, candidates };
  } catch (error) {
    report.webRTC = 'failed: ' + error.name + ' ' + error.message;
  }

  // Where each path has got to: a path that is not advancing is not playing,
  // whatever its element says.
  window.probeState = async () => {
    const state = {
      contextTime: context.currentTime,
      fileTime: file.currentTime,
      filePaused: file.paused,
      liveTime: live.currentTime,
      livePaused: live.paused,
    };
    if (rtc) {
      state.remoteTime = rtc.remote.currentTime;
      state.remotePaused = rtc.remote.paused;
      state.connection = rtc.receiver.connectionState;
      state.ice = rtc.receiver.iceConnectionState;
      state.candidates = rtc.candidates;
      const stats = await rtc.receiver.getStats();
      stats.forEach((entry) => {
        if (entry.type !== 'inbound-rtp') return;
        state.packetsReceived = entry.packetsReceived;
        if (entry.audioLevel !== undefined) state.audioLevel = entry.audioLevel;
      });
    }
    return state;
  };
  return report;
};
</script>
</body>
"""

/// What a capture's content filter says about applications.
private enum FilterKind: String {
    /// The whole display, nothing left out.
    case everything = "the whole display"
    /// The whole display without this application.
    case excludingOwn = "this application excluded"
    /// Only the applications named, and this one is not named.
    case includingOthers = "only the other applications included"
    /// The whole display without the second copy. The second copy is started
    /// through LaunchServices however the probe itself was started, so this
    /// says what excluding an application does to a web view's sound when
    /// WebKit's helpers answer to that application.
    case excludingOther = "the second copy excluded"
    /// Only the applications named; neither copy is named.
    case includingNeither = "only applications other than the two copies included"
}

/// One way of leaving the application out of a capture.
private struct Variant {
    let name: String
    /// `SCStreamConfiguration.excludesCurrentProcessAudio`.
    let excludesCurrentProcessAudio: Bool
    let filter: FilterKind
}

/// The first and the last recording exclude nothing: the first shows the tones
/// can be heard at all, the last that they were still playing at the end.
private let variants = [
    Variant(name: "nothing excluded", excludesCurrentProcessAudio: false, filter: .everything),
    Variant(name: "excludesCurrentProcessAudio", excludesCurrentProcessAudio: true, filter: .everything),
    Variant(name: "application excluded by the content filter", excludesCurrentProcessAudio: false, filter: .excludingOwn),
    Variant(name: "both of the above", excludesCurrentProcessAudio: true, filter: .excludingOwn),
    Variant(name: "only the other applications included", excludesCurrentProcessAudio: false, filter: .includingOthers),
    Variant(name: "the second copy excluded by the content filter", excludesCurrentProcessAudio: false, filter: .excludingOther),
    Variant(name: "neither copy included", excludesCurrentProcessAudio: false, filter: .includingNeither),
    Variant(name: "nothing excluded, again", excludesCurrentProcessAudio: false, filter: .everything),
]

/// Collects the first channel of what a stream delivers.
private final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate = 48_000.0
    private var problem: String?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard isFloat, description.mBitsPerChannel == 32 else {
            lock.lock()
            problem = "unexpected sample format: flags \(description.mFormatFlags), \(description.mBitsPerChannel) bits"
            lock.unlock()
            return
        }
        let interleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let step = interleaved ? max(Int(description.mChannelsPerFrame), 1) : 1
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                guard let first = list.first, let data = first.mData else { return }
                let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                let values = data.assumingMemoryBound(to: Float.self)
                lock.lock()
                sampleRate = description.mSampleRate
                samples.reserveCapacity(samples.count + count / step)
                var index = 0
                while index < count {
                    samples.append(values[index])
                    index += step
                }
                lock.unlock()
            }
        } catch {
            lock.lock()
            problem = "could not read a sample buffer: \(error.localizedDescription)"
            lock.unlock()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        problem = "the stream stopped: \(error.localizedDescription)"
        lock.unlock()
    }

    func result() -> (samples: [Float], sampleRate: Double, problem: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, sampleRate, problem)
    }
}

@MainActor
private final class ProbeDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private let options: Options
    private var window: NSWindow!
    private var webView: WKWebView!
    private var report: [String: Any] = [:]
    private var finished = false
    private var companionBundleIdentifier: String?
    private let outputQueue = DispatchQueue(label: "capture-probe.output")

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        // Private WebKit preference, for measuring only; the application must
        // never call it. Without capture permission WebKit hides host addresses
        // behind mDNS names, and two peer connections in one page then never
        // connect. In a call the client holds the microphone permission and
        // WebKit does not filter. Passing nil as the BOOL argument is NO.
        let selector = NSSelectorFromString("_setICECandidateFilteringEnabled:")
        if configuration.preferences.responds(to: selector) {
            configuration.preferences.perform(selector, with: nil)
        }

        let frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        // The window is never put on the screen: the page only has to play.
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView

        let limit = options.playOnly == nil ? 150.0 : options.toneSeconds
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
            guard let self else { return }
            if self.options.playOnly == nil {
                self.finish(problem: "timed out after \(Int(limit)) s")
            } else {
                exit(0)
            }
        }
        webView.loadHTMLString(pageSource, baseURL: URL(string: "http://localhost/"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let base = options.playOnly {
            webView.callAsyncJavaScript(
                "return await window.startTones(gain, base)",
                arguments: ["gain": options.gain, "base": base],
                in: nil,
                in: .page,
                completionHandler: nil
            )
            return
        }
        Task { await self.run() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(problem: "the page did not load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(problem: "the page did not load: \(error.localizedDescription)")
    }

    private func run() async {
        report["system"] = ProcessInfo.processInfo.operatingSystemVersionString
        report["processID"] = Int(getpid())
        report["bundleIdentifier"] = Bundle.main.bundleIdentifier ?? NSNull()
        report["activationPolicy"] = options.regular ? "regular" : "accessory"
        report["gain"] = options.gain
        report["frequencies"] = Dictionary(uniqueKeysWithValues: toneFrequencies.map { ($0.name, $0.frequency) })

        var permitted = CGPreflightScreenCaptureAccess()
        if !permitted, options.requestPermission {
            permitted = CGRequestScreenCaptureAccess()
        }
        report["screenRecordingPermission"] = permitted
        guard permitted else {
            finish(problem: "no Screen Recording permission; grant it in System Settings, or run once with --request-permission")
            return
        }

        do {
            let tones = try await webView.callAsyncJavaScript(
                "return await window.startTones(gain, base)",
                arguments: ["gain": options.gain, "base": ownBaseFrequency],
                contentWorld: .page
            )
            report["page"] = tones ?? NSNull()
            // Give the file and the connection time to start: until both
            // advance, and no longer than fifteen seconds. On a machine
            // whose network does not let the two connections reach each
            // other the WebRTC tone never plays; the wait ends when the
            // connection gives up, and the recordings say the tone is absent.
            let deadline = Date().addingTimeInterval(15)
            var state = await pageState()
            while Date() < deadline, !Self.allPathsAdvance(state) {
                try await Task.sleep(nanoseconds: 250_000_000)
                state = await pageState()
            }
            report["pageStateBeforeCaptures"] = state
        } catch {
            finish(problem: "the page could not start its tones: \(error.localizedDescription)")
            return
        }

        if let path = options.companionPath {
            do {
                try await startCompanion(at: path)
            } catch {
                finish(problem: "the second copy did not start: \(error.localizedDescription)")
                return
            }
        }
        report["otherApplicationRunning"] = companionBundleIdentifier != nil

        // Read after the second copy has started: the last variant names the
        // applications to include, and it has to be among them.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            finish(problem: "the system gave no shareable content: \(error.localizedDescription)")
            return
        }
        guard let display = content.displays.first else {
            finish(problem: "no display to capture")
            return
        }
        let ownApplication = content.applications.first { $0.processID == getpid() }
        let otherApplications = content.applications.filter { $0.processID != getpid() }
        report["ownApplicationListed"] = ownApplication != nil
        let otherApplication = companionBundleIdentifier.flatMap { identifier in
            otherApplications.first { $0.bundleIdentifier == identifier }
        }
        report["otherApplicationListed"] = otherApplication != nil
        // Does the system list WebKit's helper processes as applications of
        // their own? If it did, they could be excluded one by one.
        report["webKitApplicationsListed"] = content.applications
            .filter { $0.bundleIdentifier.lowercased().contains("webkit") }
            .map { ["bundleIdentifier": $0.bundleIdentifier, "processID": Int($0.processID), "name": $0.applicationName] }

        var captures: [[String: Any]] = []
        for variant in variants {
            var entry: [String: Any] = [
                "name": variant.name,
                "excludesCurrentProcessAudio": variant.excludesCurrentProcessAudio,
                "filter": variant.filter.rawValue,
            ]
            let filter: SCContentFilter
            switch variant.filter {
            case .everything:
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            case .excludingOwn:
                guard let ownApplication else {
                    entry["skipped"] = "the system does not list this process as an application"
                    captures.append(entry)
                    continue
                }
                filter = SCContentFilter(display: display, excludingApplications: [ownApplication], exceptingWindows: [])
            case .includingOthers:
                filter = SCContentFilter(display: display, including: otherApplications, exceptingWindows: [])
            case .excludingOther, .includingNeither:
                guard let otherApplication else {
                    entry["skipped"] = "the second copy is not running or not listed"
                    captures.append(entry)
                    continue
                }
                if variant.filter == .excludingOther {
                    filter = SCContentFilter(display: display, excludingApplications: [otherApplication], exceptingWindows: [])
                } else {
                    let neither = otherApplications.filter { $0.processID != otherApplication.processID }
                    filter = SCContentFilter(display: display, including: neither, exceptingWindows: [])
                }
            }
            do {
                let recording = try await record(filter: filter, excludesCurrentProcessAudio: variant.excludesCurrentProcessAudio)
                for (key, value) in recording { entry[key] = value }
            } catch {
                entry["error"] = error.localizedDescription
            }
            entry["pageStateAfter"] = await pageState()
            captures.append(entry)
        }
        report["captures"] = captures
        finish(problem: nil)
    }

    /// Starts the second copy through LaunchServices, so that it is an
    /// application of its own and not a child of this one.
    private func startCompanion(at path: String) async throws {
        let url = URL(fileURLWithPath: path)
        guard let identifier = Bundle(url: url)?.bundleIdentifier else {
            throw NSError(domain: "CaptureProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(path) is not a bundle"])
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [
            "--play-only", String(otherBaseFrequency),
            "--gain", String(options.gain),
            "--tone-seconds", "120",
        ]
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        companionBundleIdentifier = identifier
        // Its page loads, its file is read and its tones start. With less than
        // this the first recording caught one of them still starting.
        try await Task.sleep(nanoseconds: 12_000_000_000)
    }

    private func stopCompanion() {
        guard let identifier = companionBundleIdentifier else { return }
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) {
            application.terminate()
        }
    }

    private func pageState() async -> [String: Any] {
        let value = try? await webView.callAsyncJavaScript("return await window.probeState()", contentWorld: .page)
        return value as? [String: Any] ?? [:]
    }

    private static func allPathsAdvance(_ state: [String: Any]) -> Bool {
        func number(_ key: String) -> Double { (state[key] as? NSNumber)?.doubleValue ?? 0 }
        let connectionSettled = number("packetsReceived") > 20 || (state["ice"] as? String) == "failed"
        return number("fileTime") > 0.5 && number("liveTime") > 0.5 && connectionSettled
    }

    private func record(filter: SCContentFilter, excludesCurrentProcessAudio: Bool) async throws -> [String: Any] {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // The picture is not wanted: the smallest frame, once a second.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let recorder = Recorder()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: recorder)
        try stream.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: outputQueue)
        // Without an output for the picture the system logs every frame it drops.
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(options.seconds * 1_000_000_000))
        try await stream.stopCapture()

        let (samples, sampleRate, problem) = recorder.result()
        // The first half second is the stream starting up.
        let settled = Array(samples.dropFirst(Int(sampleRate / 2)))
        var tones: [String: Any] = [:]
        for tone in toneFrequencies {
            let amplitude = ToneAnalysis.amplitude(of: settled, sampleRate: sampleRate, frequency: tone.frequency)
            tones[tone.name] = [
                "decibels": (ToneAnalysis.decibels(amplitude) * 10).rounded() / 10,
                "presence": ToneAnalysis.presence(amplitude: amplitude, played: options.gain).rawValue,
            ]
        }
        var entry: [String: Any] = [
            "seconds": (Double(settled.count) / sampleRate * 100).rounded() / 100,
            "sampleRate": sampleRate,
            "levelDecibels": (ToneAnalysis.decibels(ToneAnalysis.rootMeanSquare(of: settled)) * 10).rounded() / 10,
            "tones": tones,
        ]
        if let problem { entry["problem"] = problem }
        return entry
    }

    private func finish(problem: String?) {
        guard !finished else { return }
        finished = true
        stopCompanion()
        if let problem { report["problem"] = problem }
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        if let path = options.outPath {
            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("capture-probe: could not write \(path): \(error.localizedDescription)\n".utf8))
            }
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(problem == nil ? 0 : 2)
    }
}

guard let options = Options.parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data("""
    usage: CaptureProbe [--request-permission] [--regular] [--gain 0.05] [--seconds 2.5]
                        [--out report.json] [--companion Other.app]
           CaptureProbe --play-only 2300 [--gain 0.05] [--tone-seconds 60]

    """.utf8))
    exit(64)
}

// The main thread is the main actor here; the closure never returns, so the
// delegate, which the application holds weakly, lives as long as the run.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(options.regular ? .regular : .accessory)
    let delegate = ProbeDelegate(options: options)
    application.delegate = delegate
    application.run()
}
