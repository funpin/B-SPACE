#!/usr/bin/env bash
# Runs the bridge contract check: builds ContractCheck and points it at the
# contract and the picker in packages/desktop and at contract/harness.html.
# The shell under test is the real one (BSpaceShell), with no window on screen
# and its settings in a temporary folder. Before the bridge it checks the
# shell's window state on this machine's displays (--check window-state), the
# import of the Electron build's localStorage (--check local-storage-import),
# links and auto-launch settings (--check launch), notifications and the
# badge (--check notifications), the menu bar (--check menu), recovery mode
# (--check recovery), dragging the window (--check drag), the tray
# (--check tray), game detection (--check activity), the global keybinds
# (--check keybinds) and the list of what can be shared (--check sources).
#
# Usage:
#   scripts/contract-check.sh [--out <report.json>]
#
# Prints the report (or writes it to --out) and exits 0 when the bridge keeps
# the contract, 1 when it does not, 2 when the check could not run.

set -euo pipefail
# Resolved before the cd below: $0 may be relative to the caller's directory.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
OUT_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      [[ $# -ge 2 ]] || { echo "contract-check.sh: --out needs a path" >&2; exit 64; }
      # Made absolute here: the path is the caller's, the cd below is ours.
      OUT_ARGS=(--out "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")")
      shift
      ;;
    --help|-h)
      sed -n '2,11p' "$SELF" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "contract-check.sh: unknown option $1" >&2
      exit 64
      ;;
  esac
  shift
done

cd "$(dirname "$SELF")/.."
DESKTOP="$(cd ../desktop && pwd)"

swift build -c release --product ContractCheck >&2

# The shell's window, on this machine's displays: restored from
# window-state.json, written back after a move, centred when its place is gone.
.build/release/ContractCheck \
  --contract "$DESKTOP/src/bridgeContract.json" \
  --picker "$DESKTOP/resources/instance-picker.html" \
  --strings "$DESKTOP/src/desktopStrings.json" \
  --recovery "$DESKTOP/resources/recovery.html" \
  --check window-state >&2

# The import of the Electron build's localStorage, from the fixture profile the
# tests read, into a data store that is never written to disk.
.build/release/ContractCheck \
  --contract "$DESKTOP/src/bridgeContract.json" \
  --picker "$DESKTOP/resources/instance-picker.html" \
  --strings "$DESKTOP/src/desktopStrings.json" \
  --recovery "$DESKTOP/resources/recovery.html" \
  --check local-storage-import \
  --fixture "$PWD/Tests/BSpaceCoreTests/Fixtures/chromium-local-storage/leveldb" >&2

# What reaches the page from outside the app: backspace:// links, held until
# the page listens for them, and the auto-launch settings.
.build/release/ContractCheck \
  --contract "$DESKTOP/src/bridgeContract.json" \
  --picker "$DESKTOP/resources/instance-picker.html" \
  --strings "$DESKTOP/src/desktopStrings.json" \
  --recovery "$DESKTOP/resources/recovery.html" \
  --check launch >&2

# Notifications and the Dock badge, on a page served from the loopback
# address. No notification is shown.
.build/release/ContractCheck \
  --contract "$DESKTOP/src/bridgeContract.json" \
  --picker "$DESKTOP/resources/instance-picker.html" \
  --strings "$DESKTOP/src/desktopStrings.json" \
  --recovery "$DESKTOP/resources/recovery.html" \
  --check notifications >&2

# The menu bar in every language, and the language following the web client.
.build/release/ContractCheck \
  --contract "$DESKTOP/src/bridgeContract.json" \
  --picker "$DESKTOP/resources/instance-picker.html" \
  --strings "$DESKTOP/src/desktopStrings.json" \
  --recovery "$DESKTOP/resources/recovery.html" \
  --check menu >&2

# Recovery mode, with its clocks shortened: a failed load, a web client that
# never starts and a page that stops answering all end on the recovery page.
.build/release/ContractCheck \
  --contract "$DESKTOP/src/bridgeContract.json" \
  --picker "$DESKTOP/resources/instance-picker.html" \
  --strings "$DESKTOP/src/desktopStrings.json" \
  --recovery "$DESKTOP/resources/recovery.html" \
  --check recovery >&2

# Dragging the window: by the top strip of a page that reported nothing, then
# by what the page reports; the page sees nothing of a press that drags.
.build/release/ContractCheck \
  --contract "$DESKTOP/src/bridgeContract.json" \
  --picker "$DESKTOP/resources/instance-picker.html" \
  --strings "$DESKTOP/src/desktopStrings.json" \
  --recovery "$DESKTOP/resources/recovery.html" \
  --check drag >&2

# The tray: the character plays the state the page reports, the menu offers
# the controls the page allows and sends the chosen one back.
.build/release/ContractCheck \
  --contract "$DESKTOP/src/bridgeContract.json" \
  --picker "$DESKTOP/resources/instance-picker.html" \
  --strings "$DESKTOP/src/desktopStrings.json" \
  --recovery "$DESKTOP/resources/recovery.html" \
  --check tray >&2

# Game detection, with a made-up list of processes and a made-up answer of
# the network: nothing real is listed and nothing is fetched.
.build/release/ContractCheck \
  --contract "$DESKTOP/src/bridgeContract.json" \
  --picker "$DESKTOP/resources/instance-picker.html" \
  --strings "$DESKTOP/src/desktopStrings.json" \
  --recovery "$DESKTOP/resources/recovery.html" \
  --check activity >&2

# Global keybinds, with a made-up keyboard and a made-up permission: no real
# key is listened to.
.build/release/ContractCheck \
  --contract "$DESKTOP/src/bridgeContract.json" \
  --picker "$DESKTOP/resources/instance-picker.html" \
  --strings "$DESKTOP/src/desktopStrings.json" \
  --recovery "$DESKTOP/resources/recovery.html" \
  --check keybinds >&2

# What can be shared, with a made-up list: the screen is not looked at.
.build/release/ContractCheck \
  --contract "$DESKTOP/src/bridgeContract.json" \
  --picker "$DESKTOP/resources/instance-picker.html" \
  --strings "$DESKTOP/src/desktopStrings.json" \
  --recovery "$DESKTOP/resources/recovery.html" \
  --check sources >&2

exec .build/release/ContractCheck \
  --contract "$DESKTOP/src/bridgeContract.json" \
  --picker "$DESKTOP/resources/instance-picker.html" \
  --strings "$DESKTOP/src/desktopStrings.json" \
  --recovery "$DESKTOP/resources/recovery.html" \
  --harness "$PWD/contract/harness.html" \
  ${OUT_ARGS[@]+"${OUT_ARGS[@]}"}
