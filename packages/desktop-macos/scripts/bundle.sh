#!/usr/bin/env bash
# Builds the native macOS client and assembles its application bundle.
#
# Usage:
#   scripts/bundle.sh [options]
#
# Options:
#   --identity dev|release
#         dev (default)  a build to try a branch with. Its own bundle
#                        identifier (com.backspace.desktop.dev) and its own
#                        settings folder (Application Support/Backspace-Dev),
#                        and it does not claim the backspace:// scheme. It can
#                        run beside the installed app without touching that
#                        app's sign-in, settings or web storage.
#         release        the identity of the shipped app: com.backspace.desktop,
#                        Application Support/Backspace, the backspace:// scheme.
#                        This is what replaces the Electron build.
#   --run                start the bundle after building it, in the foreground
#   --help               this text
#
# The version comes from the root package.json. The picker page, the bridge
# contract, the strings and the icon are taken from packages/desktop, which
# owns them for both shells. Prints the path of the bundle on standard output.
#
# Signing is scripts/sign.sh: with MAC_SIGN_P12 and MAC_SIGN_P12_PASSWORD in
# the environment the bundle is signed with that certificate, otherwise ad hoc;
# MAC_SIGN_REQUIRED=1 refuses the ad hoc fallback.

set -euo pipefail
# Resolved before the cd below: $0 may be relative to the caller's directory.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SELF")/.."

IDENTITY="dev"
RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)
      [[ $# -ge 2 ]] || { echo "bundle.sh: --identity needs a value" >&2; exit 64; }
      IDENTITY="$2"
      shift
      ;;
    --run) RUN=true ;;
    --help|-h)
      sed -n '2,27p' "$SELF" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "bundle.sh: unknown option $1" >&2
      exit 64
      ;;
  esac
  shift
done

case "$IDENTITY" in
  dev)
    BUNDLE_ID="com.backspace.desktop.dev"
    BUNDLE_NAME="B-SPACE Dev"
    DISPLAY_NAME="B:SPACE Dev"
    USER_DATA_XML="<key>BSpaceUserDataDirectory</key><string>Backspace-Dev</string>"
    URL_SCHEME_XML=""
    ;;
  release)
    BUNDLE_ID="com.backspace.desktop"
    BUNDLE_NAME="B-SPACE"
    DISPLAY_NAME="B:SPACE"
    USER_DATA_XML=""
    URL_SCHEME_XML="<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>B:SPACE</string><key>CFBundleTypeRole</key><string>Editor</string><key>CFBundleURLSchemes</key><array><string>backspace</string></array></dict></array>"
    ;;
  *)
    echo "bundle.sh: --identity takes dev or release" >&2
    exit 64
    ;;
esac

DESKTOP="../desktop"
VERSION="$(sed -n 's/^  "version": "\(.*\)",$/\1/p' ../../package.json | head -n 1)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "bundle.sh: could not read a plain version from the root package.json (got \"$VERSION\")" >&2
  exit 1
fi
for resource in "$DESKTOP/resources/instance-picker.html" "$DESKTOP/resources/recovery.html" "$DESKTOP/src/bridgeContract.json" "$DESKTOP/src/desktopStrings.json" "$DESKTOP/resources/games.json" "$DESKTOP/build/icon.icns"; do
  [[ -f "$resource" ]] || { echo "bundle.sh: $resource is missing" >&2; exit 1; }
done

swift build -c release --product BSpaceApp >&2

EXECUTABLE="B-SPACE"
APP=".build/app/${IDENTITY}/B-SPACE.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BSpaceApp "$APP/Contents/MacOS/$EXECUTABLE"
cp "$DESKTOP/resources/instance-picker.html" "$APP/Contents/Resources/instance-picker.html"
cp "$DESKTOP/resources/recovery.html" "$APP/Contents/Resources/recovery.html"
cp "$DESKTOP/src/bridgeContract.json" "$APP/Contents/Resources/bridgeContract.json"
cp "$DESKTOP/build/icon.icns" "$APP/Contents/Resources/icon.icns"
# The games recognised by their process names.
cp "$DESKTOP/resources/games.json" "$APP/Contents/Resources/games.json"
# The frames of the character in the menu bar: black templates, with their
# @2x files beside them, which the system tints for the menu bar's colour.
TRAY_FRAMES=0
for frame in "$DESKTOP"/resources/tray-*Template.png "$DESKTOP"/resources/tray-*Template@2x.png; do
  cp "$frame" "$APP/Contents/Resources/"
  TRAY_FRAMES=$((TRAY_FRAMES + 1))
done
if [[ "$TRAY_FRAMES" -ne 32 ]]; then
  echo "bundle.sh: expected 32 tray frame images (16 frames, each with @2x), found $TRAY_FRAMES" >&2
  exit 1
fi
# What the shell says on its own (menus), in every language of the web client.
cp "$DESKTOP/src/desktopStrings.json" "$APP/Contents/Resources/desktop-strings.json"
# The texts of the system's permission prompts, from the same catalog: one
# <language>.lproj/InfoPlist.strings per language in the bundle, and the
# English ones for the Info.plist below, which must name every permission.
PERMISSION_XML="$(swift "$(dirname "$SELF")/permission-texts.swift" "$DESKTOP/src/desktopStrings.json" "$APP/Contents/Resources")"
[[ -n "$PERMISSION_XML" ]] || { echo "bundle.sh: no permission texts were written" >&2; exit 1; }
for localization in "$APP"/Contents/Resources/*.lproj; do
  plutil -lint "$localization/InfoPlist.strings" >&2
done

# The keys of the Electron build's Info.plist that carry over (pre-audit, 4.2).
# App Transport Security: an instance reached over http:// by a domain name
# loads only with NSAllowsArbitraryLoads; addresses and localhost load anyway.
# NSAllowsLocalNetworking must NOT stand beside it, although the Electron
# build has both: when that key is present the system ignores
# NSAllowsArbitraryLoads, and http:// by name is blocked again. Chromium has
# its own network stack and never noticed; WKWebView uses the system's
# (measured: pre-audit, 2.7).
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>${BUNDLE_NAME}</string>
  <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
  <key>CFBundleIconFile</key><string>icon.icns</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRequiresAquaSystemAppearance</key><false/>
  <key>NSQuitAlwaysKeepsWindows</key><false/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
${PERMISSION_XML}
  ${USER_DATA_XML}
  ${URL_SCHEME_XML}
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >&2

# Signed last, over the finished bundle, so the Info.plist and the resources
# are bound to the signature.
"$(dirname "$SELF")/sign.sh" "$APP"

APP_PATH="$PWD/$APP"
echo "$APP_PATH"
if [[ "$RUN" == true ]]; then
  exec "$APP_PATH/Contents/MacOS/$EXECUTABLE"
fi
