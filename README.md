# NOIR Media Player for macOS

Native Apple Silicon port of [NOIR Media Player](https://github.com/dhucul/NoirMediaPlayer),
the Windows DVD, video, audio and network-stream player. The application and every bundled
playback library contain **arm64 only**. The deployment target is macOS 13 or later;
the current preview was exercised on macOS 27.2, not on every older supported release.

## Playback architecture

AppKit provides the desktop interface. AVFoundation is the preferred engine for supported
files and HTTP/HTTPS media. It provides the player clock, audio and embedded subtitle
selection, chapters, hardware-managed decoding and video frames. First-party Swift handles
the queue, M3U/M3U8 playlists, bookmarks, recent sources, plain SRT/WebVTT captions,
aspect overrides, native rotation, snapshots, window modes and keyboard controls.

The official VLC 3.0.23 runtime is loaded only when needed: an unsupported source,
native startup failure or timeout, complex subtitle file, optical disc or explicit
compatibility preference. Local HLS manifests remain single sources rather than becoming
queue entries. Network protocols supported by the interface are HTTP, HTTPS, RTSP, RTP and UDP.

The production Windows application likewise prefers Windows playback and retains VLC
for compatibility. Its experimental first-party DVD VM/renderer is **not** a completed
production backend; this port uses VLC for DVDs and Blu-ray folders.

## Build

Install Xcode and its command-line tools, then run from the repository root:

```sh
bash Scripts/fetch-runtime.sh
```

This downloads the official **arm64** VLC image over HTTPS, verifies its pinned SHA-256,
mounts it read-only, builds NOIR, bundles the runtime and detaches the image. It does not
install VLC in Applications. The output is `build/NOIR Media Player.app`.

To use an existing official VLC 3.0.23 bundle instead:

```sh
NOIR_VLC_APP=/Applications/VLC.app bash Scripts/build.sh
```

The build uses only Apple's SDK, C/Swift compilers, shell utilities and Python 3.
There are no Swift package or .NET dependencies. Universal input runtimes are reduced
to their arm64 slices; Intel-only plug-ins and the standalone VLC interface are omitted.
The build signs each binary and the application ad hoc and verifies the result. Public
distribution still requires the owner's Developer ID signing and Apple notarization.
The app icon and the GPL/LGPL texts in `Resources/` come from the Windows repository.

To package the built app as a drag-to-Applications disk image, run
`bash Scripts/package-dmg.sh`. It writes `Installer/NoirMediaPlayer-macOS-arm64.dmg`
(compressed, APFS, with an Applications link and `Resources/DMG Read Me.txt`) and its
`.sha256`, replacing the previous image only after the new one verifies. Disk images are
not committed; publish them as release assets.

Runtime caching records hashes of the input and packaged runtime, including every
plug-in and symlink. Missing, changed or partially deleted bundles are repackaged;
a surviving cache marker alone cannot produce an app without VLC.

## Controls

The interface retains NOIR's queue / video / inspector layout and original icon/colors.
Native macOS menus, file dialogs, window controls and Command-key shortcuts are used.

| Shortcut | Action |
| --- | --- |
| Space | Play / pause |
| Left / Right | Seek 10 seconds; Shift seeks 30 |
| Up / Down | Volume |
| Page Up / Page Down | Previous / next |
| F / Escape | Fullscreen / leave fullscreen |
| P | Always-on-top mini player |
| M / S / V | Mute / snapshot / external subtitle |
| H / R | Shuffle / cycle repeat Off, All, One |
| I / B | Inspector / queue |
| Command-O | Open files / playlists |
| Shift-Command-O | Open folder recursively |
| Command-D / Command-E | Open optical disc / eject active optical disc |
| Command-L | Open network stream |
| Option-arrows / Return | DVD menu navigation / activation |

Legacy Control-O/D/E/L aliases are also supported. Text editing retains the normal
macOS shortcuts. Files and folders can be dropped on the video area; dropping a
subtitle on an active session loads it.

Preferences and bookmarks live in `~/Library/Application Support/NoirMediaPlayer/settings.json`.
Snapshots default to `~/Pictures/Noir Snapshots`. Tests override both with workspace paths.
Recent sources appear in File → Open Recent. Files/folders can be dropped throughout the
window. Playback preferences apply to the next open;
the hardware-decoding switch applies to compatibility playback because AVFoundation
manages native decoder selection.

## Validation and remaining parity work

Run `bash Scripts/test.sh` in a logged-in graphical macOS session after building.
It generates original H.264, stereo PCM and MJPEG/Matroska fixtures, launches the real application,
checks native display readiness, pause/seek, native captions on/off, rotated native PNGs,
complex-caption handoff and pause restoration, compatibility snapshots/rotation,
unsupported-container fallback, mini player, queue filtering, volume/mute, native audio
and HTTP playback from a temporary localhost server. It also checks playlist round trips,
caption boundaries and bounded stored/deflated AACS ZIP parsing with synthetic data.
Review regressions cover stop/quit bookmarks and resuming, Play and Repeat One after
VLC EOF (including audio selections), one-item Shuffle with Repeat All/Off, DVD/Blu-ray
playlist identity, rejection of disc folders on non-optical storage, and revalidation
of an optical device before eject. Audit regressions cover rotation during VLC startup,
seeking after a native end, seeks issued before AVFoundation is ready, Play after Stop and
Next after removing the current item, duplicate track names, concurrent snapshots,
tolerant/clamped settings decoding, Windows-1252 and BOM playlists, caption separators
and entities, the source limit across inputs, AACS text split at the inspection boundary,
caption files dropped with media, launch-argument flags, and a missing VLC player.
Eject requests use a mock adapter in tests; no
physical volume is unmounted by the suite.
No actual key database is downloaded during tests. The JSON report is in `build/fixtures`.
It exits on failure or after a 120-second process deadline.

With `NOIR_VLC_APP` pointing to an official runtime, run
`bash Scripts/test-runtime-cache.sh` to verify cache reuse, missing-plug-in
detection, and a complete rebuild after deleting the generated app while retaining
the cache marker. It uses a separate generated bundle under `build/runtime-regression`.

Build 2 fixes all six initial review findings: VLC replay at EOF, bookmark loss after
Stop, optical-only eject selection, disc identity in playlists, one-item Shuffle
repeat cycles, and stale runtime packaging caches. Eject validates the whole device's
I/O Registry optical-media class and identity, waits for playback handles to close,
and rejects a replacement device before submitting an unmount request.

This is a working preview, not a claim of complete Windows parity:

- Physical DVD/Blu-ray playback, authored menu interaction and eject need real-drive
  verification. Multi-track files, chapter-rich media and live network protocols need
  a broader real-media matrix beyond the generated fixtures.
- Encrypted Blu-ray requires a compatible external arm64 libaacs installation and keys;
  a Mac libaacs build is not bundled. Settings provides alternate arm64 library selection,
  the standard key folder and an explicit key-download button using the same service as
  Windows. Downloads are bounded, HTTPS-only and validated; ZIP contents are read in memory
  without extracting archive paths. Library changes require a restart. Availability and
  coverage of that third-party key service have not been verified. BD-J menus can require
  additional Java components.
- Plain UTF-8 SRT/WebVTT renders natively. Formatted/positioned captions and other formats
  hand the original file to VLC. Native and VLC embedded tracks depend on their respective
  format/codec support; the Windows bounded metadata inspectors are not yet shared.
- Native snapshots compose the selected external plain captions after video rotation.
  LibVLC snapshots include its rendered captions; the subsequent image rotation rotates
  those captions together with the picture. Native embedded caption text is included in
  snapshots with first-party plain styling; its authored placement/style is not reproduced yet.
- The app is ad-hoc signed for local testing and has not been notarized. macOS 13–26
  compatibility is a deployment target, not a completed OS-version test matrix.

See `Resources/ThirdParty.md` and the bundled license texts for runtime attribution and source links.
