#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
UPDATE_PUBLIC_KEY="${STYLEPOLISH_UPDATE_PUBLIC_KEY:-}"
BUILD_NUMBER="${STYLEPOLISH_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || printf '1')}"
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    printf 'STYLEPOLISH_BUILD_NUMBER must be a positive integer.\n' >&2
    exit 1
fi
if [[ -n "$UPDATE_PUBLIC_KEY" && ! "$UPDATE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    printf 'STYLEPOLISH_UPDATE_PUBLIC_KEY must be a base64 Ed25519 public key.\n' >&2
    exit 1
fi
# Remove build-machine paths from debug data and #filePath expansions.
swift build -c release -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/StylePolish" -Xswiftc -file-prefix-map -Xswiftc "$PWD=/StylePolish"
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="${1:-dist/StylePolish.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
find "$APP/Contents/MacOS" -maxdepth 1 -name 'StylePolish_StylePolishApp.bundle' -type d -exec rm -r {} \;
# Replace the inode rather than overwrite a previously executed Mach-O file.
cp "$BIN_DIR/StylePolish" "$APP/Contents/MacOS/StylePolish.new"
mv -f "$APP/Contents/MacOS/StylePolish.new" "$APP/Contents/MacOS/StylePolish"
# Distribute the executable without local DWARF/debug paths.
strip -S "$APP/Contents/MacOS/StylePolish"
# Copy resources into the standard app location; do not ship build-machine paths.
cp Sources/StylePolishCore/Resources/local-typos.json Sources/StylePolishCore/Resources/habit-tips.json Sources/StylePolishCore/Resources/apps.json "$APP/Contents/Resources/"
cp -R Sources/StylePolishApp/Resources/prompts "$APP/Contents/Resources/"
cp .build/checkouts/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE.txt"
ICON="Sources/StylePolishApp/Resources/AppIcon.icns"
if [ -f "$ICON" ]; then
    cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
else
    rm -f "$APP/Contents/Resources/AppIcon.icns"
    printf 'Warning: AppIcon.icns is missing; building without a custom icon.\n' >&2
fi
BUILD_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || printf 'source')"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    BUILD_COMMIT="${BUILD_COMMIT}+dirty"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.bmdy6.StylePolish</string>
<key>CFBundleName</key><string>StylePolish</string>
<key>CFBundleExecutable</key><string>StylePolish</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.7.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>StylePolishCommit</key><string>source</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ -f "$ICON" ]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :StylePolishCommit $BUILD_COMMIT" "$APP/Contents/Info.plist"
if [ -n "$UPDATE_PUBLIC_KEY" ]; then
    /usr/libexec/PlistBuddy \
        -c 'Add :SUFeedURL string https://raw.githubusercontent.com/bmdy6/stylepolish/main/appcast.xml' \
        -c "Add :SUPublicEDKey string $UPDATE_PUBLIC_KEY" \
        -c 'Add :SUEnableAutomaticChecks bool false' \
        -c 'Add :SUAllowsAutomaticUpdates bool false' \
        -c 'Add :SURequireSignedFeed bool true' \
        -c 'Add :SUVerifyUpdateBeforeExtraction bool true' \
        "$APP/Contents/Info.plist"
fi
# Never search the login keychain or create an identity implicitly.
SIGNING_KEYCHAIN="$HOME/Library/Keychains/stylepolish-signing.keychain-db"
SIGNING_IDENTITY=""
if [ "${STYLEPOLISH_ADHOC:-0}" != "1" ] && [ -f "$SIGNING_KEYCHAIN" ]; then
    if scripts/setup-signing.sh; then
        ORIGINAL_SIGNING_SEARCH=()
        while IFS= read -r signing_path; do
            [ -z "$signing_path" ] || ORIGINAL_SIGNING_SEARCH+=("$signing_path")
        done < <(security list-keychains -d user | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
        restore_signing_search() { security list-keychains -d user -s "${ORIGINAL_SIGNING_SEARCH[@]}"; }
        trap restore_signing_search EXIT
        security list-keychains -d user -s "$SIGNING_KEYCHAIN" "${ORIGINAL_SIGNING_SEARCH[@]}"
        SIGNING_IDENTITY="$(security find-identity -p codesigning "$SIGNING_KEYCHAIN" | awk '/"StylePolish Local"/ {print $2; exit}')"
    fi
fi
if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --force --keychain "$SIGNING_KEYCHAIN" --sign "$SIGNING_IDENTITY" --timestamp=none "$APP"
    printf 'Signed with dedicated StylePolish Local identity.\n'
elif [ -n "$UPDATE_PUBLIC_KEY" ]; then
    printf 'Update-enabled builds require the dedicated StylePolish Local signing identity.\n' >&2
    exit 1
else
    printf 'No dedicated signing identity available; using ad-hoc signing (codesign -s -). Updates may need Accessibility reauthorization.\n' >&2
    codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict --deep "$APP"
printf 'Built app: %s\n' "$APP"
