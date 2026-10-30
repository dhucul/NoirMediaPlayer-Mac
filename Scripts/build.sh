#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${NOIR_BUILD_DIR:-$ROOT/build}"
APP="$BUILD_DIR/NOIR Media Player.app"
VLC_SOURCE="${NOIR_VLC_APP:-/Applications/VLC.app}"
if [[ ! -f "$VLC_SOURCE/Contents/MacOS/lib/libvlc.dylib" ]]; then
  echo "Set NOIR_VLC_APP to an official VLC 3.0.23 application bundle (arm64 or universal)." >&2
  exit 1
fi
mkdir -p "$BUILD_DIR/objects" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/Resources/VLC"
bash "$ROOT/Scripts/fetch-aacs.sh"
# Clang module caches embed their absolute path; discard one copied from another checkout.
if [[ "$(cat "$BUILD_DIR/module-cache/.root" 2>/dev/null)" != "$BUILD_DIR" ]]; then
  rm -rf "$BUILD_DIR/module-cache"; mkdir -p "$BUILD_DIR/module-cache"; printf '%s' "$BUILD_DIR" > "$BUILD_DIR/module-cache/.root"
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun clang -target arm64-apple-macos13.0 -isysroot "$SDK" -O2 -c "$ROOT/Sources/NoirVLC.c" -o "$BUILD_DIR/objects/NoirVLC.o"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -sdk "$SDK" -O \
  -module-cache-path "$BUILD_DIR/module-cache" -import-objc-header "$ROOT/Sources/NoirVLC.h" \
  "$ROOT"/Sources/*.swift "$BUILD_DIR/objects/NoirVLC.o" \
  -framework AppKit -framework AVFoundation -framework QuartzCore -framework CoreMedia -framework DiskArbitration -framework IOKit -lz \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/NoirMediaPlayer"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ ! -f "$APP/Contents/Resources/NoirMediaPlayer.icns" ]]; then
  ICONSET="$BUILD_DIR/NoirMediaPlayer.iconset"; mkdir -p "$ICONSET"
  for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$ROOT/Resources/NoirMediaPlayer-icon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE*2))
    sips -z "$DOUBLE" "$DOUBLE" "$ROOT/Resources/NoirMediaPlayer-icon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
  done
  python3 "$ROOT/Scripts/make-icon.py" "$ICONSET" "$APP/Contents/Resources/NoirMediaPlayer.icns"
fi
if ! python3 "$ROOT/Scripts/runtime-cache.py" check "$VLC_SOURCE/Contents/MacOS" "$APP" "$BUILD_DIR/.arm64-runtime"; then
  rm -rf "$APP/Contents/Frameworks" "$APP/Contents/Resources/VLC"
  mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/VLC"
  ditto "$VLC_SOURCE/Contents/MacOS/lib" "$APP/Contents/Frameworks"
  for PART in plugins share; do ditto "$VLC_SOURCE/Contents/MacOS/$PART" "$APP/Contents/Resources/VLC/$PART"; done
  # The standalone VLC interface depends on Sparkle; NOIR supplies its own UI.
  rm -f "$APP/Contents/Resources/VLC/plugins/libmacosx_plugin.dylib" "$APP/Contents/Resources/VLC/plugins/plugins.dat"
  # Distribute only Apple Silicon code, including every bundled plug-in.
  while IFS= read -r -d '' LIBRARY; do
    if file -b "$LIBRARY" | grep -q 'Mach-O'; then
      ARCHS="$(lipo -archs "$LIBRARY")"
      if [[ "$ARCHS" != *arm64* ]]; then rm "$LIBRARY"; continue; fi
      if [[ "$ARCHS" == *x86_64* ]]; then lipo "$LIBRARY" -thin arm64 -output "$LIBRARY.arm64"; mv "$LIBRARY.arm64" "$LIBRARY"; fi
      if ! SIGN_OUTPUT="$(codesign --force --sign - "$LIBRARY" 2>&1)"; then echo "$SIGN_OUTPUT" >&2; exit 1; fi
    fi
  done < <(find "$APP/Contents/Frameworks" "$APP/Contents/Resources/VLC" -type f -print0)
  python3 "$ROOT/Scripts/runtime-cache.py" update "$VLC_SOURCE/Contents/MacOS" "$APP" "$BUILD_DIR/.arm64-runtime"
fi
mkdir -p "$APP/Contents/Resources/Licenses"
mkdir -p "$APP/Contents/Frameworks/AACS" "$APP/Contents/Resources/Licenses/AACS"
cp -P "$BUILD_DIR/aacs-runtime/"*.dylib "$APP/Contents/Frameworks/AACS/"
cp "$BUILD_DIR/aacs-runtime/Licenses/"*.txt "$APP/Contents/Resources/Licenses/AACS/"
cp "$ROOT/Resources/ThirdParty.md" "$APP/Contents/Resources/Licenses/ThirdParty.md"
cp "$ROOT/Resources/Licenses/"*.txt "$APP/Contents/Resources/Licenses/"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
