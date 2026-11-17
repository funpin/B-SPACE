#!/usr/bin/env bash
# Runs the bridge contract check: builds ContractCheck and points it at the
# contract and the picker in packages/desktop and at contract/harness.html.
# The shell under test is the real one (BSpaceShell), with no window on screen
# and its settings in a temporary folder. Before the bridge it checks the
# shell's window state on this machine's displays (--check window-state) and
# the import of the Electron build's localStorage (--check local-storage-import).
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
  --check window-state >&2

# The import of the Electron build's localStorage, from the fixture profile the
# tests read, into a data store that is never written to disk.
.build/release/ContractCheck \
  --contract "$DESKTOP/src/bridgeContract.json" \
  --picker "$DESKTOP/resources/instance-picker.html" \
  --check local-storage-import \
  --fixture "$PWD/Tests/BSpaceCoreTests/Fixtures/chromium-local-storage/leveldb" >&2

exec .build/release/ContractCheck \
  --contract "$DESKTOP/src/bridgeContract.json" \
  --picker "$DESKTOP/resources/instance-picker.html" \
  --harness "$PWD/contract/harness.html" \
  ${OUT_ARGS[@]+"${OUT_ARGS[@]}"}
