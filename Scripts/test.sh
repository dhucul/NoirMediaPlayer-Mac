#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${NOIR_BUILD_DIR:-$ROOT/build}"
APP="$BUILD_DIR/NOIR Media Player.app/Contents/MacOS/NoirMediaPlayer"
FIXTURES="$BUILD_DIR/fixtures"
mkdir -p "$FIXTURES"
# Clang module caches embed their absolute path; discard one copied from another checkout.
if [[ "$(cat "$BUILD_DIR/module-cache/.root" 2>/dev/null)" != "$BUILD_DIR" ]]; then
  rm -rf "$BUILD_DIR/module-cache"; mkdir -p "$BUILD_DIR/module-cache"; printf '%s' "$BUILD_DIR" > "$BUILD_DIR/module-cache/.root"
fi
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" "$ROOT/Tests/MakeFixtures.swift" -o "$BUILD_DIR/MakeFixtures"
"$BUILD_DIR/MakeFixtures" "$FIXTURES"
python3 "$ROOT/Tests/make_matroska.py" "$FIXTURES"
python3 - "$APP" "$FIXTURES" <<'PY'
import json, os, subprocess, sys, threading, http.server, functools, re
from pathlib import Path
app, fixtures=sys.argv[1:]
report=Path(fixtures)/'smoke-report.json'
report.unlink(missing_ok=True)
env=dict(os.environ,NOIR_DATA_DIR=str(Path(fixtures).parent/'test-settings'))
class RangeHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def send_head(self):
        path=Path(self.translate_path(self.path))
        if not path.is_file():
            self.send_error(404); return None
        size=path.stat().st_size; start=0; end=size-1; partial=False
        header=self.headers.get('Range')
        if header:
            match=re.fullmatch(r'bytes=(\d*)-(\d*)',header)
            if not match or not any(match.groups()):
                self.send_error(416); return None
            first,last=match.groups()
            start=int(first) if first else max(0,size-int(last))
            end=min(size-1,int(last)) if first and last else size-1
            if start>end:
                self.send_error(416); return None
            partial=True
        self.send_response(206 if partial else 200)
        self.send_header('Content-Type',self.guess_type(str(path)))
        self.send_header('Accept-Ranges','bytes')
        self.send_header('Content-Length',str(end-start+1))
        if partial: self.send_header('Content-Range','bytes %d-%d/%d'%(start,end,size))
        self.end_headers(); self.remaining=end-start+1
        source=path.open('rb'); source.seek(start); return source
    def copyfile(self,source,outputfile):
        while self.remaining:
            chunk=source.read(min(65536,self.remaining))
            if not chunk: break
            outputfile.write(chunk); self.remaining-=len(chunk)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(RangeHandler,directory=fixtures))
threading.Thread(target=server.serve_forever,daemon=True).start()
env['NOIR_HTTP_TEST_URL']='http://127.0.0.1:%d/native.mp4'%server.server_port
try:
    subprocess.run([app,'--smoke-test',fixtures],env=env,check=True,timeout=120)
finally:
    server.shutdown()
result=json.loads(report.read_text())
for item in result['checks']:
    print(('PASS' if item['passed'] else 'FAIL')+' '+item['check'])
if not result['passed']:
    raise SystemExit(1)
PY
