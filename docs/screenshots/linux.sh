#!/bin/bash
# Screenshots of waffle-fuse on a Linux desktop, for the documentation.
# Runs in a virtual X display (CI: .github/workflows/screenshots.yml):
#
#   xvfb-run -s "-screen 0 1280x800x24" dbus-run-session docs/screenshots/linux.sh <out dir> [player]
#
# player: Waffle ModPlayer (the bundle of the Linux packages), for its window
# playing the module of the demo floppy.
#
# Needs: waffle-fuse built in the repository, xfwm4, caja, stalonetray,
# xdotool, ImageMagick, python3-gi with GTK 3 and librsvg (SVG icons).
# The demo images of docs/examples are mounted as the desktop would.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
OUT="${1:-$ROOT/docs/images/screenshots}"
PLAYER="${2:-}"
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
xfwm4 --compositor=off >/dev/null 2>&1 &
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

# ── Waffle ModPlayer: the module on the Amiga floppy, playing ───────────────
if [ -n "$PLAYER" ]; then
    "$PLAYER" --mute --quit-after 30 "$FLOPPY/WaffleDemo/Music/waffle.mod" >"$WORK/player.log" 2>&1 &
    MPPID=$!
    if w="$(find_window "Waffle ModPlayer")"; then
        xdotool windowmove "$w" 60 60
        sleep 6      # the VU meters moving, the scroller under way
        shot_window "$w" "linux-modplayer.png"
    else
        echo "::warning::no ModPlayer window"; cat "$WORK/player.log"
        echo "--- libraries of the X11 plugin not found:"
        ldd "$(dirname "$PLAYER")/plugins/platforms/libqxcb.so" | grep 'not found'
        QT_DEBUG_PLUGINS=1 timeout 10 "$PLAYER" --mute --quit-after 2 --force "$FLOPPY/WaffleDemo/Music/waffle.mod" 2>&1 |
            grep -iE 'cannot|error|fail|xcb' | head -20
    fi
    kill $MPPID 2>/dev/null
fi

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
    # The tray and the menu, without the empty (black) screen around them
    import -window root -crop 600x440+$((X + WIDTH - 600))+0 +repage "$WORK/menu.png" &&
        convert "$WORK/menu.png" -fuzz 3% -trim +repage -bordercolor black -border 8 "$OUT/linux-tray-menu.png" &&
        echo "saved linux-tray-menu.png"
    xdotool key Escape
else
    echo "::warning::no tray"; cat "$WORK/daemon.log"
fi

# ── Graphical installer ──────────────────────────────────────────────────────
# The optional packages it checks for, as on a complete desktop (CI: the tray
# screenshot above needs the X11 fallback, without AppIndicator)
if [ -n "${CI:-}" ]; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        gir1.2-ayatanaappindicator3-0.1 polkitd pkexec >/dev/null 2>&1 || true
fi
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
