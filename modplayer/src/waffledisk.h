// Waffle ModPlayer – is a file on a disk mounted by waffle-fuse?
//
//   Linux    the mount source in /proc/self/mountinfo is "waffle:<drive or image>"
//   macOS    the same, in the mount's f_mntfromname (FUSE-T); or the volume
//            icon waffle-fuse serves at the root of the volume
//   Windows  the file system of the drive is FUSE-AFFS or FUSE-FAT (WinFsp)

#pragma once

#include <QString>

struct WaffleDisk
{
    bool found = false;
    QString root;       // mountpoint or drive ("/media/me/WaffleDemo", "Z:\")
};

WaffleDisk waffleDiskOf(const QString &path);

// Linux: open the file with the application that had its type before the
// player was installed (as scripts/waffle-open-image.py does for images).
// false when there is none.
bool handOverToPreviousApp(const QString &path);
