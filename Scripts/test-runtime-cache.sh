#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${NOIR_BUILD_DIR:-$ROOT/build}"
CASE_DIR="$BUILD_DIR/runtime-regression"
CASE_APP="$CASE_DIR/NOIR Media Player.app"
SOURCE="${NOIR_VLC_APP:-/Applications/VLC.app}/Contents/MacOS"
mkdir -p "$CASE_DIR"
ditto "$BUILD_DIR/NOIR Media Player.app" "$CASE_APP"
cp "$BUILD_DIR/.arm64-runtime" "$CASE_DIR/.arm64-runtime"
python3 "$ROOT/Scripts/runtime-cache.py" check "$SOURCE" "$CASE_APP" "$CASE_DIR/.arm64-runtime"
echo 'PASS complete runtime cache accepted'
rm "$CASE_APP/Contents/Resources/VLC/plugins/libdvdnav_plugin.dylib"
if python3 "$ROOT/Scripts/runtime-cache.py" check "$SOURCE" "$CASE_APP" "$CASE_DIR/.arm64-runtime"; then
  echo 'FAIL missing playback plug-in accepted' >&2; exit 1
fi
echo 'PASS missing playback plug-in invalidates cache'
rm -rf "$CASE_APP"
NOIR_BUILD_DIR="$CASE_DIR" bash "$ROOT/Scripts/build.sh"
python3 "$ROOT/Scripts/runtime-cache.py" check "$SOURCE" "$CASE_APP" "$CASE_DIR/.arm64-runtime"
codesign --verify --deep --strict "$CASE_APP"
echo 'PASS deleting app with a retained cache marker rebuilds the complete runtime'
python3 - "$CASE_DIR/runtime-cache-report.json" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({'passed':True,'checks':[
    {'check':'complete runtime cache accepted','passed':True},
    {'check':'missing playback plug-in invalidates cache','passed':True},
    {'check':'deleted app rebuild restores complete runtime','passed':True},
]},indent=2)+'\n')
PY
