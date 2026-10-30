# Third-party runtime

The compatibility engine is the unmodified arm64 slice of VideoLAN VLC 3.0.23.
Source distribution and license notices: https://download.videolan.org/pub/videolan/vlc/3.0.23/
Corresponding source: https://download.videolan.org/pub/videolan/vlc/3.0.23/vlc-3.0.23.tar.xz
Official runtime: https://download.videolan.org/pub/videolan/vlc/3.0.23/macosx/

The arm64 disk image SHA-256 is pinned in Scripts/fetch-runtime.sh. The local preview
was extracted from the official universal image with SHA-256
56ee657c3aaf5c71b4ab7d6e4f4a77f6eca54633e0bf42a93b8116eb1d1f6ec9.
No changes are made to VLC code. The Intel slices are removed for this Apple Silicon build.
LibVLC is LGPL 2.1 or later. Distributed VLC plug-ins include GPL 2 or later components.
The license texts are bundled alongside this notice. VideoLAN contributors retain their copyrights.
The dynamic libraries remain replaceable in Contents/Frameworks and the plug-ins in
Contents/Resources/VLC. Re-sign an edited local app using codesign --force --deep --sign -.

The NOIR icon and design come from the Windows application, dhucul/NoirMediaPlayer.
The macOS application uses Apple's AppKit, AVFoundation, CoreMedia and QuartzCore frameworks.
