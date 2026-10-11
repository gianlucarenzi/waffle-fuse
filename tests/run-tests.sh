#!/bin/bash
# Filesystem tests for waffle-fuse on disk images (no hardware needed).
#
# For every format a reference tree is copied onto a freshly formatted image
# through waffle-fuse, then files are moved, renamed, truncated, appended and
# deleted.  The result is checked three ways:
#   1. through the mounted filesystem itself,
#   2. after a remount (what really reached the image),
#   3. with independent tools: xdftool/xdfscan (amitools) for AmigaDOS,
#      pyfatfs + fsck.fat for FAT.
#
# Requirements: fusermount3 (Linux), FUSE-T (macOS, with GNU coreutils first
# in PATH) or WinFsp (Windows, run from an MSYS2 shell), mkfs.fat, fsck.fat;
# amitools (xdftool, xdfscan) and pyfatfs for the independent checks.  Point XDFTOOL, XDFSCAN and TEST_PYTHON at them if they
# are not in PATH (e.g. inside a virtualenv).
#
# Debugging: ONLY="FAT 720K" runs one suite, WAFFLE_DEBUG=1 mounts with the
# FUSE trace (-d), LOG_TAIL=N shows N driver log lines on each failure.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../waffle-fuse"
WINDOWS=
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WINDOWS=1; BIN="$BIN.exe" ;; esac
XDFTOOL="${XDFTOOL:-xdftool}"
XDFSCAN="${XDFSCAN:-xdfscan}"
TEST_PYTHON="${TEST_PYTHON:-python3}"
MKFS_FAT="$(command -v mkfs.fat || echo /sbin/mkfs.fat)"
FSCK_FAT="$(command -v fsck.fat || echo /sbin/fsck.fat)"

if [ -n "$WINDOWS" ]; then
    # WinFsp creates the directory of a mount and removes it on unmount
    is_mounted() { [ -d "$1" ]; }
    fuse_umount() { "$BIN" --unmount "$1"; }
    tree_diff() { diff -r "$1" "$2"; }
elif [ "$(uname -s)" = Darwin ]; then
    # A mountpoint is on another device than its parent directory.  The macOS
    # stat: GNU stat (coreutils first in PATH) reads -f %d as free inodes
    is_mounted() { [ -d "$1" ] && [ "$(/usr/bin/stat -f %d "$1" 2>/dev/null)" != "$(/usr/bin/stat -f %d "$1/.." 2>/dev/null)" ]; }
    fuse_umount() { umount "$1"; }
    # FUSE-T lists names decomposed (NFD): compare them in NFC form
    tree_diff() { "$TEST_PYTHON" "$HERE/treediff.py" "$1" "$2"; }
else
    is_mounted() { mountpoint -q "$1"; }
    fuse_umount() { fusermount3 -u "$1"; }
    tree_diff() { diff -r "$1" "$2"; }
fi

WORK="$(mktemp -d /tmp/waffle-test.XXXXXX)"
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

ok()   { echo "  ok   $*"; PASS=$((PASS+1)); }
bad()  {
    echo "  FAIL $*"; FAIL=$((FAIL+1))
    [ -s "$WORK/fuse.log" ] && { echo "       --- driver log:"; tail -"${LOG_TAIL:-15}" "$WORK/fuse.log" | sed 's/^/       /'; }
    return 0
}
check() { local what="$1"; shift; if "$@" >"$WORK/check.out" 2>&1; then ok "$what"; else bad "$what"; sed 's/^/       /' "$WORK/check.out" | head -20; fi; }

mount_img() {
    local img="$1"; shift
    "$BIN" --image "$img" "$MNT" -f ${WAFFLE_DEBUG:+-d} "$@" >"$WORK/fuse.log" 2>&1 &
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
    # The driver must exit once unmounted: give it 20 s, then kill it
    for _ in $(seq 200); do
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$PID" 2>/dev/null; then
        echo "       driver still running 20 s after unmount: killed"
        kill -9 "$PID"; wait "$PID" 2>/dev/null; PID=
        return 1
    fi
    wait "$PID"
    local rc=$?
    PID=
    return $rc
}

# Deterministic pseudo-random file of a given size
mkfile() { head -c "$2" /dev/urandom > "$1"; }

# Reference tree.  $1 = dir, $2 = 1 if long names (> 30 chars) are allowed
make_ref() {
    local d="$1" long="$2"
    mkdir -p "$d/Dir One/Nested" "$d/dir2" "$d/many"
    for s in 0 1 487 488 489 512 513 5000; do mkfile "$d/f$s" "$s"; done
    mkfile "$d/big40k" 40000            # > 72 blocks: needs an extension block
    mkfile "$d/big150k.bin" 150000      # several extension blocks / long FAT chain
    mkfile "$d/Dir One/inner.dat" 3000
    mkfile "$d/Dir One/Nested/deep.txt" 700
    echo "hello amiga" > "$d/ReadMe.TXT"
    echo "small" > "$d/small.txt"
    echo "lettera" > "$d/Lettera all'ufficio.txt"
    echo "accenti" > "$d/Città è più.txt"
    if [ "$long" = 1 ]; then
        echo "long" > "$d/A very long file name that does not fit in 8.3.text"
    fi
    for i in $(seq 1 40); do echo "file $i" > "$d/many/Entry number $i.txt"; done
}

# Apply the same modifications to the mounted fs ($1) and to the expected tree ($2)
mutate() {
    local m
    for m in "$1" "$2"; do
        mv "$m/small.txt" "$m/Dir One/moved.txt" &&
        mv "$m/dir2" "$m/Dir One/Nested/dir2moved" &&
        rm "$m/f1" &&
        echo "new content" > "$m/f5000" &&
        head -c 777 /dev/zero >> "$m/big40k" &&
        truncate -s 100 "$m/big150k.bin" &&
        truncate -s 3000 "$m/f487" &&
        # case-only rename in two steps: macOS sees one file under both names
        mv "$m/ReadMe.TXT" "$m/readme.tmp" && mv "$m/readme.tmp" "$m/readme.txt" &&
        mkdir "$m/tmpdir" && rmdir "$m/tmpdir" &&
        rm "$m/many/Entry number 7.txt" &&
        mv "$m/many/Entry number 8.txt" "$m/many/Renamed eight.txt" || return 1
    done
}

run_suite() {
    local name="$1" img="$2" kind="$3" long="$4"
    [ -n "${ONLY:-}" ] && [ "$name" != "$ONLY" ] && return
    echo "== $name"
    rm -rf "$WORK/ref" "$WORK/exp" "$WORK/out"
    make_ref "$WORK/ref" "$long"
    cp -a "$WORK/ref" "$WORK/exp"

    mount_img "$img" || { bad "$name: mount"; return; }
    check "copy reference tree" cp -r "$WORK/ref/." "$MNT/"
    check "tree matches while mounted" tree_diff "$WORK/ref" "$MNT"
    check "move/rename/truncate/append/delete" mutate "$MNT" "$WORK/exp"
    check "modified tree matches while mounted" tree_diff "$WORK/exp" "$MNT"
    if [ "$kind" = affs ] && [ "$long" = 0 ]; then
        if touch "$MNT/This name is definitely longer than thirty chars" 2>/dev/null; then
            bad "names > 30 chars must be rejected"
        else
            ok "names > 30 chars rejected"
        fi
    fi
    # Disk full: the copy must fail cleanly and leave a consistent filesystem
    local avail
    if [ -n "$WINDOWS" ]; then
        avail=$(stat -c %s "$img")      # df sees the volume holding the mount directory
    else
        avail=$(df --output=avail -B1 "$MNT" | tail -1)
    fi
    mkfile "$WORK/toobig" $((avail + 20000))
    if cp "$WORK/toobig" "$MNT/toobig" 2>/dev/null; then
        bad "disk full reported (df avail $avail bytes, copied $(stat -c %s "$MNT/toobig" 2>/dev/null) of $((avail + 20000)))"
    else
        ok "disk full reported"
    fi
    rm -f "$MNT/toobig"
    check "tree intact after disk full" tree_diff "$WORK/exp" "$MNT"
    check "unmount" umount_img

    mount_img "$img" || { bad "$name: remount"; return; }
    check "tree matches after remount" tree_diff "$WORK/exp" "$MNT"
    umount_img

    if [ "$kind" = affs ]; then
        if command -v "$XDFSCAN" >/dev/null 2>&1; then
            check "xdfscan: no errors or warnings" bash -c "out=\$('$XDFSCAN' -l 2 '$img' 2>&1); echo \"\$out\"; ! echo \"\$out\" | grep -qiE 'error|warn'"
            mkdir -p "$WORK/out"
            "$XDFTOOL" "$img" unpack "$WORK/out" >/dev/null 2>&1
            local vol; vol="$(ls "$WORK/out" | grep -v xdfmeta | head -1)"
            check "xdftool extraction matches" diff -r -x '*.xdfmeta' "$WORK/exp" "$WORK/out/$vol"
        else
            echo "  skip independent AmigaDOS checks (amitools not found)"
        fi
    else
        check "fsck.fat: clean" "$FSCK_FAT" -n "$img"
        if "$TEST_PYTHON" -c "import pyfatfs" 2>/dev/null; then
            check "pyfatfs extraction matches" bash -c "'$TEST_PYTHON' '$HERE/extract.py' '$img' '$WORK/out' && diff -r '$WORK/exp' '$WORK/out'"
        else
            echo "  skip pyfatfs check (not installed)"
        fi
    fi
}

# ── Amiga ────────────────────────────────────────────────────────────────────
if command -v "$XDFTOOL" >/dev/null 2>&1; then
    for t in "ofs DD" "ffs DD" "ffs+intl DD" "ffs HD"; do
        set -- $t
        img="$WORK/amiga-$1-$2.adf"
        if [ "$2" = HD ]; then
            "$XDFTOOL" "$img" create size=1760Ki + format "Test Volume" "$1" >/dev/null
        else
            "$XDFTOOL" "$img" format "Test Volume" "$1" >/dev/null
        fi
        run_suite "Amiga $1 $2" "$img" affs 0
    done
else
    echo "== Amiga: skipped (xdftool not found, set XDFTOOL)"
fi

# ── FAT ──────────────────────────────────────────────────────────────────────
for kb in 720 1440; do
    img="$WORK/fat-$kb.img"
    "$MKFS_FAT" -C -n "WAFFLE" "$img" "$kb" >/dev/null
    run_suite "FAT ${kb}K" "$img" fat 1
done

# ── Images formatted by waffle-fuse itself ───────────────────────────────────
for t in "ofs dd" "ffs hd" "amiga-intl dd"; do
    set -- $t
    img="$WORK/wf-$1-$2.adf"
    "$BIN" --format-image "$img" "$1" "$2" "Test Volume" 2>/dev/null
    run_suite "waffle-fuse format: $1 $2" "$img" affs 0
done
for d in dd hd; do
    img="$WORK/wf-dos-$d.img"
    "$BIN" --format-image "$img" dos "$d" "WAFFLE" 2>/dev/null
    run_suite "waffle-fuse format: dos $d" "$img" fat 1
done

if [ -n "${ONLY:-}" ]; then
    echo; echo "passed: $PASS  failed: $FAIL"
    [ "$FAIL" -eq 0 ]; exit
fi

# ── Read-only mount ──────────────────────────────────────────────────────────
echo "== read-only image"
img="$WORK/ro.img"
"$MKFS_FAT" -C "$img" 720 >/dev/null
mount_img "$img" -o ro || bad "ro mount"
if touch "$MNT/x" 2>/dev/null; then bad "write refused on ro mount"; else ok "write refused on ro mount"; fi
umount_img

# ── Background mode (no -f, as the desktop launchers use it) ─────────────────
echo "== background mode"
if [ -n "$WINDOWS" ]; then
    echo "  skip (on Windows waffle-fuse always stays in the foreground)"
elif "$BIN" --image "$WORK/fat-720.img" --automount "$WORK/bg" >"$WORK/bg.log" 2>&1; then
    BGMNT="$(sed -n 's/^WAFFLE event=mounted mountpoint=//p' "$WORK/bg.log")"
    if [ -n "$BGMNT" ] && is_mounted "$BGMNT" && ls "$BGMNT" >/dev/null; then
        ok "mounted and readable after going to the background"
        fuse_umount "$BGMNT"
        for _ in $(seq 100); do [ -d "$BGMNT" ] || break; sleep 0.1; done
        [ ! -d "$BGMNT" ] && ok "driver exits and removes the mountpoint" || bad "driver exits and removes the mountpoint"
    else
        bad "mounted and readable after going to the background"; cat "$WORK/bg.log"
    fi
else
    bad "background mount"; cat "$WORK/bg.log"
fi

# ── Automount directory naming ───────────────────────────────────────────────
echo "== automount"
"$BIN" --image "$WORK/fat-720.img" --automount "$WORK/auto" -f >"$WORK/auto.log" 2>&1 &
PID=$!
for _ in $(seq 50); do is_mounted "$WORK/auto/WAFFLE" && break; sleep 0.1; done
if is_mounted "$WORK/auto/WAFFLE"; then
    ok "mounted on <dir>/<volume label>"
    # On macOS the event follows the mount by up to 50 ms (the driver waits to see it)
    for _ in $(seq 50); do grep -q "^WAFFLE event=mounted" "$WORK/auto.log" && break; sleep 0.1; done
    expected="$WORK/auto/WAFFLE"
    [ -n "$WINDOWS" ] && expected="$(cygpath -w "$expected")"
    grep -qF "WAFFLE event=mounted mountpoint=$expected" "$WORK/auto.log" && ok "mounted event" || bad "mounted event"
    if [ -n "$WINDOWS" ]; then
        [ ! -e "$WORK/auto/WAFFLE/.xdg-volume-info" ] && ok "no .xdg-volume-info on Windows" || bad "no .xdg-volume-info on Windows"
        if mkdir "$WORK/auto/WAFFLE/\$RECYCLE.BIN" 2>/dev/null; then bad "Recycle Bin refused"; else ok "Recycle Bin refused"; fi
    else
        grep -qx "Name=WAFFLE" "$WORK/auto/WAFFLE/.xdg-volume-info" && grep -qx "Icon=waffle-dos-floppy" "$WORK/auto/WAFFLE/.xdg-volume-info" \
            && grep -qx "IconFile=.waffle-icon.svg" "$WORK/auto/WAFFLE/.xdg-volume-info" \
            && ok "virtual .xdg-volume-info (name and icon)" || bad "virtual .xdg-volume-info"
        grep -q "<svg" "$WORK/auto/WAFFLE/.waffle-icon.svg" && ok "virtual volume icon" || bad "virtual volume icon"
    fi
    if mkdir "$WORK/auto/WAFFLE/.Trash-$(id -u)" 2>/dev/null; then bad ".Trash folder refused"; else ok ".Trash folder refused"; fi
    fuse_umount "$WORK/auto/WAFFLE"; wait "$PID"; PID=
    if "$TEST_PYTHON" -c "import pyfatfs" 2>/dev/null; then
        rm -rf "$WORK/auto-out"
        "$TEST_PYTHON" "$HERE/extract.py" "$WORK/fat-720.img" "$WORK/auto-out" 2>/dev/null
        [ ! -e "$WORK/auto-out/.xdg-volume-info" ] && [ ! -e "$WORK/auto-out/.waffle-icon.svg" ] \
            && ok "volume info never written to the disk" || bad "volume info written to the disk"
    fi
    [ ! -e "$WORK/auto/WAFFLE" ] && ok "mountpoint removed after unmount" || bad "mountpoint removed after unmount"
else
    bad "automount"; cat "$WORK/auto.log"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
