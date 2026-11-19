# Sourced by the scripts that build what links LiveKit's library (bundle.sh,
# contract-check.sh): makes `swift` Xcode's.
#
# The library compiles with the Command Line Tools' toolchain too, and what
# that builds crashes the moment a share joins a call (seen with Swift 6.1.2
# against the macOS 15.5 SDK; Xcode 27.2's Swift 6.4.2 is fine). A build that
# works until it is used is worse than one that does not start, so a machine
# whose selected developer directory is the Command Line Tools is pointed at
# Xcode for the length of the script, and one without Xcode is told so.
#
# DEVELOPER_DIR, when already set, is left alone: CI and anyone who knows
# better choose for themselves.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  case "$(xcode-select -p 2>/dev/null || true)" in
    */CommandLineTools*|"")
      if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
      else
        echo "$(basename "${SELF:-$0}"): this package has to be built with Xcode's toolchain," \
          "and the selected developer directory is the Command Line Tools." \
          "Install Xcode, or set DEVELOPER_DIR to one." >&2
        exit 1
      fi
      ;;
  esac
fi
