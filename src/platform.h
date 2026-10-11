#pragma once
// waffle-fuse: small portability helpers (POSIX / Windows)

#include <ctime>

#ifdef _WIN32
static inline struct tm* localtime_r(const time_t* t, struct tm* result)
{
    return localtime_s(result, t) == 0 ? result : nullptr;
}
#endif

// Offset of local time from UTC at time t, in seconds (AmigaDOS and FAT keep
// local time, Unix and Windows UTC)
static inline long utcOffsetAt(time_t t)
{
    struct tm lt;
    localtime_r(&t, &lt);
#ifdef _WIN32
    return (long)(_mkgmtime(&lt) - t);
#else
    return lt.tm_gmtoff;
#endif
}
