#!/bin/bash
# Screenshots of waffle-fuse on a Linux desktop, for the documentation.
# Runs in a virtual X display (CI: .github/workflows/screenshots.yml):
#
#   xvfb-run -s "-screen 0 1280x800x24" dbus-run-session docs/screenshots/linux.sh <out dir>
#
# Needs: waffle-fuse built in the repository, marco (MATE window manager),
# caja, stalonetray, xdotool, ImageMagick, python3-gi with GTK 3.
# The demo images of docs/examples are mounted as the desktop would.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
OUT="${1:-$ROOT/docs/images/screenshots}"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
FLOPPY="$HOME/Floppy"

shot_window() {     # <window id> <file>: the window with its frame
    sleep 1.5
    import -frame -window "$1" "$OUT/$2" && echo "saved $2"
}

find_window() {     # <name>: first visible window whose title contains name
    local w
    for _ in $(seq 40); do
        w="$(xdotool search --onlyvisible --name "$1" 2>/dev/null | head -1)"
        [ -n "$w" ] && { echo "$w"; return 0; }
        sleep 0.25
    done
    return 1
}

# A desktop: window manager with frames, a light background
xsetroot -solid '#3a6ea5' 2>/dev/null
marco --replace --no-composite >/dev/null 2>&1 &
sleep 2

# ── The demo images, mounted as the desktop does (volume name as folder) ─────
for img in WaffleDemo.adf WAFFLEDOS.img; do
    cp "$ROOT/docs/examples/$img" "$WORK/"
    "$ROOT/waffle-fuse" --image "$WORK/$img" --automount "$FLOPPY"
done
ls "$FLOPPY"

# ── Caja on the Amiga disk and on the PC disk ────────────────────────────────
for vol in WaffleDemo WAFFLEDOS; do
    caja --no-desktop --browser "$FLOPPY/$vol" >/dev/null 2>&1 &
    if w="$(find_window "$vol")"; then
        xdotool windowsize "$w" 860 520 windowmove "$w" 60 60
        shot_window "$w" "linux-caja-$( [ "$vol" = WaffleDemo ] && echo amiga || echo dos ).png"
        xdotool windowclose "$w" 2>/dev/null || xdotool windowkill "$w"
    else
        echo "::warning::no Caja window for $vol"
    fi
done
pkill -x caja

# ── Tray daemon: icon and menu (no drive here: waiting for the DrawBridge) ───
stalonetray --geometry 6x1-0+0 --icon-size 24 --kludges force_icons_size \
    --background '#2b2b2b' >/dev/null 2>&1 &
sleep 1
python3 "$ROOT/scripts/waffle-diskflashback.py" >"$WORK/daemon.log" 2>&1 &
sleep 4
if tray="$(xdotool search --onlyvisible --class stalonetray | head -1)"; then
    eval "$(xdotool getwindowgeometry --shell "$tray")"
    # The icon is the first one in the tray: right click opens the menu
    xdotool mousemove $((X + 12)) $((Y + 12)) click 3
    sleep 1.5
    import -window root -crop 520x360+$((X + WIDTH - 520))+0 +repage "$OUT/linux-tray-menu.png" && echo "saved linux-tray-menu.png"
    xdotool key Escape
else
    echo "::warning::no tray"; cat "$WORK/daemon.log"
fi

# ── Graphical installer ──────────────────────────────────────────────────────
python3 "$ROOT/scripts/waffle-installer.py" >"$WORK/installer.log" 2>&1 &
if w="$(find_window "waffle-fuse installer")"; then
    xdotool windowmove "$w" 80 60
    shot_window "$w" "linux-installer.png"
else
    echo "::warning::no installer window"; cat "$WORK/installer.log"
fi

# ── Clean up ─────────────────────────────────────────────────────────────────
pkill -f waffle-installer.py; pkill -f waffle-diskflashback.py
for vol in WaffleDemo WAFFLEDOS; do fusermount3 -u "$FLOPPY/$vol" 2>/dev/null; done
rm -rf "$WORK"
ls -l "$OUT"
