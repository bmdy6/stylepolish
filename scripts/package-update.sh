#!/bin/bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
    printf 'Usage: %s <Sparkle bin directory> <Ed25519 key file> <release notes.md> <new output directory>\n' "$0" >&2
    exit 2
fi

sparkle_bin="$1"
private_key="$2"
release_notes="$3"
output="$4"
root="$(cd "$(dirname "$0")/.." && pwd -P)"
test -x "$sparkle_bin/generate_appcast"
test -x "$sparkle_bin/sign_update"
test -f "$private_key"
test -f "$release_notes"
test ! -e "$output"
output_parent="$(dirname "$output")"
mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd -P)"
stage="$(mktemp -d "$output_parent/.stylepolish-update.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/StylePolish.app"
plist="$app/Contents/Info.plist"

signing_public_key="$(swift -e '
    import CryptoKit
    import Foundation
    let keyFile = URL(fileURLWithPath: CommandLine.arguments[1])
    let encoded = try String(contentsOf: keyFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: encoded), seed.count == 32 else {
        fputs("Expected a base64-encoded 32-byte Ed25519 seed.\n", stderr)
        exit(2)
    }
    print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        .publicKey.rawRepresentation.base64EncodedString())
' "$private_key")"
STYLEPOLISH_UPDATE_PUBLIC_KEY="$signing_public_key" "$root/scripts/build-app.sh" "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")" = "$signing_public_key"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Expected a stable three-part release version in the app.\n' >&2
    exit 1
fi
architecture="$(lipo -archs "$app/Contents/MacOS/StylePolish" | tr ' ' '-')"
filename="StylePolish-$version-macOS-$architecture"
mkdir "$stage/feed"

ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/feed/$filename.zip"
cp "$release_notes" "$stage/feed/$filename.md"
"$sparkle_bin/generate_appcast" \
    --ed-key-file "$private_key" \
    --download-url-prefix "https://github.com/bmdy6/stylepolish/releases/download/v$version/" \
    --link "https://github.com/bmdy6/stylepolish/releases/tag/v$version" \
    --embed-release-notes \
    --maximum-deltas 0 \
    "$stage/feed"
"$sparkle_bin/sign_update" --verify --ed-key-file "$private_key" "$stage/feed/appcast.xml"
mkdir "$output"
mv "$stage/feed/$filename.zip" "$stage/feed/appcast.xml" "$output/"
printf 'Update artifacts are ready in %s\n' "$output"
