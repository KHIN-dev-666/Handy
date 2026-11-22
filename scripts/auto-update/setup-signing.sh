#!/bin/bash
# One-time setup: create the self-signed "Handy Local Signing" code-signing identity in a
# dedicated keychain (~/Library/Application Support/handy-auto-update/signing/).
# The keychain password is random, stored next to it (mode 600), and only protects this
# throwaway signing key, so codesign can run unattended from launchd. Safe to re-run:
# it does nothing if the identity already exists.
set -eu
LOG_TAG=setup
. "$(dirname "$0")/common.sh"
LOG_FILE="$LOG_DIR/setup-signing.log"

mkdir -p "$SIGN_DIR"
chmod 700 "$SIGN_DIR"
cd "$SIGN_DIR"
if [ -f "$SIGN_KEYCHAIN" ] && security find-identity -p codesigning "$SIGN_KEYCHAIN" | grep -q "\"$SIGN_NAME\""; then
    echo "Identity \"$SIGN_NAME\" already exists in $SIGN_KEYCHAIN"
    exit 0
fi
[ -f keychain-password ] || (umask 077; /usr/bin/openssl rand -hex 24 >keychain-password)
PW=$(cat keychain-password)
cat >cert.cnf <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Handy Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
umask 077
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 7300 -config cert.cnf 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:"$PW" -name "$SIGN_NAME"
[ -f "$SIGN_KEYCHAIN" ] || security create-keychain -p "$PW" "$SIGN_KEYCHAIN"
security set-keychain-settings "$SIGN_KEYCHAIN"
security unlock-keychain -p "$PW" "$SIGN_KEYCHAIN"
security import id.p12 -k "$SIGN_KEYCHAIN" -P "$PW" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$SIGN_KEYCHAIN" >/dev/null
rm -f key.pem id.p12
security find-identity -p codesigning "$SIGN_KEYCHAIN"
log "Created signing identity $SIGN_NAME"
echo "Back up $SIGN_DIR: losing it means one more manual Accessibility grant on each Mac."
