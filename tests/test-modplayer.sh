#!/bin/bash
# Tests of Waffle ModPlayer, the easter egg: a module on a disk mounted by
# waffle-fuse is recognised and plays; a module anywhere else is not (on Linux
# it goes to the application that had .mod files before).
#
#   tests/test-modplayer.sh [player]
#
# player: waffle-modplayer (default: next to waffle-fuse; on macOS the binary
# inside "Waffle ModPlayer.app").  SHOT_DIR=<dir> keeps the screenshots.
# Needs what tests/run-tests.sh needs to mount images (FUSE, FUSE-T or WinFsp).

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
BIN="$ROOT/waffle-fuse"
PLAYER="${1:-$ROOT/waffle-modplayer}"
WINDOWS=
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WINDOWS=1; BIN="$BIN.exe"; [ -n "${1:-}" ] || PLAYER="$PLAYER.exe" ;; esac

if [ -n "$WINDOWS" ]; then
    is_mounted() { [ -d "$1" ]; }
    fuse_umount() { "$BIN" --unmount "$1"; }
elif [ "$(uname -s)" = Darwin ]; then
    is_mounted() { [ -d "$1" ] && [ "$(/usr/bin/stat -f %d "$1" 2>/dev/null)" != "$(/usr/bin/stat -f %d "$1/.." 2>/dev/null)" ]; }
    fuse_umount() { umount "$1"; }
else
    is_mounted() { mountpoint -q "$1"; }
    fuse_umount() { fusermount3 -u "$1"; }
    # No display needed for the window on Linux
    export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
fi

WORK="$(mktemp -d /tmp/waffle-modplayer-test.XXXXXX)"
MNT="$WORK/mnt"
[ -n "$WINDOWS" ] || mkdir -p "$MNT"
PASS=0
FAIL=0
PID=

cleanup() {
    is_mounted "$MNT" 2>/dev/null && fuse_umount "$MNT"
    [ -n "$PID" ] && wait "$PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

ok()  { echo "  ok   $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

mount_img() {
    "$BIN" --image "$1" "$MNT" -f >"$WORK/fuse.log" 2>&1 &
    PID=$!
    for _ in $(seq 50); do
        is_mounted "$MNT" && return 0
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.1
    done
    echo "mount failed:"; cat "$WORK/fuse.log"
    return 1
}

umount_img() {
    fuse_umount "$MNT"
    for _ in $(seq 200); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    wait "$PID" 2>/dev/null
    PID=
}

"$PLAYER" --version || { echo "cannot run $PLAYER"; exit 1; }
python3 "$ROOT/docs/examples/make-mod.py" "$WORK/waffle.mod" >/dev/null 2>&1 ||
    python "$ROOT/docs/examples/make-mod.py" "$WORK/waffle.mod" >/dev/null

for fmt in ffs dos; do
    echo "== module on a waffle-fuse disk ($fmt)"
    "$BIN" --format-image "$WORK/$fmt.img" "$fmt" dd "MODS" >/dev/null
    mount_img "$WORK/$fmt.img" || { bad "mount $fmt"; continue; }
    cp "$WORK/waffle.mod" "$MNT/waffle.mod"

    if out="$("$PLAYER" --is-waffle "$MNT/waffle.mod" 2>&1)"; then
        ok "recognised as a waffle-fuse disk${out:+ ($(echo "$out" | tr -d '\r'))}"
    else
        bad "not recognised as a waffle-fuse disk: $out"
    fi

    # Plays from the floppy: the window, after 5 s of music
    rm -f "$WORK/shot.png"
    "$PLAYER" --mute --screenshot "$WORK/shot.png" "$MNT/waffle.mod" >"$WORK/player.log" 2>&1
    rc=$?
    if [ $rc -eq 0 ] && [ -s "$WORK/shot.png" ]; then
        ok "plays and shows the VU meters"
        [ -n "${SHOT_DIR:-}" ] && mkdir -p "$SHOT_DIR" && cp "$WORK/shot.png" "$SHOT_DIR/modplayer-$fmt.png"
    else
        bad "player (exit $rc):"; cat "$WORK/player.log"
    fi
    umount_img
done

# Windows: on a drive letter too, as the tray app mounts disks
if [ -n "$WINDOWS" ]; then
    echo "== module on a waffle-fuse drive letter (Windows)"
    "$BIN" --format-image "$WORK/letter.adf" ffs dd "LETTER" >/dev/null
    "$BIN" --image "$WORK/letter.adf" '*' -f >"$WORK/letter.log" 2>&1 &
    LPID=$!
    L=
    for _ in $(seq 100); do
        L="$(sed -n 's/^WAFFLE event=mounted mountpoint=//p' "$WORK/letter.log" | tr -d '\r')"
        [ -n "$L" ] && break
        sleep 0.1
    done
    if [ -n "$L" ]; then
        cp "$WORK/waffle.mod" "$L/waffle.mod"
        echo "       file system of $L: $(powershell -NoProfile -Command "([IO.DriveInfo]'$L').DriveFormat" | tr -d '\r')"
        if out="$("$PLAYER" --is-waffle "$L/waffle.mod" 2>&1)"; then
            ok "recognised on $L ($(echo "$out" | tr -d '\r'))"
        else
            bad "not recognised on $L"
        fi
        "$BIN" --unmount "$L"
    else
        bad "no drive letter"; cat "$WORK/letter.log"
    fi
    wait $LPID 2>/dev/null
fi

echo "== module elsewhere"
if "$PLAYER" --is-waffle "$WORK/waffle.mod" >/dev/null 2>&1; then
    bad "a file in $WORK taken for a waffle-fuse disk"
else
    ok "not a waffle-fuse disk"
fi

# Linux: the desktop handler, in a home of its own.  A module that is not on a
# waffle-fuse disk goes to the application that had the type before.
if [ -z "$WINDOWS" ] && [ "$(uname -s)" = Linux ] && command -v xdg-mime >/dev/null 2>&1; then
    echo "== desktop handler (Linux)"
    H="$WORK/home"
    mkdir -p "$H/.local/share/applications" "$H/.config"
    # (no quotes in Exec: xdg-mime ignores an entry whose program it cannot find)
    printf '#!/bin/sh\necho "$1" > "%s/handed-over"\n' "$WORK" > "$WORK/other-player"
    chmod +x "$WORK/other-player"
    printf '[Desktop Entry]\nType=Application\nName=Other player\nExec=%s %%f\nMimeType=audio/x-mod;\n' \
        "$WORK/other-player" > "$H/.local/share/applications/other-player.desktop"
    (
        export HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" XDG_CURRENT_DESKTOP= DESKTOP_SESSION=
        printf '[Default Applications]\naudio/x-mod=other-player.desktop\n' > "$H/.config/mimeapps.list"
        [ "$(xdg-mime query default audio/x-mod)" = other-player.desktop ] || exit 10
        sh "$ROOT/scripts/install-desktop.sh" --no-autostart >/dev/null 2>&1
        [ "$(xdg-mime query default audio/x-mod)" = waffle-modplayer.desktop ] || exit 11
        # Handed over at once; if not, the window closes after 10 s and the test fails
        "$PLAYER" --mute --quit-after 10 "$WORK/waffle.mod" || exit 12
        for _ in $(seq 30); do [ -s "$WORK/handed-over" ] && break; sleep 0.1; done
        [ "$(cat "$WORK/handed-over" 2>/dev/null)" = "$WORK/waffle.mod" ] || exit 13
        sh "$ROOT/scripts/install-desktop.sh" --uninstall >/dev/null 2>&1
        [ "$(xdg-mime query default audio/x-mod)" = other-player.desktop ] || exit 14
    )
    case $? in
        0)  ok "default for .mod files; others handed to the previous player; given back on uninstall" ;;
        10) bad "cannot set up the previous player in the test home" ;;
        11) bad "install-desktop.sh did not make the player the default for audio/x-mod" ;;
        12) bad "the player failed on a module outside waffle-fuse" ;;
        13) bad "the module was not handed to the previous player" ;;
        14) bad "uninstall did not give audio/x-mod back" ;;
    esac
fi

echo ""
echo "Waffle ModPlayer: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
