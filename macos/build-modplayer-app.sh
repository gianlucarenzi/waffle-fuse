#!/bin/sh
# build-modplayer-app.sh – build "Waffle ModPlayer.app" (universal, Qt inside)
#
#   macos/build-modplayer-app.sh <version> <Qt prefix> <libmikmod prefix> [output dir]
#
# Qt: the official universal binaries (aqtinstall, clang_64); libmikmod:
# modplayer/build-libmikmod.sh with -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64".
# macdeployqt copies the Qt frameworks and plugins into the app; then an
# ad-hoc signature, as for Waffle DiskFlashback.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VERSION="${1:?usage: $0 <version> <Qt prefix> <libmikmod prefix> [output dir]}"
QT="${2:?Qt prefix}"
MIKMOD="${3:?libmikmod prefix}"
OUT="${4:-$ROOT/dist}"
APP="$OUT/Waffle ModPlayer.app"
BUILD="$OUT/build-modplayer"

# App icon from icons/modplayer.svg
ICONSET="$BUILD/icon.iconset"
rm -rf "$BUILD" "$APP"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    rsvg-convert -w $size -h $size "$ROOT/icons/modplayer.svg" -o "$ICONSET/icon_${size}x${size}.png"
    rsvg-convert -w $((size * 2)) -h $((size * 2)) "$ROOT/icons/modplayer.svg" -o "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns -o "$ROOT/modplayer/resources/waffle-modplayer.icns" "$ICONSET"

cmake -S "$ROOT/modplayer" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$QT" \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
    -DMIKMOD_ROOT="$MIKMOD" \
    -DWAFFLE_VERSION="$VERSION"
cmake --build "$BUILD" --parallel
rm -f "$ROOT/modplayer/resources/waffle-modplayer.icns"
mv "$BUILD/Waffle ModPlayer.app" "$APP"
plutil -lint "$APP/Contents/Info.plist"

"$QT/bin/macdeployqt" "$APP" -always-overwrite
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
lipo -info "$APP/Contents/MacOS/Waffle ModPlayer"
du -sh "$APP"
rm -rf "$BUILD"
echo "Built $APP"
