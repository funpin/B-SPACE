#!/usr/bin/env bash
# The signing identity of development builds on this machine.
#
# An ad hoc signature has no identity of its own: macOS tells such a build by
# the hash of its code, so every rebuild is a new application to it, and the
# microphone, Screen Recording and Input Monitoring grants of the build
# before are refused to it while the privacy lists still show them switched
# on. A build signed with a certificate is told by the certificate, which is
# the same from build to build.
#
# This makes that certificate: self-signed, for code signing, kept with its
# key in a folder of the user's own outside the repository. scripts/bundle.sh
# signs a development build with it whenever it is there. It is never used
# for a release identity, and it is no part of the project's own certificate
# (docs/systems/desktop-security.md, "Stable signing identity").
#
# Usage:
#   scripts/dev-identity.sh            make the identity unless there is one
#   scripts/dev-identity.sh --where    print the folder it is kept in
#   scripts/dev-identity.sh --remove   delete it; builds are ad hoc again
#
# The folder is ~/Library/Application Support/Backspace-Dev-Signing, or
# BSPACE_DEV_IDENTITY_DIR when that is set. The first build signed with a new
# identity is one more new application to macOS: the grants are given to it
# once, after removing the entries of the builds before
# (`tccutil reset All com.backspace.desktop.dev`), and stay from then on.
#
# Whoever can read the folder can sign code that macOS takes for the
# development build, with its grants. It is readable by its owner alone.
#
# Written for the bash 3.2 that macOS ships.

set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

DIRECTORY="${BSPACE_DEV_IDENTITY_DIR:-$HOME/Library/Application Support/Backspace-Dev-Signing}"
P12="$DIRECTORY/identity.p12"
PASSWORD_FILE="$DIRECTORY/password"

case "${1:-}" in
  "") ;;
  --where)
    echo "$DIRECTORY"
    exit 0
    ;;
  --remove)
    rm -f "$P12" "$PASSWORD_FILE"
    rmdir "$DIRECTORY" 2>/dev/null || true
    echo "dev-identity.sh: removed; development builds are signed ad hoc again" >&2
    exit 0
    ;;
  --help|-h)
    sed -n '2,29p' "$SELF" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "dev-identity.sh: unknown option $1" >&2
    exit 64
    ;;
esac

if [[ -s "$P12" && -s "$PASSWORD_FILE" ]]; then
  echo "dev-identity.sh: there is an identity already in $DIRECTORY" >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/b-space-dev-identity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
umask 077

cat > "$WORK/certificate.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = B-SPACE development build (local)
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG

# The system's openssl on purpose: a .p12 written by OpenSSL 3 with its default
# algorithms is one `security import` cannot read.
PASSWORD="$(/usr/bin/openssl rand -hex 24)"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/certificate.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/certificate.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/certificate.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASSWORD"

mkdir -p "$DIRECTORY"
chmod 700 "$DIRECTORY"
printf '%s' "$PASSWORD" > "$PASSWORD_FILE"
mv "$WORK/identity.p12" "$P12"
chmod 600 "$P12" "$PASSWORD_FILE"

echo "dev-identity.sh: made a development signing identity in $DIRECTORY" >&2
