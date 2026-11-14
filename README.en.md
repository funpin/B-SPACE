<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/b-space/png/lockup-128.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/brand/b-space/png/lockup-on-light-128.png">
    <img src="assets/brand/b-space/png/lockup-on-light-128.png" alt="B:SPACE" height="64">
  </picture>
</p>

<p align="center">
  <strong>Your own Discord on your own server. Text, voice, video and screen sharing.</strong><br>
  An independent fork of <a href="https://github.com/TheZwiss/backspace">TheZwiss/backspace</a> with its own interface and its own app builds.
</p>

<p align="center">
  <a href="https://github.com/funpin/B-SPACE/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/funpin/B-SPACE?style=flat-square&amp;label=release&amp;color=6E5BEF&amp;labelColor=121214"></a>
  <a href="https://github.com/funpin/B-SPACE/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/funpin/B-SPACE/actions/workflows/ci.yml/badge.svg?branch=main"></a>
  <img alt="Windows | macOS" src="https://img.shields.io/badge/Windows%20%7C%20macOS-desktop-8A8A94?style=flat-square&amp;labelColor=121214">
  <a href="LICENSE"><img alt="License AGPL-3.0" src="https://img.shields.io/badge/license-AGPL--3.0-8A8A94?style=flat-square&amp;labelColor=121214"></a>
</p>

<p align="center">
  <a href="https://github.com/funpin/B-SPACE/releases/latest"><b>Download</b></a> ·
  <a href="#quick-start"><b>Quick start</b></a> ·
  <a href="#meet-b">Meet B</a> ·
  <a href="#how-the-fork-differs-from-the-original">Fork differences</a> ·
  <a href="docs/systems">How it works</a> ·
  <a href="README.md">Русский</a>
</p>

<p align="center"><img src="docs/screenshots/chat.webp" alt="A B:SPACE text channel: channel list, messages with reactions and a code block, members online" width="100%"></p>

## Features

| | |
|---|---|
| **Voice and video** | Channels and calls in direct messages. Volume from 0 to 200 % per person and per stream, RNNoise noise suppression, live connection stats. |
| **Screen sharing** | Resolution, frame rate, codec (VP9 or hardware H.264) and bitrate are yours to pick, up to 4K at 120 fps within the limits the admin sets. System audio goes along with the picture. |
| **Chat** | Channels and categories, replies, reactions, mentions, stickers, attachments, link previews, code highlighting, message search with filters. |
| **Direct messages** | One-on-one and groups of up to 10, calls, friends and friend requests. |
| **Roles and moderation** | Role permissions with category and channel overrides, bans with a reason, server mute and deafen, join requests. |
| **Federation** | Independent servers link up: friends, DMs and calls work across servers, and each server stays with its owner. |
| **Where it runs** | Browser, Windows and macOS app, phone as an installable web app. |

## The "Kamen" interface

Graphite surfaces with no tint, and colour only where it means something: unread, a mention, live, speaking. Content sits on matte panels; whatever floats above it is dense glass. Onest type, Lucide icons.

<table>
  <tr>
    <td colspan="2"><img src="docs/screenshots/voice-screen-share.webp" alt="Voice channel: a screen share in focus, the other streams and members in the strip below, call chat messages on top"><br><sub><b>Voice channel</b>: a stream in focus, the other screens and members in the strip, call chat over the picture</sub></td>
  </tr>
  <tr>
    <td width="72%" valign="top"><img src="docs/screenshots/appearance-accent-themes.webp" alt="Appearance settings: six accent themes, Emerald selected"><br><sub><b>Appearance</b>: six accent themes, Lavender, Emerald, Amber, Ice, Rose and Mono</sub></td>
    <td width="28%" valign="top"><img src="docs/screenshots/mobile-chat.webp" alt="Chat on a phone"><br><sub><b>Phone</b>: the same client as a web app</sub></td>
  </tr>
</table>

## Meet B

<p align="center"><img src="assets/brand/b-space/animated/states-row.svg" alt="All of B's states in a row: blinking, looking around, new message, typing, speaking, screen sharing, joy, do not disturb, offline" width="100%"></p>

The B:SPACE mark is a **B made of two speech bubbles**: the top one speaks, the bottom one answers. The top bubble has eyes, so the mark is also a character. It shows feelings with its eyes and movement only, never a mouth or brows. B greets you on the sign-in screen and in the interface's empty states, and in the tray (the macOS menu bar, the Windows taskbar) it shows what is going on: unread messages, a screen share, Do Not Disturb, no connection.

| | State | When | Motion |
|:---:|---|---|---|
| <img src="assets/brand/b-space/animated/blink.svg" width="56" alt=""> | **Idle** | By default | Blinks every 3–4 s |
| <img src="assets/brand/b-space/animated/look.svg" width="56" alt=""> | **Looking around** | Loading, connecting, searching | Looks left, then right |
| <img src="assets/brand/b-space/animated/notify.svg" width="56" alt=""> | **New message** | Unread, mention | Hops, eyes widen, red dot |
| <img src="assets/brand/b-space/animated/typing.svg" width="56" alt=""> | **Typing** | Someone is typing | Looks down, dots in the body run in turn |
| <img src="assets/brand/b-space/animated/voice.svg" width="56" alt=""> | **Speaking** | Voice channel, the user is talking | Body pulses, green ring |
| <img src="assets/brand/b-space/animated/screen.svg" width="56" alt=""> | **Screen sharing** | The user is sharing their screen | Body turns into a screen, a red dot blinks in the corner |
| <img src="assets/brand/b-space/animated/joy.svg" width="56" alt=""> | **Joy** | Message sent, signed in | "^ ^" eyes, a single hop |
| <img src="assets/brand/b-space/animated/dnd.svg" width="56" alt=""> | **Do not disturb** | Do Not Disturb or Away status | Eyes closed |
| <img src="assets/brand/b-space/animated/offline.svg" width="56" alt=""> | **Offline** | Server unreachable | Grey, "× ×" eyes |

The tray uses five of them (idle, new message, screen sharing, Do Not Disturb and offline); there the icon is static and only switches frames. With "Reduce motion" on in the system, B stays still. Mark files, usage rules and colours are in [assets/brand/b-space](assets/brand/b-space/README.md) (in Russian).

## How the fork differs from the original

| | |
|---|---|
| **Name and look** | Its own logo and character, its own "Kamen" interface with selectable accent themes. |
| **App builds** | Two, nothing extra: **Windows x64** (installer) and **macOS Apple Silicon** (DMG). Linux, Windows on ARM and Intel Macs are not built here; the [original project](https://github.com/TheZwiss/backspace/releases) releases them. |
| **Links and updates** | The app, the Download panel and the update check point to this repository, not the original: the versions diverge, and the source has to be the code that actually runs (AGPL, section 13). |
| **Server** | Its own Docker image (`ghcr.io/funpin/backspace`) and three optional settings: only admins create spaces, attachment retention, thumbnails off. |
| **Voice channel** | One tile per person instead of two, members without video in a strip under the grid, tiles can be hidden and rearranged. |

Since 2.0.0 the fork is maintained independently: it grew out of the original 1.11.0 and no longer pulls the original in wholesale. Individual fixes are carried over one at a time when they are needed.

## Quick start

**App.** Download a build from the [latest release](https://github.com/funpin/B-SPACE/releases/latest): **Windows**, the installer; **macOS (Apple Silicon)**, the DMG. On first launch, enter your server's address. Install a new version over the old one: your sign-in and settings are kept.

**Server.** You need a Linux host with Docker and a domain:

```bash
git clone https://github.com/funpin/B-SPACE.git backspace && cd backspace
./install.sh
```

The installer sets up `.env`, secrets, HTTPS and, if you want it, voice. The first user to register becomes the admin. Update with `./update.sh`; back up and restore with `./backup.sh` and `./restore.sh`.

Running behind your own reverse proxy or a tunnel, ports and voice are covered in the [deployment docs](docs/systems/deployment.md) and the [original README](https://github.com/TheZwiss/backspace#installation).

<details>
<summary><b>How it works</b></summary>

- **Server**: Node.js, Fastify, SQLite through Drizzle; one container, data in `data/`.
- **Client**: React, Vite, Tailwind, Zustand; the "Kamen" interface, graphite matte panels for content and dense glass for whatever floats above it.
- **Voice and video**: LiveKit; the server only issues tokens, media goes through the SFU.
- **App**: Electron, with global shortcuts, launch at login, the character in the tray, game detection.
- **Federation**: server-to-server requests are HMAC-signed, events are delivered through a retrying queue.

Each subsystem is documented in [docs/systems](docs/systems): [voice](docs/systems/voice.md), [federation](docs/systems/federation.md), [permissions](docs/systems/permissions.md), [database](docs/systems/database.md), [desktop app](docs/systems/desktop.md), [design system](docs/systems/design-system.md). The brandbook is in [docs/brand](docs/brand/brandbook.md).
</details>

<details>
<summary><b>Development</b></summary>

Node.js 22.12 or newer (`.nvmrc` pins 24) and pnpm 10:

```bash
pnpm install
cp .env.example .env    # set JWT_SECRET: openssl rand -hex 32
pnpm dev                # server on :3005, client on :5173
pnpm typecheck && pnpm test
```

Screens can be looked at without a server or a call: the `packages/web/dev-*.html` pages are served by the same dev server, for example `http://localhost:5173/dev-voice-grid.html`.

How the fork is run:

- `origin` is this repository, `upstream` is the original. Work happens on `feat/…`, `fix/…`, `chore/…` branches off `main` and lands in `main` through a pull request.
- The original is not pulled in wholesale. A fix needed from there comes over in its own pull request (`git cherry-pick` from `upstream`), checked against our code.
- Versions are our own, plain semver: `2.0.0`, `2.1.0`, `2.0.1`. Bump with `node scripts/bump-version.mjs 2.1.0`. Releases before 2.0.0 were named after the original (`1.11.0-f.1.1` means "revision 1.1 on top of the original 1.11.0").
- A release is a `v<version>` tag on `main`: the [workflow](.github/workflows/release.yml) builds both apps and drafts a release with a download table.

Rules for the coding agent are in [CLAUDE.md](CLAUDE.md), contributing in [CONTRIBUTING.md](CONTRIBUTING.md).
</details>

## License

[GNU AGPL-3.0](LICENSE): use, change and share it freely, as long as your changes stay open too. B:SPACE is a fork of [Backspace](https://github.com/TheZwiss/backspace) © TheZwiss and contributors; the original also offers a [commercial license](LICENSE-COMMERCIAL.md), which covers the original code and is granted by its author. The Onest typeface in the logo wordmark is SIL OFL 1.1.

Fork changes © 2026 funpin
