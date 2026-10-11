#!/bin/sh
# build-app.sh – build "Waffle DiskFlashback.app" (macOS menu bar app + driver)
#
#   macos/build-app.sh <version> [output dir]      (default: dist/)
#
# Needs: the universal waffle-fuse binary in the project root (see the
# workflow, or make on one architecture), Xcode command line tools (swiftc,
# lipo, iconutil, codesign) and rsvg-convert (brew install librsvg).

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VERSION="${1:?usage: $0 <version> [output dir]}"
OUT="${2:-$ROOT/dist}"
APP="$OUT/Waffle DiskFlashback.app"
MIN_MACOS=12.0

rm -rf "$APP" "$OUT/build-app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/build-app"

# App: one architecture at a time, then lipo
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos$MIN_MACOS" \
        -o "$OUT/build-app/WaffleDiskFlashback-$arch" "$HERE/WaffleDiskFlashback/main.swift"
done
lipo -create -output "$APP/Contents/MacOS/WaffleDiskFlashback" \
    "$OUT/build-app/WaffleDiskFlashback-arm64" "$OUT/build-app/WaffleDiskFlashback-x86_64"
install -m 755 "$ROOT/waffle-fuse" "$APP/Contents/MacOS/waffle-fuse"
sed "s/@VERSION@/$VERSION/g" "$HERE/Info.plist.in" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

# Menu bar icons (18 pt) from the Linux tray icons
for s in idle mounting mounted; do
    rsvg-convert -w 18 -h 18 "$ROOT/icons/tray-$s.svg" -o "$APP/Contents/Resources/tray-$s.png"
    rsvg-convert -w 36 -h 36 "$ROOT/icons/tray-$s.svg" -o "$APP/Contents/Resources/tray-$s@2x.png"
done

# App icon from the Amiga floppy
ICONSET="$OUT/build-app/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    rsvg-convert -w $size -h $size "$ROOT/icons/amiga-floppy.svg" -o "$ICONSET/icon_${size}x${size}.png"
    rsvg-convert -w $((size * 2)) -h $((size * 2)) "$ROOT/icons/amiga-floppy.svg" -o "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"

# Ad-hoc signature (no Apple developer certificate): required on Apple Silicon
codesign --force --sign - "$APP/Contents/MacOS/waffle-fuse"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
rm -rf "$OUT/build-app"
echo "Built $APP"
