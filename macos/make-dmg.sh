#!/bin/sh
# make-dmg.sh – disk image with the app, a link to Applications and the notes
#
#   macos/make-dmg.sh <app> <output.dmg> [more apps...]
#
# (the more apps: Waffle ModPlayer, next to Waffle DiskFlashback)

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:?usage: $0 <app> <output.dmg>}"
DMG="${2:?usage: $0 <app> <output.dmg>}"
SRC="$(mktemp -d)"

cp -R "$APP" "$SRC/"
shift 2
for more in "$@"; do cp -R "$more" "$SRC/"; done
ln -s /Applications "$SRC/Applications"
cp "$HERE/dmg-readme.txt" "$SRC/Read me first.txt"
rm -f "$DMG"
hdiutil create -volname "Waffle DiskFlashback" -srcfolder "$SRC" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$SRC"
echo "Created $DMG"
