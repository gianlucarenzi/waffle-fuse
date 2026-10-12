# waffle-fuse and DiskFlashback

waffle-fuse was inspired by [DiskFlashback](https://robsmithdev.co.uk/diskflashback) by
Robert Smith ([RobSmithDev/DiskFlashback](https://github.com/RobSmithDev/DiskFlashback)), see
[Origins and thanks](../README.md#origins-and-thanks). The two projects share the idea, real
floppies and disk images used as drives of the computer, but they have different goals:
DiskFlashback covers many systems, formats and floppy controllers on Windows; waffle-fuse
covers the DrawBridge / Waffle drive with Amiga and PC floppies on Linux, macOS and Windows,
fitting into each desktop.

The DiskFlashback column is based on its
[README](https://github.com/RobSmithDev/DiskFlashback#features) (October 2026): check
there for its current features.

| | **DiskFlashback** | **waffle-fuse** |
|---|---|---|
| **Systems** | Windows | Linux, macOS 12+, Windows 10 1903+ |
| **Virtual drives through** | [Dokany](https://github.com/dokan-dev/dokany) | FUSE 3 (Linux), [FUSE-T](https://www.fuse-t.org) (macOS), [WinFsp](https://winfsp.dev) (Windows) |
| **Where disks appear** | drive letters in Explorer | Linux: `/media/$USER/<volume name>` and desktop icon; macOS: `~/Floppy/<volume name>` in the Finder; Windows: drive letters in Explorer |
| **Floppy controllers** | DrawBridge, Greaseweazle, SuperCard Pro (through [FloppyBridge](https://amiga.robsmithdev.co.uk/winuae)) | DrawBridge / Waffle |
| **Disk image files mounted** | ADF, DMS, IMG, IMA, ST, MSA, HDA, HDF, DSK (MSX), SCP (DMS, MSA and SCP read-only) | ADF, IMG |
| **Amiga filesystems** | OFS, FFS, PFS (floppies and hard disks) | OFS, FFS, INTL (`DOS0`–`DOS3`) read and write; DirCache (`DOS4`/`DOS5`) read-only |
| **PC filesystems** | FAT12/16, DD 720K and HD 1.44M | FAT12 (also FAT16) with VFAT long names, DD 720K and HD 1.44M |
| **Atari ST, MSX** | yes | no |
| **Dual/triple format Amiga/Atari disks** | yes, as two drives (read-only) | no |
| **Amiga hard disks and memory cards** | yes | no |
| **Insert / remove the disk** | the real floppy drive is a Windows drive | mounted automatically on insert, with the volume name; unmounted automatically on removal; eject writes the changes and says when the disk can be removed |
| **Copy a disk to a file** | yes (sector based files) | `.adf` / `.img` (sectors, also NDOS game disks), `.scp` (raw flux, also copy-protected disks) |
| **Write an image to a disk** | yes | yes, each track read back and verified |
| **Format disks, blank images** | yes, in a range of formats | Amiga OFS / FFS / INTL and PC FAT12, DD and HD |
| **Install Amiga boot blocks** | yes | no |
| **Amiga file extension swap** (`mod.name` ↔ `name.mod`) | yes, optional | no |
| **Head cleaner** | yes | no |
| **Tray app** | yes | Waffle DiskFlashback: tray (Linux, Windows), menu bar (macOS) |
| **Command line** | not in its README | `waffle-fuse`: mount, format, copy, write, scan, wait for a disk |
| **Built on** | ADFLib, FatFS, xDMS, pfs3aio, FloppyBridge | its own Amiga and FAT filesystem code; Robert Smith's DrawBridge interface code (`lib/`) |
| **Licence** | GPL-2.0 | GPL-3.0 |

If you are on Windows and use a Greaseweazle or a SuperCard Pro, disks of other systems,
DMS files or Amiga hard disks, DiskFlashback is the tool for you. If you use a DrawBridge /
Waffle on Linux or macOS, or want the same app on all three systems, waffle-fuse is.
