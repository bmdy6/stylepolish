#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Run inside a VM or dedicated Mac desktop, never on the user's active desktop.
if [ "${STYLEPOLISH_ISOLATED_DESKTOP:-0}" != "1" ]; then
    echo 'Refusing GUI automation: run inside an isolated macOS desktop with STYLEPOLISH_ISOLATED_DESKTOP=1.' >&2
    exit 2
fi
AUDIT_TMP="$(mktemp -d /tmp/stylepolish-writeback.XXXXXX)"
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
    # A dedicated test bundle ID, never the user's installed app.
    pkill -f "$AUDIT_TMP/Editor.app/Contents/MacOS/Editor" 2>/dev/null || true
    rm -rf "$AUDIT_TMP"
}
trap cleanup EXIT
mkdir -p "$AUDIT_TMP/Editor.app/Contents/MacOS"
swiftc -target "$(uname -m)-apple-macosx13.0" scripts/tests/SyntheticEditor.swift -o "$AUDIT_TMP/Editor.app/Contents/MacOS/Editor"
cat > "$AUDIT_TMP/Editor.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.bmdy6.StylePolish.SyntheticEditor</string>
<key>CFBundleName</key><string>StylePolish Synthetic Editor</string>
<key>CFBundleExecutable</key><string>Editor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$AUDIT_TMP/Editor.app"
python3 scripts/tests/writeback-server.py "$AUDIT_TMP/port" &
SERVER_PID=$!
for attempt in {1..100}; do [ -s "$AUDIT_TMP/port" ] && break; sleep 0.05; done
STYLEPOLISH_UI_TESTS=1 STYLEPOLISH_EDITOR="$AUDIT_TMP/Editor.app" STYLEPOLISH_TEST_BASE="http://127.0.0.1:$(cat "$AUDIT_TMP/port")/v1" swift test --filter AutomaticIntegrationTests
