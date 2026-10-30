#!/bin/bash
# Build the same replaceable LGPL AACS components as Windows for arm64 macOS 13.
# No Homebrew installation or global library changes are needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${NOIR_BUILD_DIR:-$ROOT/build}"
CACHE="$BUILD_DIR/aacs-source"
RUNTIME="$BUILD_DIR/aacs-runtime"
PREFIX="$CACHE/install"
mkdir -p "$CACHE" "$RUNTIME"
if [[ -f "$RUNTIME/SHA256SUMS" ]] && (cd "$RUNTIME" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1); then exit 0; fi
export MACOSX_DEPLOYMENT_TARGET=13.0
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export lt_cv_sys_max_cmd_len=262144
export CC="$(xcrun -f clang)"
export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=13.0"
export LDFLAGS="-arch arm64 -mmacosx-version-min=13.0 -L$PREFIX/lib"
export CPPFLAGS="-I$PREFIX/include"
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
build() {
  local name="$1" version="$2" url="$3" hash="$4"
  shift 4
  local archive="$CACHE/$name-$version.tar.bz2"
  if [[ ! -f "$archive" ]]; then curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$url"; fi
  printf '%s  %s\n' "$hash" "$archive" | shasum -a 256 -c -
  rm -rf "$CACHE/$name-$version"
  tar -xf "$archive" -C "$CACHE"
  echo "Building $name $version for arm64 (log: $CACHE/$name-build.log)"
  if ! (cd "$CACHE/$name-$version" && ./configure --prefix="$PREFIX" --build=arm-apple-darwin --host=aarch64-apple-darwin --disable-static --enable-shared --disable-dependency-tracking "$@" && make -j"$JOBS" && make install) >"$CACHE/$name-build.log" 2>&1; then
    tail -60 "$CACHE/$name-build.log" >&2; exit 1
  fi
}
build libgpg-error 1.61 https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.61.tar.bz2 7a85413f2bc354f4f8aa832b718af122e48965e9e0eb9012ee659c13c6385c93 --disable-doc --disable-nls
build libgcrypt 1.12.4 https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.12.4.tar.bz2 d77f68f48879510e79a2f65977ccc68981781ea0923e5bdffac2a193ea3d660e --disable-doc --disable-asm --with-libgpg-error-prefix="$PREFIX"
build libaacs 0.12.0 https://download.videolan.org/pub/videolan/libaacs/0.12.0/libaacs-0.12.0.tar.bz2 1996673a9fc45ee4a364c66ffa84756629bf3923e52346c7358b71becb8e4419 --with-libgcrypt-prefix="$PREFIX" --with-libgpg-error-prefix="$PREFIX"
for library in libaacs.0.dylib libgcrypt.20.dylib libgpg-error.0.dylib; do
  cp -L "$PREFIX/lib/$library" "$RUNTIME/$library"
  install_name_tool -id "@loader_path/$library" "$RUNTIME/$library"
  for dependency in libgcrypt.20.dylib libgpg-error.0.dylib; do
    if otool -L "$RUNTIME/$library" | grep -Fq "$PREFIX/lib/$dependency"; then
      install_name_tool -change "$PREFIX/lib/$dependency" "@loader_path/$dependency" "$RUNTIME/$library"
    fi
  done
  codesign --force --sign - "$RUNTIME/$library"
done
ln -sf libaacs.0.dylib "$RUNTIME/libaacs.dylib"
mkdir -p "$RUNTIME/Licenses"
for spec in libaacs:0.12.0 libgcrypt:1.12.4 libgpg-error:1.61; do
  name="${spec%:*}"; version="${spec#*:}"
  cp "$CACHE/$name-$version/COPYING" "$RUNTIME/Licenses/$name-COPYING.txt"
  if [[ -f "$CACHE/$name-$version/COPYING.LIB" ]]; then cp "$CACHE/$name-$version/COPYING.LIB" "$RUNTIME/Licenses/$name-COPYING.LIB.txt"; fi
done
(cd "$RUNTIME" && shasum -a 256 *.dylib Licenses/*.txt > SHA256SUMS)
