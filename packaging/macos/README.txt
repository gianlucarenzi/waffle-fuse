waffle-fuse for macOS (Apple Silicon and Intel, macOS 12 or later)
=================================================================

FUSE driver for the DrawBridge / Waffle Arduino floppy reader: Amiga (OFS/FFS)
and PC (FAT) floppies and .adf/.img images mounted as volumes in the Finder.
There is no menu bar app yet (disks are not mounted automatically on insert).

1. Install FUSE-T (free for non-commercial use, no kernel extension):
   https://www.fuse-t.org  or  brew install macos-fuse-t/homebrew-cask/fuse-t

2. The files are not signed by an Apple developer: remove the download
   quarantine from this folder first, or macOS refuses to run them:

     xattr -dr com.apple.quarantine .

   Optionally install the command (asks for your password):

     sudo install -m 755 waffle-fuse /usr/local/bin/

3. The easy way: double-click "Waffle Floppy.command" in the Finder.  It finds
   the drive, mounts the inserted floppy under ~/Floppy/<volume name> and opens
   it in the Finder; double-click it again to eject the disk (pending writes
   are completed first, then a notification says the disk can be removed).
   Keep "Waffle Floppy.command", waffle-mount.sh and waffle-fuse together.

4. From the Terminal.  The drive is a serial port named /dev/cu.usbserial-* or
   /dev/cu.usbmodem* (ls /dev/cu.*):

     # disk in the drive, mounted under ~/Floppy/<volume name>
     waffle-fuse /dev/cu.usbserial-XXXX --automount ~/Floppy

     # disk image as a virtual disk
     mkdir -p ~/wb && waffle-fuse --image workbench.adf ~/wb

     # unmount (pending writes are completed first)
     umount ~/Floppy/<volume name>

   waffle-fuse --help lists all the options (copy a disk to an image file,
   write an image to a disk, format...).

Uninstall: delete this folder (and sudo rm /usr/local/bin/waffle-fuse).

Source, Linux packages and documentation:
https://github.com/gianlucarenzi/waffle-fuse
