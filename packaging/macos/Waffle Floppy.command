#!/bin/sh
# Double-click in the Finder: mount the floppy in the DrawBridge/Waffle drive
# under ~/Floppy and open it, or eject it if it is already mounted.
exec "$(dirname "$0")/waffle-mount.sh" "$@"
