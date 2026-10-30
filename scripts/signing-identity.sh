#!/bin/bash
# Creates (once) a self-signed code-signing identity in a dedicated keychain,
# so macOS keeps MacSnap's Screen Recording / Accessibility grants across
# rebuilds. Ad-hoc signatures change with every build and lose them.
# Prints the keychain path on success.
set -euo pipefail
KC="$HOME/Library/Keychains/macsnap-signing.keychain-db"
PASS="macsnap-local"
NAME="MacSnap Local Signing"

if [ ! -f "$KC" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
  # The system LibreSSL writes PKCS#12 files that `security import` accepts.
  OPENSSL=/usr/bin/openssl
  $OPENSSL req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/cfg" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1
  $OPENSSL pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/id.p12" -passout pass:$PASS >/dev/null 2>&1
  security create-keychain -p "$PASS" "$KC"
  security set-keychain-settings "$KC"   # no auto-lock
  security unlock-keychain -p "$PASS" "$KC"
  security import "$tmp/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null
fi
security unlock-keychain -p "$PASS" "$KC"
echo "$KC"
