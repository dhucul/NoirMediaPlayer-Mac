#!/bin/bash
# Packages the built app as a drag-to-Applications disk image with a SHA-256 file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${NOIR_BUILD_DIR:-$ROOT/build}"
APP="$BUILD_DIR/NOIR Media Player.app"
OUTPUT="${1:-$ROOT/Installer/NoirMediaPlayer-macOS-arm64.dmg}"
codesign --verify --deep --strict "$APP"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/NOIR Media Player.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/Resources/DMG Read Me.txt" "$STAGE/Read Me.txt"
# Build beside the app and replace the output only after the image verifies.
IMAGE="$BUILD_DIR/$(basename "$OUTPUT")"
hdiutil create -volname "NOIR Media Player" -srcfolder "$STAGE" -fs APFS -format UDZO -ov "$IMAGE" >/dev/null
hdiutil verify "$IMAGE" >/dev/null
rm -rf "$STAGE"
mkdir -p "$(dirname "$OUTPUT")"; mv -f "$IMAGE" "$OUTPUT"
(cd "$(dirname "$OUTPUT")" && shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
echo "$OUTPUT"
