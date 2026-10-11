waffle-fuse for macOS (Apple Silicon and Intel, macOS 12 or later)
=================================================================

FUSE driver for the DrawBridge / Waffle Arduino floppy reader: Amiga (OFS/FFS)
and PC (FAT) floppies and .adf/.img images mounted as volumes in the Finder.
This is the command line driver; there is no menu bar app yet.

1. Install FUSE-T (free for non-commercial use, no kernel extension):
   https://www.fuse-t.org  or  brew install macos-fuse-t/homebrew-cask/fuse-t

2. Install waffle-fuse (asks for your password):

     sudo install -m 755 waffle-fuse /usr/local/bin/

   The binary is not signed by an Apple developer: if macOS refuses to run it,
   remove the download quarantine first:

     xattr -d com.apple.quarantine waffle-fuse

3. Use it.  The drive is a serial port named /dev/cu.usbserial-* or
   /dev/cu.usbmodem* (ls /dev/cu.*):

     # disk in the drive, mounted under ~/Floppy/<volume name>
     waffle-fuse /dev/cu.usbserial-XXXX --automount ~/Floppy

     # disk image as a virtual disk
     mkdir -p ~/wb && waffle-fuse --image workbench.adf ~/wb

     # unmount (pending writes are completed first)
     umount ~/Floppy/<volume name>

   waffle-fuse --help lists all the options (copy a disk to an image file,
   write an image to a disk, format...).

Uninstall: sudo rm /usr/local/bin/waffle-fuse

Source, Linux packages and documentation:
https://github.com/gianlucarenzi/waffle-fuse
