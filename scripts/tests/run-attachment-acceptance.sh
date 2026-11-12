#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# A bare executable only: no .app, installation, visible window, or user editor.
attachment_tmp="$(mktemp -d /tmp/stylepolish-attachments.XXXXXX)"
trap 'rm -rf "$attachment_tmp"' EXIT
cat Sources/StylePolishApp/AttachmentSafety.swift scripts/tests/SyntheticEditor.swift > "$attachment_tmp/main.swift"
swiftc -D ATTACHMENT_HARNESS "$attachment_tmp/main.swift" -o "$attachment_tmp/editor"
"$attachment_tmp/editor" --headless-attachments
