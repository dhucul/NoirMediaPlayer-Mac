"""Validate the source and every cached runtime file, including symlink targets."""
import hashlib
import json
import os
import sys
from pathlib import Path

mode, source_arg, app_arg, marker_arg = sys.argv[1:]
source, app, marker = map(Path, (source_arg, app_arg, marker_arg))

def inventory(root, directories):
    result = {}
    for directory in directories:
        folder = root / directory
        if not folder.is_dir():
            raise ValueError(f'Missing runtime directory: {folder}')
        for path in sorted(folder.rglob('*')):
            # AACS is built, verified and copied independently by fetch-aacs.sh.
            if directory == 'Contents/Frameworks' and path.relative_to(folder).parts[0] == 'AACS':
                continue
            name = path.relative_to(root).as_posix()
            if path.is_symlink():
                if not path.exists():
                    raise ValueError(f'Broken runtime symlink: {path}')
                result[name] = {'link': os.readlink(path)}
            elif path.is_file():
                result[name] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    return result

try:
    required = [
        'Contents/Frameworks/libvlc.dylib',
        'Contents/Frameworks/libvlccore.dylib',
        *('Contents/Resources/VLC/plugins/' + name for name in (
            'libfilesystem_plugin.dylib', 'libavcodec_plugin.dylib',
            'libvout_macosx_plugin.dylib', 'libdvdnav_plugin.dylib',
            'libdvdread_plugin.dylib', 'liblibbluray_plugin.dylib')),
    ]
    if not all((app / name).is_file() for name in required):
        raise ValueError('The application is missing required VLC libraries or plug-ins')
    state = {
        'version': 1,
        'source': inventory(source, ('lib', 'plugins', 'share')),
        'packaged': inventory(app, ('Contents/Frameworks', 'Contents/Resources/VLC')),
    }
    if mode == 'check':
        if json.loads(marker.read_text()) != state:
            raise ValueError('The cached runtime no longer matches its source or packaged files')
    elif mode == 'update':
        temporary = marker.with_suffix('.tmp')
        temporary.write_text(json.dumps(state, sort_keys=True))
        temporary.replace(marker)
    else:
        raise ValueError('Expected check or update')
except (OSError, ValueError) as error:
    if mode != 'check':
        print(error, file=sys.stderr)
    raise SystemExit(1)
