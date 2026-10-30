#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/build/runtime"
mkdir -p "$CACHE"
IMAGE="$CACHE/vlc-3.0.23-arm64.dmg"
if [[ ! -f "$IMAGE" ]]; then
  curl --fail --location --proto '=https' --tlsv1.2 --output "$IMAGE" https://download.videolan.org/pub/videolan/vlc/3.0.23/macosx/vlc-3.0.23-arm64.dmg
fi
printf '%s  %s\n' fc6fac08d87f538517d44aca0c5e7a244b67c8c4cb589bf478363a7315fd5e0d "$IMAGE" | shasum -a 256 -c -
MOUNT="$CACHE/mount"
mkdir -p "$MOUNT"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$IMAGE"
trap 'hdiutil detach "$MOUNT" >/dev/null' EXIT
NOIR_VLC_APP="$MOUNT/VLC.app" bash "$ROOT/Scripts/build.sh"
