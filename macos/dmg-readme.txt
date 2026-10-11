Waffle DiskFlashback for macOS (Apple Silicon and Intel, macOS 12 or later)
==========================================================================

Amiga (OFS/FFS) and PC (FAT) floppies from the DrawBridge / Waffle drive in
the Finder: insert a disk and it is mounted in ~/Floppy/<volume name>.

1. Install FUSE-T (free for non-commercial use, no kernel extension):
   https://www.fuse-t.org  or  brew install macos-fuse-t/homebrew-cask/fuse-t

2. Drag "Waffle DiskFlashback" onto Applications.

3. Open it.  The app is not signed by an Apple developer, so the first time
   macOS refuses to open it: go to System Settings > Privacy & Security and
   click "Open Anyway" next to Waffle DiskFlashback.  Or, in the Terminal:

     xattr -dr com.apple.quarantine "/Applications/Waffle DiskFlashback.app"

A floppy icon appears in the menu bar (grey: waiting, orange: reading,
blue: disk mounted).  Its menu: Open, Eject, Mount again, Copy disk to image
file, Write image to disk, Start at login (macOS 13+), Quit.

* Eject from the menu or in the Finder before taking the disk out: pending
  changes are written first, then a notification says it can be removed.
* Floppy images (.adf, .img, .ima): right-click > Open With > Waffle
  DiskFlashback opens them as virtual disks.

The command line driver is inside the app:

  "/Applications/Waffle DiskFlashback.app/Contents/MacOS/waffle-fuse" --help

Source and documentation: https://github.com/gianlucarenzi/waffle-fuse
