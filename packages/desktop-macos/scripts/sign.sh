#!/usr/bin/env bash
# Signs an application bundle. A port of packages/desktop/scripts/macSign.js,
# which signs the Electron build; the reasons are told there in full.
#
# Usage:
#   scripts/sign.sh <path to .app>
#
# Which signature:
#   With MAC_SIGN_P12 (base64 of a .p12) and MAC_SIGN_P12_PASSWORD set, the
#   bundle is signed with that certificate: the project's self-signed
#   code-signing identity (docs/systems/desktop-security.md, "Stable signing
#   identity"). Its designated requirement then names the certificate's hash,
#   which every later build signed with the same certificate satisfies. That is
#   what lets macOS keep the microphone, Screen Recording and Input Monitoring
#   grants across updates, and lets an update replace the app in place.
#
#   Without them the signature is ad hoc: it has no stable identity, so macOS
#   drops the grants on every update. MAC_SIGN_REQUIRED=1 (set where a release
#   is built) turns that fallback into a failure, because one ad hoc release
#   would strand every installed copy on it.
#
# The certificate goes into a throwaway keychain that only codesign may use.
# The login keychain is not touched, and the keychain search list is put back
# exactly as it was, whether signing succeeds or not.
#
# Written for the bash 3.2 that macOS ships.

set -euo pipefail

if [[ $# -ne 1 || "$1" == "--help" || "$1" == "-h" ]]; then
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  [[ $# -eq 1 ]] && exit 0
  exit 64
fi

APP="$1"
[[ -d "$APP" ]] || { echo "sign.sh: $APP is not an application bundle" >&2; exit 1; }

# A certificate hash in the designated requirement marks a stable identity.
# codesign anchors a self-signed certificate as `certificate root` (the leaf is
# its own root) and a chained one as `certificate leaf`.
STABLE_REQUIREMENT='certificate (leaf|root) = H"[0-9a-fA-F]{40}"'

# Code inside the bundle is signed before the bundle: a signature over the app
# seals what its frameworks' signatures are, so they have to exist first, and
# the system refuses to load a framework signed by somebody else into a
# hardened app. The frameworks are LiveKit's library (bundle.sh puts them in).
# The arguments are codesign's: the identity, then anything that goes with it.
sign_frameworks() {
  local identity="$1"
  shift
  local framework
  for framework in "$APP"/Contents/Frameworks/*.framework; do
    [[ -d "$framework" ]] || continue
    codesign --force --sign "$identity" "$@" --timestamp=none "$framework" >&2
  done
}

# Empty counts as unset: CI passes '' to jobs that have no access to the secret.
P12_BASE64="$(printf '%s' "${MAC_SIGN_P12:-}" | tr -d '[:space:]')"
P12_PASSWORD="${MAC_SIGN_P12_PASSWORD:-}"

if [[ -z "$P12_BASE64" && -z "$P12_PASSWORD" ]]; then
  if [[ "${MAC_SIGN_REQUIRED:-}" == "1" ]]; then
    echo "sign.sh: MAC_SIGN_REQUIRED=1 but MAC_SIGN_P12 is not set: refusing to make an ad hoc signed build," \
      "it would reset every user's macOS permissions and strand their updates" >&2
    exit 1
  fi
  echo "sign.sh: no MAC_SIGN_P12: ad hoc signing. macOS permissions will not survive the next update." >&2
  # `--sign -` never contacts a timestamp server; saying so keeps the build
  # hermetic rather than relying on that default.
  sign_frameworks -
  codesign --force --sign - --timestamp=none "$APP" >&2
  codesign --verify --deep --strict "$APP" >&2
  exit 0
fi
if [[ -z "$P12_BASE64" || -z "$P12_PASSWORD" ]]; then
  echo "sign.sh: MAC_SIGN_P12 and MAC_SIGN_P12_PASSWORD must be set together" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/b-space-sign.XXXXXX")"
KEYCHAIN="$WORK/signing.keychain-db"
P12_FILE="$WORK/identity.p12"
KEYCHAIN_PASSWORD="$(/usr/bin/openssl rand -hex 24)"
trap 'rm -rf "$WORK"' EXIT

# Decoded before anything about the keychains is read or changed, so a bad
# secret fails with nothing touched.
umask 077
if ! printf '%s' "$P12_BASE64" | base64 --decode > "$P12_FILE" 2>/dev/null || [[ ! -s "$P12_FILE" ]]; then
  echo "sign.sh: MAC_SIGN_P12 is not valid base64" >&2
  exit 1
fi

# codesign finds an identity only in a keychain on the user's search list, even
# with --keychain, so the throwaway one is added to it for the signing.
SEARCH_LIST=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  line="${line#\"}"
  line="${line%\"}"
  [[ -n "$line" ]] && SEARCH_LIST+=("$line")
done < <(security list-keychains -d user)

cleanup() {
  security list-keychains -d user -s ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"} >/dev/null 2>&1 \
    || echo "sign.sh: could not restore the keychain search list" >&2
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# No auto-lock while the build runs.
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12_FILE" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a prompt on screen.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
rm -f "$P12_FILE"
security list-keychains -d user -s "$KEYCHAIN" ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"} >/dev/null

# The self-signed certificate is listed as not trusted, which is expected:
# codesign signs with it all the same, and nothing that reads the signature
# evaluates trust, only the hash.
SHA1="$(security find-identity -p codesigning "$KEYCHAIN" | sed -n 's/^ *[0-9][0-9]*) \([0-9A-F]\{40\}\) .*/\1/p' | head -n 1)"
if [[ -z "$SHA1" ]]; then
  echo "sign.sh: MAC_SIGN_P12 holds no code-signing identity" >&2
  exit 1
fi

sign_frameworks "$SHA1" --keychain "$KEYCHAIN"
codesign --force --sign "$SHA1" --keychain "$KEYCHAIN" --timestamp=none "$APP" >&2
codesign --verify --deep --strict "$APP" >&2

# codesign writes the requirement to standard output and its remarks to
# standard error; both are kept so a failure shows everything it said.
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1)"
if ! printf '%s\n' "$REQUIREMENT" | grep -Eq "$STABLE_REQUIREMENT"; then
  echo "sign.sh: the signed bundle has no certificate-anchored requirement:" >&2
  printf '%s\n' "$REQUIREMENT" >&2
  exit 1
fi
echo "sign.sh: designated requirement pinned to certificate $SHA1" >&2
