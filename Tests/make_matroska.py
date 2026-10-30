"""Original MJPEG Matroska fixture; no downloaded or copyrighted test media."""
import struct
import sys
import zipfile
import wave, math
from pathlib import Path
root = Path(sys.argv[1])
def vint(n):
    for width in range(1,9):
        if n < (1 << (width*7))-1:
            return (n | (1 << (width*7))).to_bytes(width,'big')
    raise ValueError(n)
def element(identifier, payload):
    key=identifier.to_bytes((identifier.bit_length()+7)//8,'big')
    return key+vint(len(payload))+payload
def integer(identifier,n):
    return element(identifier,n.to_bytes(max(1,(n.bit_length()+7)//8),'big'))
header=element(0x1a45dfa3,integer(0x4286,1)+integer(0x42f7,1)+integer(0x42f2,4)+integer(0x42f3,8)+element(0x4282,b'matroska')+integer(0x4287,4)+integer(0x4285,2))
info=element(0x1549a966,integer(0x2ad7b1,1000000)+element(0x4489,struct.pack('>d',12000))+element(0x4d80,b'NOIR tests')+element(0x5741,b'NOIR tests'))
track=element(0xae,integer(0xd7,1)+integer(0x73c5,1)+integer(0x83,1)+element(0x86,b'V_MJPEG')+integer(0x23e383,100000000)+element(0xe0,integer(0xb0,320)+integer(0xba,180)))
jpeg=(root/'frame.jpg').read_bytes()
blocks=b''.join(element(0xa3,b'\x81'+struct.pack('>h',i*100)+b'\x80'+jpeg) for i in range(120))
cluster=element(0x1f43b675,integer(0xe7,0)+blocks)
(root/'fallback.mkv').write_bytes(header+element(0x18538067,info+element(0x1654ae6b,track)+cluster))
for method,name in [(zipfile.ZIP_STORED,'stored'),(zipfile.ZIP_DEFLATED,'deflated')]:
    with zipfile.ZipFile(root/('keys-'+name+'.zip'),'w',compression=method) as archive:
        archive.writestr('test/KEYDB.cfg','; Synthetic parser test, no usable keys\nentry = value | test\n')
with wave.open(str(root/'audio.wav'),'wb') as audio:
    audio.setparams((2,2,44100,0,'NONE','not compressed'))
    audio.writeframes(b''.join(struct.pack('<hh',int(math.sin(i*2*math.pi*440/44100)*2000),int(math.sin(i*2*math.pi*660/44100)*2000)) for i in range(44100*5)))
