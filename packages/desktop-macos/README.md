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
`build/icon.icns`. The version comes from the root `package.json`.

### Signing

`bundle.sh` signs through `scripts/sign.sh`, a port of
`packages/desktop/scripts/macSign.js` that reads the same variables. With
`MAC_SIGN_P12` (base64 of a `.p12`) and `MAC_SIGN_P12_PASSWORD` set, the
bundle is signed with that certificate through a throwaway keychain, and the
script fails unless the designated requirement then names the certificate's
hash; that requirement is what keeps macOS permissions across updates (see
"Stable signing identity" in
[desktop-security.md](../../docs/systems/desktop-security.md)). Without them
the signature is ad hoc, which is right for a development build.
`MAC_SIGN_REQUIRED=1` refuses the ad hoc fallback.

`scripts/sign-selftest.sh` checks the certificate path without the project's
certificate: it makes a throwaway one, builds the bundle signed with it,
confirms the requirement and that the keychain search list is as it was, and
signs the bundle ad hoc again.

### CI

`.github/workflows/desktop-macos.yml` runs `swift build`, `swift test`, the
contract check and the signing self-test on a macOS runner. It starts only
when something the package builds from changes (the package, the three files
taken from `packages/desktop`, the root `package.json`, the workflow), because
macOS minutes are the expensive kind.

### Settings files

The app keeps its settings where the Electron build does, in the same files
and formats, so either shell reads what the other wrote
(`~/Library/Application Support/Backspace`; a development build uses
`Backspace-Dev`). Every file is written atomically.

| File | What | Code |
|------|------|------|
| `instance-url.json` | The chosen instance | `InstanceURLStore` |
| `window-state.json` | Size, position and whether the window was zoomed | `WindowStateStore`, `WindowPlacement` |
| `language.json` | The language the web client last reported, for the shell's own strings | `LanguageStore` |
| `auto-launch.json` | Whether the app starts hidden when opened at login (`startMinimized`); its `openAtLogin` is written and never read back | `AutoLaunchStore` |
| `local-storage-import.json` | The origins whose `localStorage` was brought over from the Electron build (native app only) | `LocalStorageImportLedger` |

`window-state.json` holds Electron's coordinates: points from the top left
corner of the primary display, Y growing downwards. AppKit counts from the
bottom left, upwards; `WindowPlacement.flipped` converts both ways. A saved
place that is no longer on any display (the monitor is gone) is dropped and
the window is centred at its saved size. The place is written 0.3 s after the
window stops moving, when it is closed and when the app quits; while the
window is zoomed the un-zoomed frame is what is written, and a full-screen
window is not written at all.

### What comes over from the Electron build

The web client keeps the sign-in, the connected instances and its settings in
`localStorage`. In the Electron build that is a LevelDB database inside the
same folder (`Local Storage/leveldb`: the folder is also Electron's Chromium
profile); in the native app it is WebKit's own storage. So that moving from one
build to the other does not sign anyone out, the native app brings the items
over:

- **When.** Before the shell loads an instance, for that instance's origin
  (and, for an `http://` address on the default port, the `https://` origin of
  the same host, where a redirect would have put the storage). Once per origin:
  `local-storage-import.json` lists the origins already offered their items.
- **What.** Every item of the origin, as it is. Only the origin's own storage:
  storage partitioned under an embedding site is left out. IndexedDB is not
  brought over; the web client keeps only file handles of resumable uploads
  there, and those are Chromium objects.
- **Never over existing data.** If WebKit already holds items for the origin,
  nothing is written: what the native app stored is newer.
- **How.** `LevelDB` reads the database without the LevelDB library (manifest,
  tables with Snappy blocks, write-ahead log; the newest entry for a key
  wins). `ChromiumLocalStorage` turns the entries into items by origin.
  `LocalStorageImporter` writes them through a second web view that never
  shows and loads nothing from the network: an empty document given the
  origin, in the main web view's data store. The items are arguments of a
  function call, never page source.
- **The Electron profile is only read**, so going back to the Electron build
  finds it as it was.
- **When it fails** (a damaged database, a refusal by the page) the instance
  loads without it and the user signs in again. A failure to read is tried
  again at the next launch; a refusal is not.

`ContractCheck --check electron-profile --profile <folder>` lists what the
import finds in a profile: origins, item counts and sizes, and with
`--keys yes` the item names. It never prints a value.

The tests read a database written by the real LevelDB library
(`Tests/BSpaceCoreTests/Fixtures/chromium-local-storage`), made by
`scripts/make-leveldb-fixture.mjs`; everything in it is made up.

### Starting the app

Logic in `BSpaceCore/AppLaunch.swift`, the system calls in
`BSpaceShell/AppLaunchSupport.swift`, the order of things in `AppDelegate`.

- **One copy.** macOS keeps to one copy of an app opened from the Finder or
  the Dock. A copy started past that (the executable run directly, `open -n`)
  looks for others with its bundle identifier; the one that started first
  stays (`SingleInstance.survivor`, by the kernel's start time, then by process
  identifier, so two copies launched together agree). The copy that gives way
  sends the other a distributed notification named
  `<bundle identifier>.second-instance`, carrying the `backspace://` link it
  was launched with if there was one, activates it and exits before creating
  a window. The copy that stays shows its window. An executable with no bundle
  (a test run) skips all of this.
- **`backspace://` links.** They come from the system
  (`application(_:open:)`), from the command line, or from a second copy.
  Anything that does not start with `backspace://` is dropped before it
  reaches the page. A link is sent on the `deep-link` channel and the window
  comes forward. If the page is not listening yet (the link launched the app,
  or the page is reloading) the link waits in `DeepLinkInbox`, the newest
  replacing an older one, and is sent when the page subscribes: the bridge
  script posts a `subscribe` message each time the page starts listening on an
  event channel (`BridgeRouter.onSubscribe`). A bundle whose Info.plist
  declares the scheme makes itself its handler at every launch, as Electron
  does; a development bundle does not declare it.
- **Opening at login.** `SystemLoginItem` is the app's own login item
  (`SMAppService.mainApp`). It belongs to the bundle identifier, so the item
  the Electron build registered is the same one. `getAutoLaunchSettings`
  answers with what the system says for `openAtLogin` and what
  `auto-launch.json` says for `startMinimized`. `setAutoLaunchSettings`
  changes the fields it is given, asks the system only when `openAtLogin`
  really changes, and answers with the state after the change as the system
  reports it: if the system refuses, the client's switch goes back.
- **A hidden start.** The window stays hidden until something asks for it
  (the Dock icon, a link, a second launch) when the app is run with
  `--hidden`, or when the system opened it at login (the launch event says so)
  and `startMinimized` is on. The page loads and connects all the same. A
  launch by a link is never hidden.

### Language and the menu bar

- **Strings.** What the shell says on its own comes from
  `packages/desktop/src/desktopStrings.json`, the one catalog of both desktop
  shells (the Electron build's `l10n.ts` reads the same file); `bundle.sh`
  copies it into the bundle and `DesktopStrings` reads it. The languages are
  the keys of that file: adding one there is all the shell needs. A catalog in
  which a language lacks a key the shell uses is refused at launch.
- **Which language.** The web client owns the choice and reports it on
  `set-language`; the shell remembers it in `language.json` and starts in it
  next time. Before the web client has said anything, the system's first
  language decides, then English (`DesktopStrings.resolve`). A language the
  catalog lacks is ignored.
- **The menu bar** (`AppMenu`) is the one `buildAppMenuTemplate` gives the
  Electron build: the application menu (About, Source code, Change Instance,
  Hide, Hide Others, Show All, Quit), Edit and Window. It is rebuilt when the
  language changes. "Source code" asks the instance for the address of its
  own source (`GET /api/instance/info`, `sourceCodeUrl`) and opens that, or
  the project's repository. "Change Instance" opens the picker and keeps the
  saved instance until another is chosen. Two differences from Electron: no "Toggle Developer
  Tools" (a `WKWebView`'s inspector cannot be opened from code; attach from
  Safari's Develop menu), and Window has Close (Command-W).
- **Permission prompts.** The texts the system shows when the app first asks
  for the microphone, the camera or the system's sound are in the same
  catalog (`mac.permission.<Info.plist key>`). `scripts/permission-texts.swift`
  writes them into the bundle, one `<language>.lproj/InfoPlist.strings` per
  language; the system picks by its own language, not the web client's.

### Recovery mode

When the web client cannot be shown, the window shows `recovery.html` (the
page of the Electron build, from `packages/desktop/resources`), which says
what happened and offers to reload, to change the instance or to quit. The
decisions are in `BSpaceCore/Recovery.swift`, a port of
`packages/desktop/src/recovery.ts`; the window's side is in
`MainWindowController`.

| Reason | When |
|--------|------|
| `load-failed` | A load the shell asked for failed, or a page broke off half shown. A navigation that became a download or was cancelled is not a failure (`WebKitErrorDomain` 102). |
| `renderer-stalled` | A page of an instance finished loading and the web client did not call `rendererReady()` within 20 s (`BootWatch`). |
| `unresponsive` | The page did not answer the shell for 25 s (`HangWatch`). |
| `render-gone` | The web content process ended twice within a minute (`CrashLoopGuard`). |

- **A page that hangs.** A `WKWebView` does not say when its page hangs, so
  the shell asks the page a trivial question every 5 s, while the window is on
  screen, and takes a question unanswered for 25 s as a hang. A tick that
  comes much later than it should (the machine slept) starts the count again.
  A stuck page cannot be navigated away from: every load is first put to the
  process of the page on screen. So for this reason the shell puts a new web
  view in the window (`replaceWebView`), and WebKit ends the stuck process.
- **A process that ends.** WebKit ends the web content process for its own
  reasons too (the system is short of memory), so the first time the page is
  loaded again; only a second ending within a minute goes to recovery.
- **A navigation of the page's own that fails before anything of it is
  shown** leaves the page it came from on screen and working, and is not
  recovered from. Chromium replaces the page with an error page there, so
  the Electron build recovers.
- **No loop.** Going into recovery while already there changes what the page
  says and loads nothing: if `recovery.html` itself cannot load, the window
  stays as it is.
- **Always visible.** Recovery brings the window forward even after a hidden
  start.
- **Actions** (`recovery-action`): `reload` leaves recovery and loads the
  saved instance, or the picker when there is none; `change-instance` leaves
  recovery and opens the picker; `quit` quits; `open-releases` opens the
  latest release in the browser. The updater is stage 5: until then
  `check-update` opens the latest release too, and `install-update` does
  nothing.

### Notifications and the badge

- **`showNotification(title, body, options)`** becomes a system notification
  (`SystemNotificationPresenter`, `UNUserNotificationCenter`), with the default
  sound, shown even while the app is in front: the web client decides when a
  notification is due. A call with no title shows nothing.
- **Permission** (alerts, sounds and the icon's badge) is asked when the
  window is first shown, if the user has never been asked. The system's
  question is a banner that goes away after a while and then counts as a
  refusal, so it must not wait for the first notification, which comes when
  nobody is looking. Permission is kept per bundle identifier: the one given
  to the Electron build stands and nothing is asked.
- **A click** brings the window forward and sends `options` back on
  `notification-click`, but only if the page is still of the origin that asked
  for the notification (`NotificationRequest.clickPayload`): identifiers from
  one instance must not open things on another. The origin and the payload
  travel with the notification through the system, so nothing is held in the
  app for a click to work, and a click still arrives after a restart. A click
  that comes before the page listens only brings the window forward.
- **`setBadgeCount(n)`** sets the Dock icon's badge to the whole number when
  it is one or more and clears it otherwise (`BadgeCount`). The system shows
  the badge only while the app is allowed to badge its icon.
- An executable that is not an application bundle has no notification centre
  and shows none.

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
folder. It first checks the window state on this machine's displays
(`ContractCheck --check window-state`: the window appears where the file says,
the file follows a move, a lost place is centred) and the import of the
Electron build's `localStorage` (`--check local-storage-import`: the fixture's
items reach a page of their origin as they are, an origin is imported once,
storage in use is kept, the shell imports before it loads an instance; the
data store is never written to disk, and the one address asked of the network
is a `.test` name that does not exist), and what reaches the page from outside
(`--check launch`: a link is held until the page listens and delivered once,
a later one goes straight through, what is not a link is dropped, and the
auto-launch settings go through the bridge to a login item that registers
nothing), and notifications and the badge (`--check notifications`, on a page
the driver serves from the loopback address so that it has a real origin: what
the page asks for reaches a presenter that only records, a click hands the
payload back, a click on a notification from another origin does not, the
badge is set and cleared), and the menu bar (`--check menu`: built in every
language of the catalog with no item left untitled, the shortcuts in place,
and the shell's language following `set-language`), and recovery mode
(`--check recovery`, with its clocks shortened: an address that cannot be
loaded, a page that never reports that it started and a page whose thread is
stuck each end on the recovery page with the right reason; a second failure
changes what that page says without loading it again; a page that reports is
left alone; Reload, Change Instance, Quit and the releases page work). Then it loads
`contract/harness.html`, and lets that page use the bridge the
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
anything); `--script <file>` asks the page something else, the file being the
body of an async function whose return value is printed:

```bash
.build/release/ContractCheck --contract ../desktop/src/bridgeContract.json \
  --picker ../desktop/resources/instance-picker.html \
  --strings ../desktop/src/desktopStrings.json \
  --recovery ../desktop/resources/recovery.html \
  --visit https://your.instance.example --settle 6
```

A visit is a cold start of the web client: about 160 requests, because the
service worker fetches every asset a second time for its cache. The server
allows 200 requests a minute per address, and that budget is shared with
everyone behind the same address, the person using the instance from this
machine included. Point it at a test instance, not at one in use.

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
