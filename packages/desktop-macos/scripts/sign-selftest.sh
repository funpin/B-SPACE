#!/usr/bin/env bash
# Checks the certificate path of scripts/sign.sh without the project's
# certificate: makes a throwaway self-signed code-signing certificate, builds
# the development bundle signed with it, and confirms that
#   - the bundle's designated requirement names a certificate hash,
#   - the signature verifies,
#   - the keychain search list is what it was before.
#
# Usage:
#   scripts/sign-selftest.sh
#
# CI runs it on every change to this package, so the signing a release depends
# on is exercised long before a release is cut. On a developer's machine it
# adds a temporary keychain to the search list for a few seconds and removes
# it again; the login keychain is not touched.

set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPTS="$(dirname "$SELF")"

if [[ $# -gt 0 ]]; then
  sed -n '2,15p' "$SELF" | sed 's/^# \{0,1\}//'
  [[ "$1" == "--help" || "$1" == "-h" ]] && exit 0
  exit 64
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/b-space-sign-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/certificate.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = B-SPACE signing self-test (throwaway)
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG

# The system's openssl on purpose: a .p12 written by OpenSSL 3 with its default
# algorithms is one `security import` cannot read.
PASSWORD="selftest-$(/usr/bin/openssl rand -hex 8)"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$WORK/certificate.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/certificate.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/certificate.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASSWORD"

BEFORE="$(security list-keychains -d user)"

APP="$(MAC_SIGN_P12="$(base64 < "$WORK/identity.p12")" MAC_SIGN_P12_PASSWORD="$PASSWORD" MAC_SIGN_REQUIRED=1 \
  "$SCRIPTS/bundle.sh")"

AFTER="$(security list-keychains -d user)"
if [[ "$BEFORE" != "$AFTER" ]]; then
  echo "sign-selftest.sh: the keychain search list was not restored" >&2
  echo "before: $BEFORE" >&2
  echo "after:  $AFTER" >&2
  exit 1
fi

codesign --verify --strict "$APP"
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1)"
if ! printf '%s\n' "$REQUIREMENT" | grep -Eq 'certificate (leaf|root) = H"[0-9a-fA-F]{40}"'; then
  echo "sign-selftest.sh: the bundle is not signed with the certificate:" >&2
  printf '%s\n' "$REQUIREMENT" >&2
  exit 1
fi

# The bundle on disk is signed with a certificate that is about to be thrown
# away. Sign it again the ordinary way, so nobody keeps running a build whose
# identity can never be reproduced.
MAC_SIGN_P12="" MAC_SIGN_P12_PASSWORD="" MAC_SIGN_REQUIRED="" "$SCRIPTS/sign.sh" "$APP" 2>/dev/null

echo "sign-selftest.sh: certificate signing works; the bundle is ad hoc signed again"
