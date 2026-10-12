#!/bin/bash
# Build the example floppy images in docs/examples with waffle-fuse itself:
#   WaffleDemo.adf   Amiga 880K, FFS, volume "WaffleDemo"
#   WAFFLEDOS.img    PC 720K, FAT12, label "WAFFLEDOS"
# Each one is formatted by waffle-fuse, mounted, filled with a few files and
# folders, and unmounted.  Linux (fusermount3) or macOS (FUSE-T).
#
# Usage: docs/examples/make-examples.sh [waffle-fuse binary]

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${1:-$HERE/../../waffle-fuse}"
WORK="$(mktemp -d)"
MNT="$WORK/mnt"
trap 'rm -rf "$WORK"' EXIT

if [ "$(uname -s)" = Darwin ]; then
    is_mounted() { [ "$(/usr/bin/stat -f %d "$1")" != "$(/usr/bin/stat -f %d "$1/..")" ]; }
    unmount() { umount "$1"; }
else
    is_mounted() { mountpoint -q "$1"; }
    unmount() { fusermount3 -u "$1"; }
fi

# fill <mounted dir>: the same small tree on both disks
fill() {
    local d="$1"
    mkdir -p "$d/Docs" "$d/Pictures" "$d/Data"
    cat > "$d/ReadMe.txt" <<'EOF'
Welcome to waffle-fuse!

This floppy image is mounted by waffle-fuse, the FUSE driver for the
DrawBridge / Waffle floppy reader: the same files would be on a real
disk in the drive.  Add, rename and delete files as you like.

https://github.com/gianlucarenzi/waffle-fuse
EOF
    cat > "$d/Docs/Formats.txt" <<'EOF'
Amiga 880K / 1.76M   OFS, FFS, INTL   read + write
Amiga DirCache       DOS4, DOS5       read-only
PC 720K / 1.44M      FAT12, VFAT      read + write
EOF
    printf 'Lettera all'"'"'ufficio\nCittà, è più bello con i floppy.\n' > "$d/Docs/Lettera.txt"
    # A small picture and a 4 KB binary file
    cp "$HERE/../../icons/amiga-floppy.svg" "$d/Pictures/floppy.svg"
    head -c 4096 /dev/zero | tr '\0' '\125' > "$d/Data/pattern.bin"
    date -u '+Created %Y-%m-%d by docs/examples/make-examples.sh' > "$d/Created.txt"
}

# make <image> <format args...>
make_image() {
    local img="$1"; shift
    rm -f "$img"
    "$BIN" --format-image "$img" "$@"
    mkdir -p "$MNT"
    "$BIN" --image "$img" "$MNT" -f >"$WORK/log" 2>&1 &
    local pid=$!
    for _ in $(seq 50); do is_mounted "$MNT" && break; sleep 0.1; done
    is_mounted "$MNT" || { cat "$WORK/log"; exit 1; }
    fill "$MNT"
    unmount "$MNT"
    wait "$pid"
    echo "made $img"
}

make_image "$HERE/WaffleDemo.adf" ffs dd WaffleDemo
make_image "$HERE/WAFFLEDOS.img" dos dd WAFFLEDOS
