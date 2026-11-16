# desktop-macos

The native macOS client of B:SPACE: a Swift shell around the system `WKWebView`
that loads the same web client the server serves. Plan and stages:
[docs/superpowers/plans/2026-11-16-macos-native-client.md](../../docs/superpowers/plans/2026-11-16-macos-native-client.md).

The package holds the application (stage 1 of the plan is under way: the
window, the server picker, the navigation policy and the core of the bridge)
and the measuring harness of stage 0.

| Target | What it is |
|--------|------------|
| `BSpaceCore` | Logic with no AppKit or WebKit in it: navigation policy, the saved instance address, the bridge contract, the page-side bridge script, the router. Covered by `swift test` |
| `BSpaceShell` | The window, the `WKWebView` and the native half of the bridge |
| `BSpaceApp` | The application: starts `BSpaceShell`. `scripts/bundle.sh` wraps it into `B-SPACE.app` |
| `ContractCheck` | Drives `BSpaceShell` through the bridge contract check, or opens a live instance in it |
| `WebKitProbe`, `ProbeSupport` | The measuring harness of stage 0 |

## Requirements

macOS 14 or newer and a Swift 6 toolchain. Command Line Tools are enough:
`swift build` and `swift test` work without Xcode. This is a SwiftPM package,
not a pnpm workspace package, so `pnpm install` and the TypeScript checks do
not touch it.

```bash
swift build -c release
swift test
```

## The application

```bash
scripts/bundle.sh --run
```

builds `.build/app/dev/B-SPACE.app` and starts it. A development build has its
own bundle identifier (`com.backspace.desktop.dev`) and its own settings
folder (`~/Library/Application Support/Backspace-Dev`), and does not claim the
`backspace://` scheme: it runs beside the installed app without touching that
app's sign-in, settings or web storage. `--identity release` gives the bundle
the identity of the shipped app, the one that replaces the Electron build.
`BACKSPACE_URL=https://…` opens that instance instead of the saved one, as in
the Electron build.

The bundle takes three files from `packages/desktop`, which owns them for both
shells: `resources/instance-picker.html`, `src/bridgeContract.json` and
`build/icon.icns`. The version comes from the root `package.json`. The
signature is ad hoc unless `--sign <identity>` names a certificate.

### The bridge

`window.backspace` is built from `packages/desktop/src/bridgeContract.json`,
the description Electron's preload is held to as well (see "Bridge contract"
in [desktop.md](../../docs/systems/desktop.md)). `BridgeScript` turns it into
the script injected at document start in the main frame; `BridgeRouter` routes
what the page posts to handlers by channel name; `BridgeHost` connects the two
to WebKit and sends the shell's events back.

Every call channel of the contract has to be answered before the first page
loads, or the app stops at launch. Channels whose feature is not ported yet
are listed in `InterimReplies` with the answer Electron gives where that
feature is absent, grouped by the stage that replaces them. Porting a channel
means registering its handler and deleting it from that table in the same
change; `InterimRepliesTests` fails when the two stop adding up to the whole
contract.

### Contract check

```bash
scripts/contract-check.sh [--out report.json]
```

runs the real shell with no window on screen and its settings in a temporary
folder, loads `contract/harness.html`, and lets that page use the bridge the
way a client does: it reads every member, calls each one, subscribes to every
event, and the driver then sends one event on each channel. The run fails
(exit status 1) when a `fire` member returns anything but `undefined`, an
`invoke` member does not return a Promise or its Promise rejects, a
subscription returns the wrong thing or misses its event, a removed callback
is still called, the bridge has a member the contract lacks, or the
User-Agent is not `… Version/<Safari> Safari/605.1.15 BSpaceDesktop/<version>`.
The report records the shape of every answer.

Five members are read but not called, because they navigate the window away
from the harness or act on a window that is not on screen: `minimize`,
`maximize`, `close`, `setInstanceUrl`, `clearInstanceUrl`.

The same executable opens a live instance in the shell and prints what the
page sees (where it ended up, its title, the bridge, whether the client drew
anything):

```bash
.build/release/ContractCheck --contract ../desktop/src/bridgeContract.json \
  --picker ../desktop/resources/instance-picker.html \
  --visit https://your.instance.example --settle 6
```

## WebKitProbe

Opens one page in a `WKWebView`, runs a script in it and writes a JSON report:
what the script returned, what the page logged as errors and warnings, how
navigation went, what the page downloaded and which capture permissions it
asked for (every request is denied and recorded, so no system prompt appears).

It answers "how does the system WebKit behave here" with a measurement instead
of a recollection. The results of the first run are in
[the pre-audit](../../docs/superpowers/specs/2026-11-16-macos-swift-port-pre-audit.md).

`scripts/probe.sh` builds it, wraps it in an application bundle and runs it.
The bundle matters: WebKit takes the capture usage descriptions and the App
Transport Security policy from the running application's `Info.plist`.

```bash
# The probe pages need an http origin. From the repository root:
python3 -m http.server 8787 --directory packages/desktop-macos/probe/pages

# From packages/desktop-macos:
scripts/probe.sh -- --url http://localhost:8787/zoom.html --call "window.runProbe()" --activate
scripts/probe.sh -- --url http://localhost:8787/video.html --call "window.runProbe()" --activate
scripts/probe.sh --ats web-content -- --url http://example.com/
scripts/probe.sh --help
```

Options of the probe itself (after `--`):

| Option | Meaning |
|--------|---------|
| `--url <url>` | The page to open. Required |
| `--call <expression>` | A JavaScript expression awaited in the page, usually `window.runProbe()` |
| `--script <file>` | A file whose text is the body of an async function run in the page; wins over `--call` |
| `--out <file>` | Where the report goes. Standard output when absent |
| `--size <W>x<H>` | Content size, 1280x800 by default |
| `--titlebar standard\|hiddenInset` | `hiddenInset`: transparent title bar over a full-size content view |
| `--activate` | Bring the window to the front and make it key. Needed when the probe clicks and types |
| `--ua-app-name <text>` | `applicationNameForUserAgent` |
| `--default <key>=<value>` | A user default set before the view exists; `true` and `false` become booleans |
| `--ephemeral` | A non-persistent data store, so runs do not see each other's storage |
| `--settle-ms <n>`, `--timeout <s>` | Wait after load before the script (500); whole-run limit (60) |
| `--snapshot <png>` | The view's own snapshot. It leaves backdrop blur out |
| `--window-capture <png>` | The window as the window server shows it. It shows blur but not `<video>` layers |
| `--download-dir <dir>` | Where downloads are saved |
| `--unfiltered-ice` | Turns WebKit's ICE candidate filtering off through a private preference. A measuring aid; the application never does this |

`--default` writes into the probe's own defaults domain and the values stay
there. Clear them between runs that should start clean:

```bash
defaults delete com.backspace.desktop.probe
```

### What a page can ask the shell

Inside the page, `await window.probeNative(op, args)`:

| `op` | `args` | Does |
|------|--------|------|
| `click` | `x`, `y`, optional `button: 'right'` | A real mouse click, in points from the top left corner of the view |
| `type` | `text` | Real key events, one per character |
| `pixelStats` | `x`, `y`, `width`, `height`, `source: 'snapshot'\|'window'` | Mean and spread of luminance in that rectangle |
| `snapshot` | `path` | Saves the view's snapshot |
| `textChecking` | — | State of the editing toggles (quote, dash and text substitution, spelling, grammar) |
| `windowInfo` | — | Window frame, content rectangle, scale factor, positions of the window buttons |
| `resize` | `width`, `height` | Sets the content size |
| `pageZoom` | `value` | Sets `WKWebView.pageZoom` |
| `hide`, `show` | — | Orders the window out and back |

### Probe pages

`probe/pages/` holds one page per question. Each defines `window.runProbe()`,
so the same page runs in the shell and, where it does not need the shell, in
any browser for comparison.

| Page | Question | Needs the shell |
|------|----------|-----------------|
| `zoom.html` | Which coordinates are visual under CSS `zoom`, at every interface scale | for the click part |
| `features.html` | CSS features, media formats and platform APIs the web client uses | for the bridge timing |
| `glass.html` | Whether each glass construction of the design system blurs its backdrop | yes |
| `video.html` | Whether a `MediaStream` picture is in the snapshot and in the window capture | yes |
| `input.html` | What the view does to typed text; how long a click counts as a user gesture | yes, with `--activate` |
| `downloads.html` | Which download triggers reach the download delegate | yes |
| `service-worker.html` | Registration, control, fetch through the worker, Cache Storage | no |
| `webrtc.html` | Offered codecs, sender stats fields, loopback between two connections | no |

To look at a page of the web client itself, start Vite (`pnpm dev:web`) and
point `--url` at `http://localhost:5173/dev-voice-grid.html` or any other
workbench page.
