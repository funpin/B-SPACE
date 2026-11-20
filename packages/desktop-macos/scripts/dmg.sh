#!/usr/bin/env bash
# Packs an application bundle into a disk image to hand out: the application
# and a link to /Applications to drag it onto.
#
# Usage:
#   scripts/dmg.sh <path to .app> <path of the .dmg to write>
#
# The image is named after the bundle. The bundle is signed before it comes
# here (scripts/bundle.sh); the copy inside the finished image is verified, so
# an image whose application macOS would call damaged is never written.
# Prints the path of the image on standard output.
#
# Written for the bash 3.2 that macOS ships.

set -euo pipefail

if [[ $# -ne 2 || "$1" == "--help" || "$1" == "-h" ]]; then
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  [[ $# -ge 1 && ( "$1" == "--help" || "$1" == "-h" ) ]] && exit 0
  exit 64
fi

APP="$1"
OUT="$2"
[[ -d "$APP" && "$APP" == *.app ]] || { echo "dmg.sh: $APP is not an application bundle" >&2; exit 1; }
[[ "$OUT" == *.dmg ]] || { echo "dmg.sh: $OUT is not a .dmg path" >&2; exit 1; }

NAME="$(basename "$APP" .app)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/b-space-dmg.XXXXXX")"
MOUNT="$WORK/mount"
detach() { hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; }
trap 'detach; rm -rf "$WORK"' EXIT

STAGE="$WORK/$NAME"
mkdir "$STAGE"
# ditto keeps what the signature seals: the links inside the frameworks and
# the extended attributes.
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >&2

# What a user will drag out of the image, as they will get it.
mkdir "$MOUNT"
hdiutil attach "$OUT" -readonly -nobrowse -mountpoint "$MOUNT" -quiet >&2
codesign --verify --deep --strict "$MOUNT/$(basename "$APP")" >&2
[[ -L "$MOUNT/Applications" ]] || { echo "dmg.sh: the image has no link to /Applications" >&2; exit 1; }
detach

echo "$OUT"
