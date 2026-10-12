#!/bin/bash
# Screenshots of waffle-fuse on macOS, for the documentation.
# Runs on a Mac with FUSE-T installed (CI: .github/workflows/screenshots.yml):
#
#   docs/screenshots/macos.sh <out dir> "<path of Waffle DiskFlashback.app>"
#
# The menu bar app opens the demo image of docs/examples: mounted under
# ~/Floppy/<volume name> and shown in the Finder.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
OUT="${1:-$ROOT/docs/images/screenshots}"
APP="${2:-/Applications/Waffle DiskFlashback.app}"
mkdir -p "$OUT"
WORK="$(mktemp -d /tmp/shots.XXXXXX)"
is_mounted() { [ -d "$1" ] && [ "$(/usr/bin/stat -f %d "$1")" != "$(/usr/bin/stat -f %d "$1/..")" ]; }

cp "$ROOT/docs/examples/WaffleDemo.adf" "$ROOT/docs/examples/WAFFLEDOS.img" "$WORK/"

# The app, started from the shell (on the CI runners an NFS mount from the GUI
# session fails), opens both images: mounted and shown in the Finder
"$APP/Contents/MacOS/WaffleDiskFlashback" "$WORK/WaffleDemo.adf" "$WORK/WAFFLEDOS.img" >/dev/null 2>&1 &
APPPID=$!
for _ in $(seq 60); do is_mounted "$HOME/Floppy/WaffleDemo" && is_mounted "$HOME/Floppy/WAFFLEDOS" && break; sleep 0.5; done
ls "$HOME/Floppy"
sleep 4

# shot <folder> <file>: the Finder window of a folder, at a known place
shot() {
    open "$1"
    sleep 2
    if osascript -e "tell application \"Finder\" to set bounds of (first window whose name is \"$(basename "$1")\") to {60, 80, 960, 620}" \
                 -e 'tell application "Finder" to activate' 2>"$WORK/osa.log"; then
        sleep 1.5
        screencapture -x -o -R60,80,900,540 "$OUT/$2" && echo "saved $2"
    else
        echo "::warning::cannot place the Finder window: $(cat "$WORK/osa.log")"
        screencapture -x "$OUT/$2" && echo "saved $2 (whole screen)"
    fi
}
shot "$HOME/Floppy/WaffleDemo" macos-finder-amiga.png
shot "$HOME/Floppy/WAFFLEDOS" macos-finder-dos.png

# The menu bar, right side: the app's floppy icon
W=$(osascript -e 'tell application "Finder" to get item 3 of (get bounds of window of desktop)' 2>/dev/null || echo 1920)
screencapture -x -R$((W - 520)),0,520,30 "$OUT/macos-menu-bar.png" && echo "saved macos-menu-bar.png"

# Quit the app: it unmounts the images first
kill -TERM $APPPID
for _ in $(seq 60); do kill -0 $APPPID 2>/dev/null || break; sleep 0.5; done
rm -rf "$WORK"
ls -l "$OUT"
