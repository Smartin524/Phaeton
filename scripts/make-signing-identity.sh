#!/bin/bash
# One-time setup on the machine that builds Phaeton: creates "Phaeton Local Signing", a self-signed
# code-signing certificate, in your login keychain. build-app.sh signs with it when it exists.
#
# Why: macOS remembers permissions such as Accessibility by the app's designated requirement. A
# plain ad-hoc signature pins that to the exact build, so every rebuild or update silently loses the
# grant. Signing with this certificate makes the requirement "this bundle id AND this certificate",
# which survives rebuilds, yet only someone holding the private key (only this Mac) can produce a
# matching app. No Apple account, no trust settings, nothing outside your login keychain.
#
# The first build afterwards may ask to let codesign use the key: choose "Always Allow".
# Remove it again with Keychain Access (search "Phaeton Local Signing", delete the certificate and key).
set -euo pipefail
NAME="Phaeton Local Signing"
KEYCHAIN="${PHAETON_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists; nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# A throwaway password only for the hand-over to the keychain. OpenSSL 3 needs -legacy for a file
# macOS can import; LibreSSL (the system openssl) does not know the flag and does not need it.
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" \
  -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" -passout "pass:$PASS"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\" in your login keychain. build-app.sh will sign with it from now on."
echo "Accessibility must be granted once more after the first build signed this way."
