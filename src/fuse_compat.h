#pragma once
// waffle-fuse: one include for the FUSE 3 API on every platform
//
// Linux: libfuse3; macOS: FUSE-T; Windows: the FUSE 3 layer of WinFsp
// (https://winfsp.dev).  The filesystem callbacks use the fuse_*_t types
// below: on Windows WinFsp has its own stat, statvfs and timespec structures.
//
// On Windows the WinFsp DLL is not linked: it lives in the WinFsp install
// directory, not on the PATH.  Every API function becomes a pointer, filled in
// by winfsp_load() (winfsp_load.cpp) from the DLL found through the registry.

#define FUSE_USE_VERSION 31

#ifdef _WIN32

#define FSP_FUSE_API            extern
#define FSP_FUSE_API_NAME(n)    (*n##_ptr)
#define FSP_FUSE_API_CALL(n)    (n##_ptr)
#include <fuse3/fuse.h>

#include <ctime>
#include <sys/stat.h>

// WinFsp's FUSE_OPT_KEY puts -1 in an unsigned field: an error in C++
#undef FUSE_OPT_KEY
#define FUSE_OPT_KEY(templ, key) { templ, (unsigned int)-1, key }

// From WinFsp's FUSE 2 headers; the FUSE 3 layer passes it on
#ifndef FSP_FUSE_CAP_READ_ONLY
#define FSP_FUSE_CAP_READ_ONLY (1 << 22)
#endif

typedef struct fuse_stat     fuse_stat_t;
typedef struct fuse_statvfs  fuse_statvfs_t;
typedef struct fuse_timespec fuse_timespec_t;

// WinFsp has only the nanosecond fields of a Linux struct stat
#define st_atime st_atim.tv_sec
#define st_mtime st_mtim.tv_sec
#define st_ctime st_ctim.tv_sec

// WinFsp uses the Linux values for these
#ifndef S_IFLNK
#define S_IFLNK 0120000
#endif
#ifndef UTIME_NOW
#define UTIME_NOW  ((1l << 30) - 1l)
#define UTIME_OMIT ((1l << 30) - 2l)
#endif

// The owner of every file is the user who mounted (-o uid=-1,gid=-1)
static inline fuse_uid_t getuid() { return 0; }
static inline fuse_gid_t getgid() { return 0; }

// Load the WinFsp DLL; false (with a message on stderr) if WinFsp is missing
bool winfsp_load();

#else

#include <fuse3/fuse.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

typedef struct stat     fuse_stat_t;
typedef struct statvfs  fuse_statvfs_t;
typedef struct timespec fuse_timespec_t;
typedef off_t           fuse_off_t;
typedef mode_t          fuse_mode_t;
typedef uid_t           fuse_uid_t;
typedef gid_t           fuse_gid_t;

#endif

#include <fcntl.h>
#include "platform.h"
