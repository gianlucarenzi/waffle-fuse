#!/bin/bash
# Build the Windows installer of waffle-fuse with Inno Setup 7 (a 64-bit
# installer; Inno Setup 6 also works and builds a 32-bit one):
# dist/waffle-fuse-setup-<version>.exe, from waffle-fuse.exe (run make first).
#
# Usage: windows/make-installer.sh [version]
#
# On Windows (MSYS2 shell) ISCC.exe is looked for in Program Files; on Linux it
# runs through wine (Inno Setup installed in the default wine prefix).  Set
# ISCC to the path of ISCC.exe, WINE to another wine command, if needed.
# The WinFsp MSI bundled in the installer is downloaded once into
# windows/build/ and checked against its SHA-256.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-0.0.0}"

WINFSP_VERSION=2.1
WINFSP_MSI=winfsp-2.1.25156.msi
WINFSP_SHA256=073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a

if [ ! -f "$HERE/../waffle-fuse.exe" ] || [ ! -f "$HERE/../WaffleDiskFlashback.exe" ]; then
    echo "make-installer: build waffle-fuse.exe and WaffleDiskFlashback.exe first (make)" >&2
    exit 1
fi

mkdir -p "$HERE/build" "$HERE/../dist"
MSI="$HERE/build/winfsp.msi"
if ! echo "$WINFSP_SHA256  $MSI" | sha256sum -c --status 2>/dev/null; then
    echo "make-installer: downloading WinFsp $WINFSP_VERSION"
    curl -fsSL -o "$MSI.part" "https://github.com/winfsp/winfsp/releases/download/v$WINFSP_VERSION/$WINFSP_MSI"
    echo "$WINFSP_SHA256  $MSI.part" | sha256sum -c --quiet -
    mv "$MSI.part" "$MSI"
fi

# File version: the numeric part of the version (0.0.0.dev12 -> 0.0.0)
NUMERIC="$(echo "$VERSION" | sed -E 's/^([0-9]+(\.[0-9]+){0,3}).*/\1/')"
[[ "$NUMERIC" =~ ^[0-9]+(\.[0-9]+)*$ ]] || NUMERIC=0.0.0

# Inno Setup 7 (64-bit edition first), else Inno Setup 6, under the given root
find_iscc() {
    local d
    for d in "Program Files/Inno Setup 7" "Program Files (x86)/Inno Setup 7" "Program Files (x86)/Inno Setup 6"; do
        [ -f "$1/$d/ISCC.exe" ] && { echo "$1/$d/ISCC.exe"; return; }
    done
    echo "$1/Program Files/Inno Setup 7/ISCC.exe"
}

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        ISCC="${ISCC:-$(find_iscc /c)}"
        RUN=()
        ISS="$(cygpath -w "$HERE/waffle-fuse.iss")"
        # Keep MSYS2 from turning the /D... options into paths
        export MSYS2_ARG_CONV_EXCL='*'
        ;;
    *)
        ISCC="${ISCC:-$(find_iscc "${WINEPREFIX:-$HOME/.wine}/drive_c")}"
        RUN=("${WINE:-wine}")
        ISS="$(winepath -w "$HERE/waffle-fuse.iss" 2>/dev/null)"
        ;;
esac

if [ ! -f "$ISCC" ]; then
    echo "make-installer: Inno Setup not found ($ISCC): install Inno Setup 7 from https://jrsoftware.org or set ISCC" >&2
    exit 1
fi

"${RUN[@]}" "$ISCC" /Q "/DAppVersion=$VERSION" "/DNumericVersion=$NUMERIC" \
    "/DWinFspVersion=$WINFSP_VERSION" "$ISS"
ls -l "$HERE/../dist/waffle-fuse-setup-$VERSION.exe"
