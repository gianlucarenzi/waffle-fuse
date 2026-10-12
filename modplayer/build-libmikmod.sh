#!/bin/sh
# build-libmikmod.sh – libmikmod as a static library for Waffle ModPlayer, so
# the player carries it and needs no libmikmod (nor its SDL and OpenAL) on the
# system.  Only the native audio drivers: ALSA and PulseAudio on Linux, loaded
# at run time (dlopen: neither is a dependency), CoreAudio on macOS, WinMM and
# DirectSound on Windows.
#
#   modplayer/build-libmikmod.sh <install prefix> [cmake options...]
#
# e.g. -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0
# Then: make modplayer MODPLAYER_CMAKE_FLAGS="-DMIKMOD_STATIC=ON" with
# PKG_CONFIG_PATH=<install prefix>/lib/pkgconfig

set -e

VERSION=3.3.13
SHA256=9fc1799f7ea6a95c7c5882de98be85fc7d20ba0a4a6fcacae11c8c6b382bb207
URL="https://downloads.sourceforge.net/project/mikmod/libmikmod/$VERSION/libmikmod-$VERSION.tar.gz"

PREFIX="$1"
[ -n "$PREFIX" ] || { echo "Usage: $0 <install prefix> [cmake options...]" >&2; exit 1; }
shift
mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -sSL --retry 3 -o "$WORK/libmikmod.tar.gz" "$URL"
if command -v sha256sum >/dev/null 2>&1; then
    echo "$SHA256  $WORK/libmikmod.tar.gz" | sha256sum -c -
else
    echo "$SHA256  $WORK/libmikmod.tar.gz" | shasum -a 256 -c -
fi
tar -C "$WORK" -xzf "$WORK/libmikmod.tar.gz"

cmake -S "$WORK/libmikmod-$VERSION" -B "$WORK/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
    -DENABLE_OPENAL=OFF -DENABLE_SDL=OFF -DENABLE_ESD=OFF -DENABLE_NAS=OFF \
    -DENABLE_DOC=OFF \
    "$@"
cmake --build "$WORK/build" --parallel
cmake --install "$WORK/build"
echo "libmikmod $VERSION (static) installed in $PREFIX"
