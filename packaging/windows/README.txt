waffle-fuse for Windows (x86_64, Windows 10 1903 or later)
==========================================================

FUSE driver for the DrawBridge / Waffle Arduino floppy reader: Amiga (OFS/FFS)
and PC (FAT) floppies and .adf/.img images mounted as Windows drives.

1. Install WinFsp (free, signed by its author): https://winfsp.dev
   or:  winget install WinFsp.WinFsp
   (waffle-fuse-setup.exe installs it for you)

2. The easy way: start WaffleDiskFlashback.exe.  A floppy icon appears in the
   notification area; insert a disk and it is mounted on a free drive letter
   and opened in Explorer.  Click the icon for the menu: Eject (pending writes
   are completed first), copy the disk to an image file, write an image to the
   disk, open an .adf/.img image as a virtual disk, start at login, quit.
   Keep WaffleDiskFlashback.exe and waffle-fuse.exe together.

3. From the command line: open a Command Prompt or PowerShell in this
   folder.  The drive is a COM port (Device Manager -> Ports (COM & LPT),
   e.g. COM3):

     rem disk in the drive, as drive W:
     waffle-fuse COM3 W:

     rem the first free drive letter (the one used is printed)
     waffle-fuse COM3 *

     rem in %USERPROFILE%\Floppy\<volume name>
     waffle-fuse COM3 --automount %USERPROFILE%\Floppy

     rem disk image as a virtual disk
     waffle-fuse --image workbench.adf W:

   waffle-fuse stays in the foreground while the disk is mounted.  To unmount
   (pending writes are completed first), press Ctrl+C in its window, or from
   another window:

     waffle-fuse --unmount W:

   waffle-fuse --help lists all the options (copy a disk to an image file,
   write an image to a disk, format...).

Uninstall: Settings -> Apps -> Installed apps -> waffle-fuse if it was
installed with waffle-fuse-setup.exe; otherwise delete this folder.

Source and documentation: https://github.com/gianlucarenzi/waffle-fuse
