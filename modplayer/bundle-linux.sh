#!/bin/sh
# bundle-linux.sh – Waffle ModPlayer with its own Qt 6, for the Linux packages:
# the player runs on any distribution (glibc 2.28 or newer, as the official Qt
# 6.8 binaries) without Qt installed.
#
#   modplayer/bundle-linux.sh <waffle-modplayer> <Qt prefix> <output dir>
#
#   <output dir>/waffle-modplayer        RUNPATH $ORIGIN/lib (build it with
#                                         -DMODPLAYER_BUNDLE=ON)
#   <output dir>/lib/                     the Qt libraries it needs, ICU, and
#                                         the small xcb libraries that Qt's X11
#                                         plugin needs and many systems lack
#   <output dir>/plugins/                 platform (X11, Wayland, offscreen),
#                                         input method and portal plugins
#   <output dir>/qt.conf                  plugins next to the binary
#
# Left to the system, as every desktop has them: glibc, libstdc++, libX11 and
# libxcb, Wayland, OpenGL/EGL, fontconfig, freetype, GLib, D-Bus, xkbcommon.  libmikmod
# is linked statically (build-libmikmod.sh).

set -e

BIN="$1"
QT="$2"
OUT="$3"
if [ ! -x "$BIN" ] || [ ! -d "$QT/lib" ] || [ -z "$OUT" ]; then
    echo "Usage: $0 <waffle-modplayer> <Qt prefix> <output dir>" >&2
    exit 1
fi

# System libraries that are bundled anyway: needed by the Qt X11 plugin, each
# one a package of its own on Debian and Ubuntu, and often missing (libxcb-cursor0
# and libxcb-shape0 above all).  Small, and stable on top of libxcb.so.1.
XCB_UTIL="libxcb-cursor.so.0 libxcb-icccm.so.4 libxcb-image.so.0 libxcb-keysyms.so.1
          libxcb-render-util.so.0 libxcb-util.so.1 libxkbcommon-x11.so.0
          libxcb-randr.so.0 libxcb-render.so.0 libxcb-shape.so.0 libxcb-shm.so.0
          libxcb-sync.so.1 libxcb-xfixes.so.0 libxcb-xkb.so.1 libX11-xcb.so.1"

PLUGINS="platforms/libqxcb.so platforms/libqwayland-generic.so platforms/libqwayland-egl.so
         platforms/libqoffscreen.so platforms/libqminimal.so
         xcbglintegrations wayland-decoration-client wayland-shell-integration
         wayland-graphics-integration-client
         platforminputcontexts/libcomposeplatforminputcontextplugin.so
         platformthemes/libqxdgdesktopportal.so"

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/plugins"
install -m 755 "$BIN" "$OUT/waffle-modplayer"

for p in $PLUGINS; do
    if [ -d "$QT/plugins/$p" ]; then
        mkdir -p "$OUT/plugins/$p"
        cp "$QT/plugins/$p"/*.so "$OUT/plugins/$p/"
    elif [ -f "$QT/plugins/$p" ]; then
        mkdir -p "$OUT/plugins/$(dirname "$p")"
        cp "$QT/plugins/$p" "$OUT/plugins/$p"
    fi
done

needed() { readelf -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'; }
system_lib() { "$(command -v ldconfig || echo /sbin/ldconfig)" -p | awk -v n="$1" '$1 == n && /x86-64/ { print $NF; exit }'; }

# Follow the NEEDED entries from the binary and the plugins, copying what
# comes from Qt (and the xcb-util libraries)
QUEUE="$OUT/waffle-modplayer $(find "$OUT/plugins" -name '*.so')"
while [ -n "$QUEUE" ]; do
    set -- $QUEUE
    f="$1"; shift
    QUEUE="$*"
    for n in $(needed "$f"); do
        [ -e "$OUT/lib/$n" ] && continue
        src=
        if [ -e "$QT/lib/$n" ]; then
            src="$QT/lib/$n"
        else
            case " $(echo $XCB_UTIL) " in *" $n "*) src="$(system_lib "$n")" ;; esac
            [ -n "$src" ] || { case " $(echo $XCB_UTIL) " in *" $n "*) echo "warning: $n not found on this system" >&2 ;; esac; continue; }
        fi
        cp -L "$src" "$OUT/lib/$n"
        chmod 644 "$OUT/lib/$n"
        QUEUE="$QUEUE $OUT/lib/$n"
    done
done

install -m 644 "$(dirname "$0")/THIRD-PARTY-NOTICES.txt" "$OUT/"

# Qt finds its plugins through qt.conf, next to the binary
printf '[Paths]\nPrefix = .\nPlugins = plugins\n' > "$OUT/qt.conf"

# Every library looks for the others next to itself: Qt's own have RUNPATH
# $ORIGIN; the plugins $ORIGIN/../../lib.  The system ones copied here need nothing.
echo "Bundled in $OUT:"
ls "$OUT/lib"
du -sh "$OUT"
