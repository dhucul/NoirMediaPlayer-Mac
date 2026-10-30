import struct
import sys
from pathlib import Path
source, target = map(Path, sys.argv[1:])
entries = [('icp4','icon_16x16.png'),('icp5','icon_32x32.png'),('icp6','icon_32x32@2x.png'),('ic07','icon_128x128.png'),('ic08','icon_256x256.png'),('ic09','icon_512x512.png'),('ic10','icon_512x512@2x.png')]
payload=b''
for kind,name in entries:
    data=(source/name).read_bytes()
    payload+=kind.encode()+struct.pack('>I',len(data)+8)+data
target.write_bytes(b'icns'+struct.pack('>I',len(payload)+8)+payload)
