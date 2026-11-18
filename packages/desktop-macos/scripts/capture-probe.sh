#!/usr/bin/env bash
# Builds CaptureProbe, wraps it in two application bundles and runs it.
#
# Two bundles from one executable: CaptureProbe.app records, and
# CaptureProbeTone.app, under another identifier, is "some other application"
# whose sound every recording has to keep.
#
# The bundle matters, and so does the way it is started. Which processes the
# system counts as "this application" when a capture excludes it follows the
# process that is responsible for them. Started from a terminal, the probe and
# WebKit's helpers answer to the terminal's application; started through
# LaunchServices (--open) they answer to the probe itself, as the client's
# will. Only an --open run says what the client will get.
#
# The probe plays quiet tones for about half a minute and needs the Screen
# Recording permission: the terminal's without --open, its own with it.
#
# Usage:
#   scripts/capture-probe.sh [--build-only] [--open] [-- <CaptureProbe options>]
#
#   --build-only  build and assemble the bundles, print the probe's path
#   --open        start the probe through LaunchServices; the report goes to
#                 .build/capture-probe/report.json and is printed at the end
#
# CaptureProbe options: --request-permission, --regular, --gain, --seconds, --out.

set -euo pipefail
# Resolved before the cd below: $0 may be relative to the caller's directory.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SELF")/.."

BUILD_ONLY=false
OPEN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) BUILD_ONLY=true ;;
    --open) OPEN=true ;;
    --help|-h)
      sed -n '2,25p' "$SELF" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "capture-probe.sh: unknown option $1 (CaptureProbe options go after --)" >&2
      exit 64
      ;;
  esac
  shift
done

swift build -c release --product CaptureProbe >&2

OUT="$PWD/.build/capture-probe"

# bundle <name> <identifier>
bundle() {
  local app="$OUT/$1.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp .build/release/CaptureProbe "$app/Contents/MacOS/CaptureProbe"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundleExecutable</key><string>CaptureProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.0</string>
  <key>CFBundleVersion</key><string>0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
  plutil -lint "$app/Contents/Info.plist" >&2
  # Ad-hoc signature over the finished bundle, so the Info.plist is bound to it.
  codesign --force --sign - "$app" >&2
}

bundle CaptureProbe com.backspace.desktop.probe.capture
bundle CaptureProbeTone com.backspace.desktop.probe.tone

APP="$OUT/CaptureProbe.app"
TONE="$OUT/CaptureProbeTone.app"

if [[ "$BUILD_ONLY" == true ]]; then
  echo "$APP"
  exit 0
fi

if [[ "$OPEN" == true ]]; then
  REPORT="$OUT/report.json"
  rm -f "$REPORT"
  # -W waits for the probe to exit; -n starts a fresh copy; -g keeps it behind.
  open -W -n -g "$APP" --args --companion "$TONE" --out "$REPORT" "$@"
  cat "$REPORT"
  exit 0
fi

exec "$APP/Contents/MacOS/CaptureProbe" --companion "$TONE" "$@"
