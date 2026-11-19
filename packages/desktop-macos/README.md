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
| `BSpaceApp` | The application: starts `BSpaceShell`. `scripts/bundle.sh` wraps it into `B-SPACE.app`, or `B-SPACE Dev.app` for a development build |
| `ContractCheck` | Drives `BSpaceShell` through the bridge contract check, or opens a live instance in it |
| `WebKitProbe`, `ProbeSupport` | The measuring harness of stage 0 |
| `CaptureProbe` | The stage 4 experiment: does a system audio capture that excludes an application leave out what its web view plays |
| `StreamProbe` | The stage 4 experiment of plan section 12: publish a screen share into a LiveKit room from the shell's own capture, and print what WebRTC says about it |

## Requirements

To build and to run the tests: macOS 15 or newer and a Swift 6 toolchain.
The app itself is released for macOS 26 and newer (decided on 2026-11-18;
measured on 27.2 only): the bundle's `LSMinimumSystemVersion` says 26.0,
and the system refuses to start it on anything older. The package is built
for 15 because that is the newest `Package.swift` can name with the
toolchain and SDK it is built by. Command Line Tools are enough:
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

builds `.build/app/dev/B-SPACE Dev.app` and starts it (a release identity builds `.build/app/release/B-SPACE.app`). A development build has its
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
the signature is ad hoc. `MAC_SIGN_REQUIRED=1` refuses the ad hoc fallback.

An ad hoc build is a new application to macOS every time it is rebuilt: the
system tells it by the hash of its code, so the microphone, Screen Recording
and Input Monitoring grants of the build before are refused to it while the
privacy lists still show them switched on, and each has to be removed and
given again. To work on the client without that,

```bash
scripts/dev-identity.sh
```

makes a self-signed code-signing certificate of this machine's own, once, in
`~/Library/Application Support/Backspace-Dev-Signing` (readable by its owner
alone, outside the repository). `bundle.sh` signs a development build with it
whenever it is there and no certificate is named in the environment; a
release identity never takes it. The first build signed with it is one more
new application: clear the entries of the builds before with
`tccutil reset All com.backspace.desktop.dev`, give the grants once, and
they stay. `scripts/dev-identity.sh --remove` deletes the certificate.
Whoever can read that folder can sign code macOS takes for the development
build, with its grants; it has nothing to do with the project's certificate.

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

### What the page complains about

A development build (`scripts/bundle.sh --identity dev`) writes the page's
warnings and errors to `page.log` in its settings folder
(`Application Support/Backspace-Dev`): what the web client logged with
`console.warn` and `console.error`, errors nobody caught and promises nobody
handled, one line each with the time, and a line for every page load. The
file is started again when it passes a megabyte. The shipped app writes
none (`ShellEnvironment.pageLogURL` is nil for it).

It is there because a build that is being tried has no inspector open, and
the system's own log says nothing of what happens inside the page. In the
first call the client was tried in, a share that dropped the sharer from the
call left only this to read, and the file named the cause in one attempt.

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

### Dragging the window

The window has no title bar of its own: the page draws one, and Electron
learns which parts of it drag the window from the CSS property
`-webkit-app-region`. WebKit does not know the property and drops it from the
style sheet, so here the page says where its title bar is, and the shell tells
the system to drag the window by those parts.

- **What the page reports.** The web client measures the elements it marks
  `.titlebar-drag` and `.titlebar-no-drag` and calls
  `window.backspace.setDragRegions({ drag, noDrag })` with their rectangles,
  in points from the top left corner of the page
  (`packages/web/src/platform/windowDragRegions.ts`). It reports again when
  such an element appears, goes away or changes size, and when the window is
  resized. The member is marked `nativeOnly` in the contract: Electron's
  preload does not have it, and there the client reports nothing.
- **A page that reports nothing** is dragged by a strip along its top edge,
  32 points high (`WindowDragMap.fallbackStripHeight`). That covers the
  shell's own pages (the instance picker, recovery), whose title bar is that
  strip, and a server whose web client is older than `setDragRegions`. Every
  new page starts from the strip again.
- **A report is taken whole or not at all** (`DragRegions`): `drag` has to be
  a list, every rectangle four finite numbers with a size that is not
  negative, and at most 64 of a kind. A report that cannot be read leaves
  the last one standing. An empty `drag` is believed: such a page is not
  dragged anywhere.
- **Who starts the drag.** The system does, by itself, from the rectangles
  of the views that say they move the window (`mouseDownCanMoveWindow`, in a
  window that is `isMovableByWindowBackground`). It reads those answers when
  the window is laid out, not at each press, so the shell cannot decide
  press by press. `ShellWebView` says it moves the window, and
  `ShellContentView` lays transparent `StayView`s, which say they do not and
  let every press through, over everything that must stay a page:
  `WindowDragMap.stayRects` gives their rectangles, the view short of the
  dragged parts plus the exceptions. They are laid out again when the page
  reports, when another page is shown and when the window changes size; a
  window that grew stays a page beside what was last reported until the page
  has measured itself again.
- **Why not `performDrag(with:)`.** Asking for the drag at the press is what
  the first version did, and what Chromium does. On the machine this was
  written on, that call started the drag only now and then: on a bench of
  windows dragged by hand 2 of 18 presses moved the window that asked,
  against 12 of 12 for the one built as above; an ordinary window with a
  plain view failed the same way, and the Electron build dragged as badly.
  The machine turned out to be in a bad state then (a system gesture had
  stopped working too). After a reboot the Electron build drags reliably, so
  the call itself is sound and the cause was that state, not the system's
  version; the bench was not run again. The layout above was kept all the
  same: it is the system's own way of moving a window, it needs no answer
  from the app at the press, and it held where the call did not. Two things
  that look simpler do not work:
  answering `mouseDownCanMoveWindow` by where the mouse is (the answer is
  kept from the last layout), and views that move the window laid over a web
  view that does not (a view that does not takes its whole rectangle out).
- **Where a press goes.** A press on a dragged part still reaches the web
  view, after the system has begun moving the window. `ShellWebView` keeps
  it from the page, release included; anywhere else the page gets the whole
  click.
- **A double click** on a dragged part does what the system's setting says a
  double click on a title bar does (`TitleBarDoubleClick`, from
  `AppleActionOnDoubleClick` and the older `AppleMiniaturizeOnDoubleClick`):
  zoom, minimize or nothing. "Fill" has no public call and is done as zoom.
  A full-screen window ignores it.

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

### The tray

The B:SPACE character sits in the menu bar and shows what the app needs the
user to know; under it is a menu with quick controls. The web client decides
both: it reports the character's state over `set-tray-state` and what the
menu may offer over `set-tray-context`, and gets a chosen control back as a
`tray-action`. `BSpaceCore/Tray.swift` is a port of
`packages/desktop/src/trayState.ts` and `trayContext.ts`; `TrayCoordinator`
and `SystemTrayPresenter` in `BSpaceShell/Tray.swift` are the status item.

- **The character.** Nine states, each a loop of frames with their
  durations (`TrayAnimations`), the same as in the Electron build. The frame
  images are that build's template PNGs, `tray-<frame>Template.png` with
  their `@2x` files, which `bundle.sh` copies into the bundle (it stops if
  there are not 32) and the system tints for the menu bar's colour. Their
  size is set by hand, 18 by 22 points from the pixels of the plain file:
  the PNGs say 1200 dpi, AppKit believes them and would draw the character
  one point wide, where Electron goes by the pixels alone
  (`SystemTrayPresenter.loadFrames`).
  `TrayAnimator` owns no timer: each call answers with the frame to show and
  the delay to the next one. A state reported again keeps its place in the
  loop; a state that is not one is ignored.
- **Reduced motion.** When the system asks apps to keep still
  (`accessibilityDisplayShouldReduceMotion`), each state shows its first
  frame and no more. The setting is read at every step, so turning it on
  stops the loop at the next frame.
- **The menu** is this shell's own, not the Electron build's
  ([design](../../docs/superpowers/specs/2026-11-18-macos-tray-menu-design.md)).
  From the top: the name of the call; a row of round buttons for what is done
  in one press; Do Not Disturb with a check mark; Show B:SPACE; Quit. Changing
  the instance, the source code and (from stage 5) updates are in the app's
  menu, where macOS has them. Before sign-in it is Show and Quit alone.

  | Button | When it is there | Colour |
  |--------|------------------|--------|
  | Microphone | signed in | red when off |
  | Sound | signed in | red when off |
  | Viewers' pointers | in a call, when the web client reports the setting | the accent when shown |
  | Turn off camera | while the camera is on | red |
  | Stop sharing | while the screen is shared | red |
  | Disconnect | in a call | plain |

  The tray can turn the camera off and stop a share and cannot start either:
  that is done in the window, in plain sight. `TrayMenu.items` builds the
  model (`TrayControl`: kind, tone, title, command, whether it closes the
  menu); `SystemTrayPresenter` draws the row as the view of one menu item
  (`TrayControlsView`, `TrayRoundButton`, system symbols) and the lines with a
  system symbol in front.
- **A switch leaves the menu open.** Pressing Microphone, Sound or Pointers
  sends the action and changes nothing by itself: the button changes when the
  web client reports the new state, and a menu with the same items in another
  state is changed in place. The buttons that end something close the menu.
- **Width.** Beside an item with a view of its own the system sizes the menu
  by that view and cuts the lines of text short ("Показа…B:SPACE"), so the
  menu's minimum width is worked out from its longest line
  (`SystemTrayPresenter.minimumWidth`).
- **What the web client reports.** `set-tray-context` carries `signedIn`,
  `voice`, `muted`, `deafened`, `status`, and, for this shell alone,
  `cameraOn`, `screenSharing` and `showPointers`. A server whose web client
  is older does not send the last three: Pointers, Turn off camera and Stop
  sharing are then left out and the rest works. The actions that come back
  are `toggleMute`, `toggleDeafen`, `disconnect`, `setStatus`, and from this
  shell alone `toggleShowPointers`, `stopCamera`, `stopScreenShare`.
- **A context that cannot be read is refused whole** (`TrayContext`), a field
  of the wrong type among the three included, and the menu stays as it was.
  A channel name longer than 40 characters is cut with an ellipsis.
- **Another page.** When the window shows another page (the picker, recovery,
  a reload), the controls go and the character rests until the new page
  reports. The Electron build keeps what the last page said, so its menu can
  offer controls to a page that does not listen.
- An executable that is not an application bundle has no frame images and
  shows no tray.

### Game detection

The shell notices a game or app it knows among the running processes and
tells the web client, which shows it as the user's activity when they allow
it. `BSpaceCore/Activity.swift` and `BSpaceShell/ActivityDetector.swift` are
a port of `packages/desktop/src/activityDetector.ts`.

- **The dictionary** is `games.json` of the Electron build (`{ version, games
  }`, each game an id, a name, process names and a type), copied into the
  bundle. Entries that are not games are skipped; a file with none left is
  not a dictionary.
- **Looking.** Every fifteen seconds the processes are listed with the
  system's `ps -c -A -o comm`, the command the Electron build runs, so the
  names are the ones the dictionary was written against. The first listed
  game one of whose processes is running, whatever the case, is the activity.
  The web client hears of it once when it starts (`activity-detected` with
  `{ type, name, timestamps: { start } }`) and once when it ends (`null`),
  and reads the same from `getCurrentActivity()`. If the processes cannot be
  listed, detection stops instead of asking again.
- **A newer dictionary** is fetched once at start from the project's
  repository (`GameDictionarySync.remoteAddress`), with the tag of the copy
  already here, so an unchanged file costs no download. A newer one is saved
  as `games-cache.json` with its tag in `games-cache-etag.txt` (the Electron
  build's files, in the settings folder) and used from the next look on; what
  is detected at that moment stays detected.
- **Which one to start with.** The saved dictionary or the shipped one,
  whichever is newer. The Electron build takes the saved one whenever it can
  be read, so there an app update with a newer dictionary waits for the
  network.

### Global keybinds

What the web client syncs over `keybinds-sync` is listened for while any app
is in front, and the web client is told over `keybind-action` when an action
begins and ends: push-to-talk with the window hidden. The logic is in
`BSpaceCore/Keybinds.swift`, the listener and the permission in
`BSpaceShell/Keybinds.swift`; together a port of
`packages/desktop/src/keybindManager.ts`.

- **Keys.** The web client records a keybind as hashes of DOM
  `KeyboardEvent.code` strings. `KeyCodes.domCodes` names the DOM code of
  each of the system's virtual key codes, and `KeyCodes.hash` is the web
  client's own hash (djb2 over UTF-16 units, wrapped to 32 bits). A test
  reads the table of `packages/desktop/src/keybindManager.ts` and holds the
  two to the same codes, short of six keys no Mac keyboard has (F21 to F24,
  Scroll Lock, Print Screen).
- **Matching.** `KeybindMatcher` is fed what the system reports and answers
  with the actions that begin and end. An action is pressed once when all
  its keys are down and released once when one goes up, however often the
  system repeats a held key. A mouse button (3 middle, 4 back, 5 forward)
  fires its keybind with the keys held and ends it when the button goes up;
  the left and right buttons are never keybinds.
- **Modifiers.** The system reports Shift, Control, Option and Command as a
  change of the flags, not as a key going down or up. Which key it was, and
  whether it is down, is read from the bit each side has of its own
  (`ModifierKeys`): with both Shifts held, the shared bit stays set when one
  is let go.
- **The listener** is an event tap that only listens
  (`EventTapKeyInputSource`): it cannot change or hold back what it sees. It
  runs only while there is a keybind to listen for, and is switched back on
  when the system switches it off for answering slowly.
- **A release the system never reports.** While a password is typed the
  system hides the keyboard from listeners, and it switches a listener off
  when it answers slowly; a release lost that way would leave push-to-talk
  transmitting. So twice a second, while anything is held, and whenever the
  listener was switched off and on, what is believed to be down is checked
  against what the system says is down (`KeybindMatcher.reconcile`,
  `SystemKeyStateProbe`), and what is not is let go. The Electron build has
  no such check.
- **The permission is Input Monitoring**, not Accessibility as in the Electron
  build: a tap that only listens needs no more
  (`InputMonitoringPermission`). The first keybind has the system ask for
  it; `check-accessibility` answers whether it is given and
  `accessibility-status` says so when it changes (the web client's names are
  Electron's). When the window comes forward the shell looks again, so
  coming back from System Settings starts the listening. The web client's
  settings show a warning that names this permission and whose button opens
  its list (`openKeybindPermissionSettings`, a `nativeOnly` member).
- **Another page.** When the window shows another page its keybinds go and
  the listening stops, until the new page syncs its own. The Electron build
  keeps the list of the page that is gone.
- The Wayland portal of the Electron build has no part here:
  `keybind-portal-status` answers null and `keybind-portal-retry` does
  nothing.

### The microphone and the camera

A web view asks the shell before it asks the system
(`requestMediaCapturePermissionFor`). Left unanswered, WebKit shows its own
question on top of the system's, again on every page load. The shell answers
by `MediaCapturePolicy`:

- the page of the window, asking for itself, is granted; the only question
  the user then sees is the system's, once, with the text from the string
  catalog (`mac.permission.*`, written into the bundle);
- a frame inside the page is denied, whatever its origin: an embedded player
  has no business with the microphone. The Electron build grants every
  request (it sets no permission handler);
- the shell's own pages (the instance picker, recovery) are denied.

Each answer goes to the log (`[media] the page asked for the microphone:
granted`). Not seen on the built app yet: the system's question and a working
microphone and camera in a call.

Choosing the output device is the web client's part: WebKit has no
`AudioContext.setSinkId`, so the client plays its mix through a media element
pointed at the device (`OutputRouter`; "Output routing" in
[voice.md](../../docs/systems/voice.md)).

### What can be shared

`get-screen-sources` answers with every display and every ordinary window,
each with a picture, in the shape the web client's stream setup screen reads
(`ScreenSource.bridgeValue`). Ids are spelled as the Electron build spells
them, `screen:<display id>:0` and `window:<window id>:0`: the client
remembers the id shared last time.

- **The list** comes from ScreenCaptureKit (`SystemScreenSourceLister`).
  Displays first, then windows in the system's order. A window is listed
  when `ScreenSourceRules.isListed` says so: an application's, on the
  ordinary level, on screen, titled, at least 48 points on each side, and
  not the system's furniture. The last rule is there for Stage Manager,
  which keeps a small titled copy of every window in its strip on the
  ordinary level: without it each of those windows is listed twice (seen on
  a machine with Stage Manager on: 15 windows, 5 after the rule).
- **Pictures** are taken at once for all of them (`SCScreenshotManager`),
  fitted into 320 by 180 pixels with the proportions kept, never enlarged,
  as PNG. A window's application icon is drawn at 32 pixels. A source the
  system would not photograph is left out.
- **Names.** A window is called by its title. A display is called by its
  own name ("Built-in Retina Display"), where the Electron build says
  "Screen 1"; `mac.capture.screen` is for a display the system has no name
  for.
- **Who may ask, and how often** (`ScreenSourceGate`, the rule of the
  Electron build's `screenSharePolicy.ts`): the pictures are of the user's
  screen and the page is a server's code. New pictures are taken only while
  the app's window is the one the user works in, and no more often than once
  a second; otherwise the page gets the list it had. Requests that arrive
  while a list is being made share it. A list is not carried to another
  page.
- **Permission.** Without Screen Recording the list is empty and the system
  is asked once (`CGRequestScreenCaptureAccess`).
- **A window in the Stage Manager strip** is listed at the size it has
  there, and the system reports that size for its content too. What a
  capture of such a window carries has to be looked at when the capture
  exists.

On this machine the real list (1 display, 5 windows) took 0.44 s and reached
the page as 258 KB of JSON; with 15 windows, 0.88 s and 411 KB.

The web client does not ask for the list yet: it has to say that it can take
a native capture before `get-screen-share-picker-mode` answers `'app'` (see
"Capturing the screen").

### The local media channel

Captured video and sound reach the page over a WebSocket on the loopback
address (`LocalMediaChannel`). A page served over `https` may open nothing
less than `wss://`: `ws://127.0.0.1` and a custom URL scheme are refused as
mixed content (measured in the audit). The server's Content Security Policy
already allows it (`connect-src wss:`).

- **The certificate.** Nobody can issue one for `127.0.0.1`, so every channel
  makes its own (`LocalIdentity`): a fresh P-256 key and a version 3
  certificate signed with it, for the address `127.0.0.1`, a TLS server's,
  written in DER by the package itself. The system turns a key and a
  certificate into a TLS server's identity only through a PKCS#12 file, so
  one is written in memory (triple DES and HMAC-SHA1 with the key derivation
  of RFC 7292: the form everything reads) and imported with
  `kSecImportToMemoryOnly`. No keychain is touched and nothing is
  written to disk.
- **Trust.** Nothing trusts that certificate except the shell's own web view:
  when a TLS server shows its certificate, the navigation delegate vouches
  for it only if the address is `127.0.0.1`, the port is that of a channel
  the shell has open, and the certificate is that channel's, byte for byte.
  Everything else is decided by the system as before.
- **Who may speak** (`MediaChannelGate`). Any program of the machine can
  connect to a loopback port. A handshake from an origin other than the
  page's is refused. Then the first message has to be the token the shell
  gave the page, 32 random bytes; it works once, a wrong guess does not spend
  it, and nothing that connects after it was used is heard, even when that
  connection is gone. A connection that says nothing for five seconds is
  closed.
- **A slow page.** A message is dropped, and `send` says so, when 4 MB
  already wait to be sent: old frames are worth nothing.
- **One page.** A channel is opened for the page the window shows
  (`openMediaChannel`; the shell's own pages get none) and closed when the
  window shows another.

Measured on the shell (`--check media-channel`, macOS 27.2.1): 240 messages
of 40 KB at 60 a second reach the page 0.2 ms after they leave at the median,
1.8 ms at the 95th percentile, 4.8 ms at most. The same from a page with an
`https` origin, on a bench: 0.5, 3.1 and 8.2 ms.

The page gets the address and the token from `startNativeScreenCapture`
(see "Capturing the screen").

### Video on the channel

What the channel carries is described by `MediaWire`. Text messages are JSON
and say what is coming; binary messages are the media.

- **The format** is announced before the first frame and whenever it changes:
  `{"type":"video","codec":"avc1.64002a","width":1920,"height":1080,"description":"<base64>"}`.
  `codec` and `description` (the `avcC` decoder configuration record) are
  what WebCodecs' `VideoDecoder.configure` takes.
- **A frame** is a binary message: one byte for what it is (1 a key frame,
  2 a frame that needs the ones before it), eight bytes for when it was
  captured (milliseconds since 1970, a little-endian double, the page's
  `Date.now()` clock), then one H.264 access unit with each NAL unit behind
  its length in four bytes, as VideoToolbox makes it.
- **The page may ask** for a key frame with `{"type":"keyframe"}` when its
  decoder lost its place.

`VideoEncoder` makes the frames: H.264 High profile on the hardware encoder,
in real time, with no frame reordering, about 0.12 bits a pixel
(`VideoShape.bitsPerSecond`: 15 Mbit/s at 1080p60, 27 at 1440p60, 43 at
3024 by 1964; the page decodes it and the browser encodes it again for the
call, so this stream is kept well above what the call carries). A key frame
is made at the start, when the page asks, and at least every ten seconds.

Two things were found by measuring, and both differ from what the audit's
prototype did:

- **The low-latency rate control is not used.** Asking for it
  (`EnableLowLatencyRateControl`) selects another encoder,
  `h264.rtvc`, in place of the hardware one, `ave.avc`. On macOS 27.2.1, 180
  frames at 60 a second:

  | Size | Hardware encoder: frames out, time inside | Low-latency: frames out, time inside | Low-latency: the call blocks |
  |------|-------------------------------------------|--------------------------------------|------------------------------|
  | 1920 by 1080 | 60 a second, 18 ms | 39 a second, 124 ms | 25 ms a frame |
  | 2560 by 1440 | 60 a second, 23 ms | 34 a second, 28 ms | 28 ms a frame |
  | 3024 by 1964 | 60 a second, 35 ms | 29 a second, 163 ms | 32 ms a frame |

  With the hardware encoder the call returns in 0.1 ms.
- **The stream is made to say that its frames come in order**
  (`H264ParameterSets`). The hardware encoder does not reorder frames and
  does not say so, and a decoder that is not told assumes the worst its
  level allows: WebKit's held 4 frames at 1080p, 12 at 1440p and 7 at 3024
  by 1964 before showing the first. The sequence parameter set in the
  decoder configuration record is rewritten to carry
  `bitstream_restriction_flag` with `max_num_reorder_frames` of zero, and
  nothing else in it changes. Choosing another profile does not help
  (Baseline, Constrained Baseline, Main and Constrained High were tried).

Measured end to end on the shell (`--check video-pipe --size <w>x<h>`, run by
hand: it measures this machine's hardware encoder): 300 frames the check
draws, a busy picture, 60 a second, through the encoder and the channel to a
worker of the page that decodes them (`VideoDecoder`) into a track
(`VideoTrackGenerator`) the page plays, which is how the web client will do
it. From a frame being made to its being decoded in the page, after the
first second, over several runs on a machine that was busy with other work
(load average 10 to 17):

| Size | Frames a second in the page | Median | 95th percentile | With the decoder left to guess (median) |
|------|----------------------------:|-------:|----------------:|----------------------------------------:|
| 1920 by 1080 | 60 | 23 to 26 ms | 36 to 63 ms | 90 ms |
| 2560 by 1440 | 60 | 28 to 31 ms | 40 to 79 ms | 230 ms |
| 3024 by 1964 | 58 to 61 | 42 to 46 ms | 51 to 115 ms | 161 ms |

The encoder gave back no frame and the channel dropped none. The 95th
percentile is mostly the key frame the page asks for half way through: it
is large and arrives late, and the frames behind it queue.

**A page that falls behind catches up.** Nothing on the way drops a frame,
so a decoder that is slower than the stream for a moment would stay late
for good, and later with every such moment: at 3024 by 1964, on the busy
machine, one run in three ended with 30 frames waiting in the decoder and
frames 0.8 s late. The reader therefore watches the decoder's queue: more
than four frames waiting, and it resets the decoder, asks the shell for a
key frame and skips what arrives before it. In the runs where that
happened (once in a run, 10 or 11 frames skipped of 300) the latest frame
was 0.16 to 0.22 s late. The check's page does this; the web client's
reader has to do the same.

What feeds the encoder is in "Capturing the screen".

### Capturing the screen

A capture starts when the page calls `startNativeScreenCapture({ sourceId,
maxWidth, maxHeight, frameRate })` with an id from the list of sources. The
shell opens a local media channel, starts the capture and the encoder, and
answers with an id for the capture, the channel's address, its token and the
size and rate of the video that will come; the page connects and decodes.
`stopNativeScreenCapture(id)` ends it, and so does the window showing
another page. A page may have up to four at once: while a share runs, the
stream setup screen previews the source the user is about to switch to, and
a change of size starts the new capture before it stops the old one.

- **The capture** is ScreenCaptureKit's (`SystemScreenCapturer`): a display
  by its id, or one window apart from the desktop. The video has the
  source's own size in pixels, fitted into what was asked for with the
  proportions kept and both sides even (`VideoShape.encodedSize`; a 3456 by
  2234 display asked for at 1080p is 1670 by 1080), in the pixel format the
  hardware encoder takes without a conversion, with the pointer in it. The
  size is decided when the share starts: a window resized later is scaled
  into it.
- **A screen that stands still.** The system sends a frame only when
  something changed. A page that connects a moment after the capture
  started, or a decoder that asks for a key frame, would wait for the next
  change with nothing to show, so the session (`CaptureSession`) keeps the
  last frame and encodes it again as a key frame when the screen has not
  changed within 50 ms of being asked.
- **A frame that could not be sent** (the page reads too slowly, or has not
  connected yet) breaks the chain the following frames depend on, so the
  next one is made a key frame.
- **The capture ending by itself** (the window was closed, the display
  unplugged, the permission taken away) closes it, and the page hears
  `onNativeScreenCaptureEnded` with its id.
- **Refusals** say why: `bad-request` (no source named), `no-permission`
  (no Screen Recording; the system has been asked), `no-source`,
  `unsupported` (a shell that does not capture), `too-many`, `failed`.
- **Who picks the source.** `getScreenSharePickerMode({ nativeCapture: true
  })` answers `'app'`: a web client that says it can take a native capture
  is shown the app's own list. Without the argument the answer is
  `'system'`: a client from before native capture calls `getDisplayMedia`
  and WebKit shows its own picker (plan, 5.5).

Checked on the shell with a screen the check makes up (`--check capture`,
part of `contract-check.sh`): the picker mode by what the client says; a
request without a source, and for one that is gone; a share fitted into what
was asked for and decoded in the page; a screen standing still giving a
picture to a page that connects late and to a decoder that asks; two
captures at once, each stopped by its id, and a fifth refused; the three
ways a capture ends.

The real screen (`--check capture-system`, by hand, macOS 27.2.1): the main
display, 3456 by 2234, asked for at 1080p and 60 frames a second, was
captured at 1670 by 1080; in five seconds of ordinary work on screen the
page decoded 249 frames, 51.5 a second while the screen changed, each 20 ms
after it was captured at the median, 38 ms at the 95th percentile, 59 ms at
most; no frame was skipped.

**The web client's side** is `packages/web/src/platform/nativeCapture/`
(change 4 of the plan). `nativeScreenCapture.ts` starts a capture and
returns an ordinary stream with one video track; a module worker
(`reader.worker.ts`) connects to the channel, decodes with `VideoDecoder`
and writes into a `VideoTrackGenerator`, which WebKit has in workers only;
`channelReader.ts` is its logic, the catch-up rule included (see "Video on
the channel"). Stopping the track ends the capture; a capture that ends by
itself fires `ended` on the track; another size or rate is a second
capture of the same source behind the same track. The stream setup screen
passes `nativeCapture: true` when it asks who picks the source, and stages
the picked tile through it instead of `getDisplayMedia`. The details are in
"Screen sharing in the native macOS client" in
[voice.md](../../docs/systems/voice.md).

That code was run in the shell (`--check capture-web`, by hand: it needs the
web package's dev server and its workbench page
`dev-native-capture.html`) with a screen the check makes up: the track plays
in a video element at 1152 by 720, goes on playing, follows other limits to
640 by 400 behind the same track while the first capture stops, says when
the capture ends, stops the capture when stopped, and reports a source that
is gone.

Not done: a share in a real call (through LiveKit, watched from another
client), processor load and the comparison with the Electron build are
not measured.

### The shell's own share

The share the app is meant to have (plan section 12): the shell joins the
call itself, as the user's stream participant, and publishes what it captures
with one hardware encode. The page decides (which call, with which stream
token, what to share, at what quality) and the shell does it; nothing of the
share passes through the page. It replaces the path above, where the picture
went to the page over the local channel and was encoded a second time there;
that path is still in the tree and goes once the new one has been through a
call.

| Piece | Where | What it is |
|---|---|---|
| `ScreenShareRequest`, `ScreenShareUpdate`, `ScreenShareReply`, `ScreenShareEvent`, `ScreenShareStats` | `BSpaceCore/ScreenShare.swift` | What the page and the shell say to each other, with the bounds a request is brought into. A call server is a `wss://` address, or `ws://` to this machine only |
| `ScreenSharePublisher` | `BSpaceShell/ScreenShare.swift` | A share's connection to a call, as a protocol: join, publish video, take frames, change the encoding, publish and unpublish sound, leave |
| `ShareSession` | the same file | One share: the capture, the sound, the publisher, and their order. The capture is prepared first, so a missing permission or a source that is gone is said before the call hears of anything. A change of source, size or rate starts a new capturer whose frames take over when it runs, and the track is not published again. A window that changes size is followed, as in the capture path |
| `LiveKitSharePublisher` | `BSpaceShell/LiveKitSharePublisher.swift` | The real connection, through the fork of LiveKit's library (below). The library's mode without devices, so nothing opens a microphone; H.265 keeps an H.264 backup track; sound at 128 kbit/s; WebRTC's adaptation switched off (it reads the hardware encoder's latency as load and cuts 60 frames a second to 40) |

Bridge members: `startNativeScreenShare`, `updateNativeScreenShare`,
`stopNativeScreenShare`, `onNativeScreenShareEvent`, and for the preview
`startNativeSharePreview`, `setNativeSharePreviewFrame`,
`stopNativeSharePreview`, all `nativeOnly`;
`docs/systems/desktop.md` has their arguments and answers. One share per
window. `getScreenSharePickerMode({ nativeShare: true })` answers `app` when
the shell can publish.

Checks:

- `--check share` (in `contract-check.sh`): the session through the bridge
  with a screen, a system and a call the check makes up. What is refused
  and before what is made for it, what the call is handed, what each change
  touches and leaves, every way a share ends, and that it goes with its page.
- `--check share-live --url wss://… --token-file <stream token> [--seconds 20]
  [--codec h265]` (by hand): the same start through the bridge with the real
  publisher into a real room, a made-up screen and sound, a change of bitrate
  in the middle; prints what the connection reports. Watch the room with
  `StreamProbe --watch`. Measured on 2026-11-19: 1920 by 1200 at 60 frames a
  second for 70 seconds, hardware H.265, the viewer at 60 to 61 with no
  freeze, sound at 128 kbit/s as screen share audio.

The app bundle carries the library's two frameworks in
`Contents/Frameworks` (`bundle.sh` copies them and adds the search path,
`sign.sh` signs them before the app); the bundle is 46 MB with them.
`scripts/toolchain.sh` makes `bundle.sh` and `contract-check.sh` build with
Xcode's toolchain: built by the Command Line Tools the library compiles and
then crashes when a share joins a call.

### The rate of a capture

ScreenCaptureKit does not give the rate it is asked for. Asked to leave a
sixtieth of a second between frames on a display that refreshes 120 times a
second it gives about 57 frames a second, 42 for 45 and 29 for 30 (the first
share in a real call arrived at 53 and at 28): a frame that comes a hair
before its time is skipped, and the next is a whole refresh later. Asked for
a shorter interval it gives more than the rate, by an amount that depends
on the display.

So `SystemScreenCapturer` asks for frames with room to spare (three
quarters of the rate's interval, `frameIntervalFactor`) and `FramePacer`
(`BSpaceCore`) picks the rate's own out of them: a schedule that moves by
whole intervals, so a frame taken a little early or late does not shift
the ones after it, and a screen that stood still is not made up for. It
covers the share, the preview and the capture path alike.

`--check capture-rate-system` (by hand: a small window that changes at
every refresh, and the system's recording indicator) counts the frames
three ways. On 2026-11-20, on the built-in display at 120 Hz:

| Asked for | The system, for the rate itself | The system, with room to spare | The capturer |
|---|---|---|---|
| 60 | 56.9 | 73.8 | 59.7 |
| 45 | 42.3 | 57.5 | 45.1 |
| 30 | 29.2 | 38.6 | 30.0 |

### The live preview of a source

Before a share starts, the stream setup screen shows the picked source live.
The shell draws it: a capture at a preview's size (`SharePreview`, at most
1280 by 800 at 30 frames a second) whose frames are handed, as they are, to
an `AVSampleBufferDisplayLayer` in a view over the web view
(`SystemSharePreview`). No encoder, no copy, and nothing of it passes through
the page, so it does not stutter when the page is busy, which the preview of
the capture path did.

The page says which source (`startNativeSharePreview`) and where its preview
box is (`setNativeSharePreviewFrame`, viewport coordinates and a corner
radius; `SharePreviewFrame` reads and bounds it). The view lies over the
page: what the page draws over its box would be covered, so the page hides
the picture (a frame of `null`) while the box moves or something of its own
is over it. Clicks go through to the page. The preview ends with
`stopNativeSharePreview`, with its source (`preview-ended` on the share's
event channel) and with its page.

Checks: `--check share` covers the preview through the bridge with a
presenter that only remembers where it was put; `--check
share-preview-system` (by hand) puts the real layer in a small window on the
screen, feeds it made-up frames, captures the window and measures that a
picture is there (16 to 234 of 255 in brightness on 2026-11-19; a layer that
draws nothing is one flat colour).

### The system's sound

A share can carry what the Mac plays: everything except this app, so that
viewers do not hear themselves through the call. It is a capture of its own,
apart from the picture's, for two reasons. The System Audio switch turns it
on and off while a share runs, and the picture must not stop for that. And
one ScreenCaptureKit filter cannot keep the app's window in the picture and
the app's sound out of the audio: the sound follows the applications the
filter names.

`SystemSoundCapturer` (`SystemAudioCapture.swift`) is a ScreenCaptureKit
stream of the main display with this app in the filter's excluded
applications, `capturesAudio` on, 48 kHz in two channels. A stream cannot be
of sound alone, so it also takes a picture two pixels wide once a second,
which nobody reads. The app is found among the applications the system
lists by its process id; the system counts the sound of the web view's
helper processes as the app's (measured with CaptureProbe, below). That holds
for an app started the usual way. One started from a terminal has its
helpers counted as the terminal's and hears itself: a development build run
that way sends the call back to its viewers.

`SystemAudioSession` puts the samples on a local media channel of its own:
the format as a text message when the page connects
(`{"type":"audio","sampleRate":48000,"channels":2}`), then binary messages
of kind 3 whose payload is 32-bit little-endian floats, frame after frame,
each channel's sample in turn (`SystemAudio.interleaved` lays the system's
one-array-a-channel samples out that way). Samples from before the page
connected go nowhere, and samples the channel cannot take are dropped:
sound that is late is worth less than a gap.

The bridge has three members for it, all `nativeOnly`:

| Member | What it does |
|--------|--------------|
| `startNativeSystemAudio()` | Starts a capture. Answers `{ ok: true, id, url, token, sampleRate, channels }` or `{ ok: false, reason }` with `no-permission`, `unsupported`, `too-many` or `failed`. Up to four at once |
| `stopNativeSystemAudio(id)` | Ends that capture and closes its channel |
| `onNativeSystemAudioEnded(cb)` | A capture ended by itself; the callback gets `{ id }` |

`getSystemAudioCapability` is answered by what the client says it takes, as
the picker mode is: `{ nativeAudio: true }` gives `excluded`, anything else
`unavailable`. A web client from before this capture uses WebKit's
`getDisplayMedia`, which gives a share no system audio, and its stream
settings say so.

The web client's side is in `packages/web/src/platform/nativeCapture/`
(`nativeSystemAudio.ts`, a worker that reads the channel, an audio worklet
that plays the samples into a track); see "Screen sharing in the native
macOS client" in [voice.md](../../docs/systems/voice.md).

Checked on the shell with a system the check makes up, a tone on each
channel (`--check system-audio`, in `contract-check.sh`): the capability
answers, the format, both tones on their own sides at the level they were
made at, the three ways a capture ends, the limit of four. The web client's
own code was run on it (`--check capture-web`): a meter in the page hears
440 Hz on the left and 880 Hz on the right of the track at the level they
were made at.

The real system (`--check system-audio-system`, by hand, macOS 27.2.1):
48,000 frames a second in pieces of 960 frames (a fiftieth of a second),
sent whether anything plays or not, at most 32 ms apart, the oldest sample
50 ms old when the page read it. With a 440 Hz tone played at 0.003 by the
check's own page, the channel carried 440 Hz at a level of 0.0021 (the tone's
root mean square) and so did the track the web client's code made of it,
with 27 ms waiting in its buffer, nothing skipped, and no gap in three
seconds.

**A page nobody sees.** The window of a check is never shown, and WebKit
holds back a page that has been hidden for about half a minute: timers in
its workers drop to ten a second, and the clock of an audio worklet loses
between 3 and 19 percent against the wall clock (`--check audio-clock`, by
hand; for the first half minute every arrangement tried keeps exact time:
one context or two at once, at the same rate or at different ones, a worklet
fed by the page or by a worker, with or without something listening to its
stream). Sound then piles up in the web client's buffer and is skipped a
fifth of a second at a time. A page that plays something audible is not held
back: the run with the tone above kept time. In a call the page captures a
microphone and plays the other side, which should keep it awake when the
window is hidden or behind the game being shared; that is not measured, and
it is the first thing to look at when a share is tried in a real call.

Not done: a share with sound in a real call; the app's own sound left out
of a capture the app itself runs (the experiment used a capture by another
process); whether a running audio router (SoundSource) doubles the sound,
which `getAudioRouters` would warn about and still answers with nothing.

### Viewers' pointers

Viewers of a share can point at it. In the app their pointers are drawn on
the stream tile; the sharer is looking at the real desktop, so the shell
draws them there, over the display being shared. The page owns the state
and sends the whole list on every change (`setStreamPointerOverlay`,
`endStreamPointerOverlay`: members the Electron build already had, and the
web client needed no change).

- **The list** is checked as the Electron build checks it
  (`OverlayPointers.sanitized`): at most 32 pointers, each with an id and a
  place inside the picture; a name is cut to 64 UTF-16 units; a colour that
  is not a plain `rgb(…)` is replaced.
- **The display** is the one the share shows (`PointerOverlayTarget`). The
  shell knows which captures run, not which is published, so the pointers
  go on the display of the newest capture of a whole display that still
  runs. A share of a window has none, as in the Electron build. While the
  stream setup screen previews another display the pointers are on that
  one, and come back when the preview is dropped.
- **The window** (`SystemPointerOverlay`) is a borderless, non-activating
  panel the size of the display: transparent, above everything
  (`.screenSaver`), on every Space and over full-screen applications, out
  of Mission Control, never key, and it ignores the mouse. It is shown
  while there are pointers and ordered out when there are none. The arrow,
  the name's tag and the ring of a click have the Electron overlay's shapes,
  sizes and timings; the name is set in the system font.
- **Out of the share.** A capture of a display names the panel in its
  content filter (`ScreenCaptureRequest.excludedWindows`, filled in by the
  shell, never by the page), so viewers do not see each pointer twice. The
  panel is made, not shown, when such a capture starts, and kept for as
  long as the shell runs: the captures know it by its window number. It
  also has the sharing type that asks the system to keep it out of captures
  the shell does not run (the system's picker).
- **`onStreamPointerOverlayCaptured`** is never sent: it is the Electron
  build's report that Windows put the overlay into the picture after all.

Checked on the shell with a screen and an overlay the check makes up
(`--check pointer-overlay`, in `contract-check.sh`): what the page sends is
checked on the way, the pointers go on the display a share shows and
nowhere without one, the capture is asked to leave the overlay's window
out, and the pointers go when pointing ends, with the share and with the
page.

The real overlay over the real main display (`--check
pointer-overlay-system`, by hand, macOS 27.2.1), in three captures of that
display. An overlay made not to hide itself is in a capture that leaves
nothing out, and is not in one that names its window: the filter works by
itself. The overlay as the app makes it is not in a capture that leaves
nothing out either: on this system ScreenCaptureKit honours the window's
sharing type too. The same check writes a picture of the pointers alone,
drawn off screen, which is how their look was compared with the page's.

Not looked at on the screen by a person: the panel over a full-screen
application and across Spaces, with Stage Manager on, and that a click goes
through it. Not tried in a real call, with real viewers pointing.

### The bridge

`window.backspace` is built from `packages/desktop/src/bridgeContract.json`,
the description Electron's preload is held to as well (see "Bridge contract"
in [desktop.md](../../docs/systems/desktop.md)). `BridgeScript` turns it into
the script injected at document start in the main frame; `BridgeRouter` routes
what the page posts to handlers by channel name; `BridgeHost` connects the two
to WebKit and sends the shell's events back.

A member marked `nativeOnly` exists in this shell alone, for something this
shell does differently from the Electron build: `setDragRegions` (see
"Dragging the window"), `openKeybindPermissionSettings` (see "Global
keybinds"), and `startNativeScreenCapture`, `stopNativeScreenCapture` and
`onNativeScreenCaptureEnded` (see "Capturing the screen").

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
left alone; Reload, Change Instance, Quit and the releases page work), and
dragging the window (`--check drag`: a page that reported nothing is dragged
by its top strip and no lower; what `setDragRegions` reports replaces the
strip, exceptions included; a report that cannot be read changes nothing; the
next page starts from the strip again; the page sees nothing of a press that
drags and the whole click of one that does not; a double click asks the
system's setting; the parts follow the window's size). The check reads which
parts the system is told about and gives its presses to the web view
directly. The drag itself is the system's and needs a real mouse: it was
tried by hand on the built app. The tray (`--check tray`) is checked with
something that records what it is given in place of the menu bar: every
frame image loads at 18 by 22 points, as a template, with its `@2x`; the
character plays the loop of the state the page reports and ignores a state
that is not one; this system has every symbol the menu is drawn with; the
menu has the row of buttons the page's context allows, fewer for a web
client that does not report the camera, the screen share and the pointers,
and stays as it was for a context that cannot be read; a pressed button
comes back to the page as a `tray-action`; Show and Quit do what they say;
the menu follows the page's language; another page starts from an empty menu
and a resting character. Game detection (`--check activity`) is checked with
a list of processes and an answer of the network that the check makes up:
the page hears of a game once when it starts and once when it ends and reads
the same from `getCurrentActivity`; a fetched dictionary is saved with its
tag and used; a second start reads the saved one and names its tag;
detection stops when the processes cannot be listed; the system's own list
is read once. Nothing is fetched there: `--check activity-network`, run by
hand, fetches the dictionary once the way the app does. The global keybinds
(`--check keybinds`) are checked with a keyboard and a permission the check
makes up: without the permission nothing is listened to, the page is told
and the system is asked once; with it a held key presses its action once and
releases it once, and a release that was never reported ends the action all
the same; a combination with a modifier and a mouse button work; an
empty list stops the listening; a list that cannot be read changes nothing;
the page's request opens the permission's settings; a listener the system
will not start is reported; another page starts with no keybinds. No real
key is listened to there. The list of what can be shared (`--check
sources`) is checked with a list the check makes up: a focused window gets
it in the shape the web client reads; a second request within a second and
a window that is not focused get the list they had; two requests at once
share one listing; another page starts with nothing. The screen is not
looked at there: `--check sources-system`, run by hand, asks the system
once and prints how many displays and windows it gave and how large their
pictures are, never a name, a title or a picture. The local media channel
(`--check media-channel`) is checked on a page served from the loopback
address: a window with no page gets no channel; a connection that says a
wrong token is closed and hears nothing; the one that says the token gets
240 messages of 40 KB at 60 a second, and the check prints how long they
took; what the page says back reaches the shell; the token works once; a
channel the shell did not open is not trusted by the page; the channel
closes with its page. `--check video-pipe`, run by hand, sends frames the
check draws through the encoder and the channel to a decoder in a worker
of the page and prints how long they took (see "Video on the channel").
A share (`--check capture`) is started through the bridge with a screen
the check makes up; `--check capture-system`, run by hand, captures
the real main display for a few seconds; `--check capture-web`, run by
hand against the web package's dev server, runs the web client's own
capture code in the shell (see "Capturing the screen").
The system's sound (`--check system-audio`) is asked for through the
bridge with a system the check makes up; `--check system-audio-system`,
run by hand, captures the real system's sound for a few seconds, and
`--check audio-clock`, run by hand, measures how an audio context's clock
runs in the web view (see "The system's sound").
Viewers' pointers (`--check pointer-overlay`) are sent through the bridge
with a screen and an overlay the check makes up; `--check
pointer-overlay-system`, run by hand, draws the real overlay on the main
display for a few seconds and captures it (see "Viewers' pointers").
Then it loads
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

## CaptureProbe

The experiment stage 4 starts with. The client streams system audio next to a
voice call. If the call's own sound came back through the capture, everybody
in the stream would hear themselves, so the capture has to leave the
application out. A web view does not play in the application's process,
though: WebKit's helper processes do. Does excluding the application exclude
them?

The probe opens a page that plays four quiet tones, one through each way a
page makes sound, records system audio with ScreenCaptureKit under each way of
leaving an application out, and reports which tones each recording holds. A
second copy of the probe, in a bundle with another identifier, plays the same
four paths at other frequencies: it is "some other application", and, started
through LaunchServices whatever the probe itself was started by, it is the
subject of the question.

```bash
# From packages/desktop-macos. About fifty seconds of quiet tones.
scripts/capture-probe.sh -- --gain 0.02
scripts/capture-probe.sh --open -- --request-permission   # under the probe's own permission
scripts/capture-probe.sh --help
```

It needs the Screen Recording permission: the terminal application's when run
as above, its own with `--open`. A tone counts as present when the recording
holds it within 3 dB of the level it was played at, and as absent when it is
10 dB or more below; a capture records an application at the level the
application gave its sound, whatever the output volume.

### What it showed

macOS 27.2.1, 2026-11-18, probe started from a terminal, second copy started
through LaunchServices. Level of each tone in the recording, in dB relative to
full scale; the tones were played at -34.

| Capture | Probe: Web Audio | Probe: file | Probe: live stream | Second copy: Web Audio | Second copy: file | Second copy: live stream |
|---------|-----------------:|------------:|-------------------:|-----------------------:|------------------:|-------------------------:|
| Nothing excluded | -34 | -34 | -34 | -34 | -34 | -34 |
| `excludesCurrentProcessAudio` | -34 | -34 | -34 | -34 | -34 | -34 |
| Probe in `excludingApplications` | -34 | -34 | -34 | -34 | -34 | -34 |
| Both of the above | -34 | -34 | -34 | -34 | -34 | -34 |
| Only the other applications included | -138 | -136 | -112 | -34 | -34 | -34 |
| Second copy in `excludingApplications` | -34 | -34 | -34 | **-139** | **-113** | **-115** |
| Neither copy included | -160 | -160 | -160 | -160 | -160 | -160 |
| Nothing excluded, again | -34 | -34 | -34 | -34 | -34 | -34 |

- **An application started the ordinary way is excluded together with its web
  view's sound.** With the second copy in the content filter's list of
  excluded applications, none of its three tones is in the recording, and the
  probe's own tones still are. The system counts the sound of WebKit's helpers
  as the sound of the application they work for. The hypothesis of the plan
  holds, and the Core Audio process tap is not needed.
- **It follows the responsible process, not the bundle.** The probe itself,
  started from a terminal, keeps all its tones under both ways of excluding
  it: its helpers answer to the terminal's application. A client started from
  a terminal (`swift run`, the bundle's executable by path) will hear itself
  in its own stream; one started from Finder, the Dock, at login or by `open`
  will not.
- **A list of included applications works too**, and in both cases: leaving an
  application out of the list removes its web view's sound even for the
  terminal-started probe. It is the stricter filter, but it also drops
  everything that is not an application, and an application started after
  the capture began has to be added to it.
- The system does not list WebKit's helpers as applications of their own, so
  they cannot be excluded one by one.

Not answered by this run:

- **A track that arrived over WebRTC.** The two peer connections in the page
  did not reach each other on this machine (ICE failed with host candidates
  only; the machine's tunnel). The live-stream path stands in for it: a remote
  track reaches its element as a stream as well. A call on the test instance
  has to confirm it.
- **`excludesCurrentProcessAudio` for an application started the ordinary
  way.** It can only be read from inside such an application, which needs the
  probe's own Screen Recording permission (`--open`). The client does not
  depend on it: it names itself in `excludingApplications`.
- **The client itself.** The same has to be seen once on the built client,
  when its capture exists.

One thing about the page: a short file played on a loop is not a reliable
tone. The element started it up to thirteen seconds late or sat at zero while
reporting that it played; a file longer than the run plays from the start.

## StreamProbe

The experiment behind section 12 of the plan: can the shell publish a screen
share into a call by itself, through LiveKit's Swift library, with one
hardware encode. It joins a room with a token read from a file, publishes a
video track fed with frames of its own (made up, or a real display through
`SystemScreenCapturer`) and, when asked, a sound track fed with ready
samples, and prints once a second the encoder, the frame rate, the bitrate,
the network path and the process's CPU as WebRTC reports them. Started with
`--watch` and a viewer's token it joins the same room as a viewer, in a
process of its own, and prints what arrives.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --product StreamProbe
.build/debug/StreamProbe --url wss://<livekit> --token-file <publisher token> \
    --width 2560 --height 1440 --fps 60 --codec h265 --audio tone
.build/debug/StreamProbe --url wss://<livekit> --token-file <viewer token> --watch
```

`--degradation resolution|framerate|balanced|disabled` is what WebRTC may
give up when it thinks the encoder is overloaded. Run for more than 40
seconds to see it: with the default (`resolution`) WebRTC cuts 60 frames a
second to 40 at about that point, "limited by cpu", taking the hardware
encoder's 39 ms a frame of latency for load while the process uses a few
percent of a core; with `disabled` the share stays at 60. The shell
publishes with it disabled.

`--floor <kbit/s>` gives the encoding a bitrate floor, `--rebitrate <kbit/s>`
changes the ceiling in the middle of the run on the same track, and the
sound is published as screen share audio: all three come from the fork
below.

Build it with Xcode's toolchain: the same sources built with Command Line
Tools (Swift 6.1.2) crash when joining a room. `--source display` shows the
system's recording indicator and sends the main display to the room;
`--audio tone` feeds a made-up tone to the room only, nothing is played on
the machine; `--change` halves the frame rate and then the frame size in the
middle of the run. The tokens are minted by hand on a test server, and the
run is by hand too: nothing here is part of the app or of
`contract-check.sh`. What it measured is in the plan, section 12.11.

## The LiveKit library

The package depends on the project's fork of LiveKit's Swift SDK,
`funpin/client-sdk-swift`, pinned in `Package.swift` to a commit of its
`b-space` branch: upstream release 2.19.0 plus three additions the shell's
screen share needs, which upstream's public API does not have.

| Addition | Why |
|---|---|
| `LocalAudioTrack.createTrack(name:source:options:reportStatistics:)` | Upstream labels every local audio track `microphone`. The stream participant's token allows only `screen_share` and `screen_share_audio`, and viewers have to tell a share's sound from a voice |
| `VideoEncoding.minBitrate` | A floor the encoder keeps while the bandwidth estimate is lower. Without it an estimate that starts low makes the encoder drop frames for seconds (measured: 2 to 30 frames a second instead of 60, in about one start of seven) |
| `LocalTrackPublication.set(videoEncoding:)` | A new bitrate ceiling, floor and frame rate ceiling for a published track without publishing it again, for the quality controls during a share |

The fork's `FORK.md` says the same in the library's terms and how the first
addition relates to upstream's own draft. To move to a newer upstream
release: rebase `b-space` onto its tag, run the library's
`VideoEncodingsTests`, build this package with Xcode's toolchain, run
`StreamProbe` against a LiveKit server with a token that allows only the two
screen share sources (sound, `--floor`, `--rebitrate`), and only then change
the revision in `Package.swift`. `Package.resolved` is committed.

The library brings two dynamic frameworks, `LiveKitWebRTC` (29 MB for both
architectures) and `RustLiveKitFFI` (3 MB); putting them into the app bundle
and signing them is not done yet. SwiftPM downloads WebRTC for every Apple
platform at once, a 686 MB archive, on a clean build.
