#!/usr/bin/env bash
# Builds WebKitProbe, wraps it in an application bundle and runs it.
#
# The bundle matters: WebKit reads the capture usage descriptions and the App
# Transport Security policy from the Info.plist of the running application, so
# a bare executable measures something else than the app will be.
#
# Usage:
#   scripts/probe.sh [bundle options] -- <WebKitProbe options>
#
# Bundle options:
#   --ats none|local|web-content|arbitrary
#         none         no NSAppTransportSecurity key at all (default)
#         local        NSAllowsLocalNetworking
#         web-content  NSAllowsArbitraryLoadsInWebContent
#         arbitrary    NSAllowsArbitraryLoads
#   --no-capture-keys  leave the microphone and camera usage descriptions out
#   --build-only       build and assemble the bundle, do not run it
#
# WebKitProbe options are listed in Sources/ProbeSupport/ProbeOptions.swift.
# Example:
#   scripts/probe.sh -- --url http://localhost:8787/zoom.html \
#     --call "window.runProbe()" --out /tmp/zoom.json

set -euo pipefail
# Resolved before the cd below: $0 may be relative to the caller's directory.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SELF")/.."

ATS="none"
CAPTURE_KEYS=true
BUILD_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ats)
      [[ $# -ge 2 ]] || { echo "probe.sh: --ats needs a value" >&2; exit 64; }
      ATS="$2"
      shift
      ;;
    --no-capture-keys) CAPTURE_KEYS=false ;;
    --build-only) BUILD_ONLY=true ;;
    --help|-h)
      sed -n '2,24p' "$SELF" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "probe.sh: unknown option $1 (WebKitProbe options go after --)" >&2
      exit 64
      ;;
  esac
  shift
done

case "$ATS" in
  none) ATS_XML="" ;;
  local) ATS_XML="<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>" ;;
  web-content) ATS_XML="<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>" ;;
  arbitrary) ATS_XML="<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>" ;;
  *)
    echo "probe.sh: --ats takes none, local, web-content or arbitrary" >&2
    exit 64
    ;;
esac

CAPTURE_XML=""
if [[ "$CAPTURE_KEYS" == true ]]; then
  CAPTURE_XML="<key>NSMicrophoneUsageDescription</key><string>WebKitProbe measures how WebKit exposes capture devices.</string><key>NSCameraUsageDescription</key><string>WebKitProbe measures how WebKit exposes capture devices.</string>"
fi

swift build -c release --product WebKitProbe >&2

# One bundle per Info.plist variant, so a run never reuses another variant's
# cached policy.
VARIANT="ats-${ATS}"
[[ "$CAPTURE_KEYS" == true ]] || VARIANT="${VARIANT}-nocapture"
APP=".build/probe/${VARIANT}/WebKitProbe.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/WebKitProbe "$APP/Contents/MacOS/WebKitProbe"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.backspace.desktop.probe</string>
  <key>CFBundleName</key><string>WebKitProbe</string>
  <key>CFBundleExecutable</key><string>WebKitProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.0</string>
  <key>CFBundleVersion</key><string>0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  ${CAPTURE_XML}
  ${ATS_XML}
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >&2
# Ad-hoc signature over the finished bundle, so the Info.plist is bound to it.
codesign --force --sign - "$APP" >&2

if [[ "$BUILD_ONLY" == true ]]; then
  echo "$APP"
  exit 0
fi

exec "$APP/Contents/MacOS/WebKitProbe" "$@"
