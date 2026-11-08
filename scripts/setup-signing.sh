#!/bin/bash
set -euo pipefail
umask 077
SIGNING_KEYCHAIN="$HOME/Library/Keychains/stylepolish-signing.keychain-db"
SIGNING_PASS_FILE="$HOME/.config/stylepolish/signing-pass"
# Dedicated signing-only keychain: empty passphrase, never login/system keychain.
# Migrate the previous machine-generated passphrase without asking the user.
if [ ! -f "$SIGNING_KEYCHAIN" ]; then
    security create-keychain -p "" "$SIGNING_KEYCHAIN"
elif [ -f "$SIGNING_PASS_FILE" ]; then
    security set-keychain-password -o "$(cat "$SIGNING_PASS_FILE")" -p "" "$SIGNING_KEYCHAIN"
fi
rm -f "$SIGNING_PASS_FILE"
SIGNING_PASS=""
security unlock-keychain -p "$SIGNING_PASS" "$SIGNING_KEYCHAIN"
security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN"
if ! security find-certificate -c 'StylePolish Local' "$SIGNING_KEYCHAIN" >/dev/null 2>&1; then
    SIGNING_TMP="$(mktemp -d)"
    trap 'rm -rf "$SIGNING_TMP"' EXIT
    cat > "$SIGNING_TMP/cert.cnf" <<'CONF'
[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=StylePolish Local
[extensions]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CONF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$SIGNING_TMP/cert.cnf" -keyout "$SIGNING_TMP/key.pem" -out "$SIGNING_TMP/cert.pem" >/dev/null 2>&1
    # macOS rejects empty-password PKCS#12 containers on fresh CI machines.
    # Import the unencrypted PEM key and certificate directly, without a container password.
    security import "$SIGNING_TMP/key.pem" -k "$SIGNING_KEYCHAIN" -T /usr/bin/codesign >/dev/null
    security import "$SIGNING_TMP/cert.pem" -k "$SIGNING_KEYCHAIN" >/dev/null
fi
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$SIGNING_PASS" "$SIGNING_KEYCHAIN" >/dev/null
printf 'Dedicated signing keychain ready.\n'
