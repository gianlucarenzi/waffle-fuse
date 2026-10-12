// Waffle ModPlayer – waffle-fuse disks (see waffledisk.h)

#include "waffledisk.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMimeDatabase>
#include <QProcess>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QTextStream>
#include <cstdio>

#ifdef Q_OS_WIN
#include <windows.h>
#elif defined(Q_OS_MACOS)
#include <sys/mount.h>
#include <sys/param.h>
#endif

#ifdef Q_OS_LINUX
// /proc/self/mountinfo writes space, tab, newline and backslash as \ooo
static QString unescapeMountField(const QString &s)
{
    static const QRegularExpression octal("\\\\([0-7]{3})");
    QString out = s;
    QRegularExpressionMatch m;
    for (qsizetype pos = 0; (m = octal.match(out, pos)).hasMatch(); pos = m.capturedStart() + 1)
        out.replace(m.capturedStart(), m.capturedLength(), QChar(m.captured(1).toInt(nullptr, 8)));
    return out;
}
#endif

WaffleDisk waffleDiskOf(const QString &path)
{
    WaffleDisk disk;
#ifdef Q_OS_WIN
    // As given: on a WinFsp drive letter the canonical path is a \\?\ device
    // path, where Windows does not find the volume
    const QString file = QFileInfo(path).absoluteFilePath();
    if (!QFileInfo::exists(file))
    {
        if (qEnvironmentVariableIsSet("WAFFLE_MODPLAYER_DEBUG"))
            std::fprintf(stderr, "%s: not found\n", qPrintable(QDir::toNativeSeparators(file)));
        return disk;
    }
#else
    const QString file = QFileInfo(path).canonicalFilePath();
    if (file.isEmpty()) return disk;
#endif

#if defined(Q_OS_LINUX)
    // The mount that holds the file is the one with the longest mountpoint
    // that is a prefix of its path
    QFile f("/proc/self/mountinfo");
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return disk;
    QString bestMount, bestSource;
    QTextStream in(&f);
    for (QString line = in.readLine(); !line.isNull(); line = in.readLine())
    {
        // id parent major:minor root mountpoint options [optional...] - fstype source superoptions
        const QStringList fields = line.split(' ');
        const int dash = int(fields.indexOf("-"));
        if (fields.size() < 5 || dash < 0 || dash + 2 >= fields.size()) continue;
        const QString mnt = unescapeMountField(fields[4]);
        const bool holds = mnt == "/" || file == mnt || file.startsWith(mnt + '/');
        if (holds && mnt.size() >= bestMount.size())
        {
            bestMount = mnt;
            bestSource = unescapeMountField(fields[dash + 2]);
        }
    }
    if (bestSource.startsWith("waffle:"))
    {
        disk.found = true;
        disk.root = bestMount;
        disk.name = QFileInfo(bestMount).fileName();
    }
#elif defined(Q_OS_MACOS)
    struct statfs st;
    if (statfs(QFile::encodeName(file).constData(), &st) != 0) return disk;
    const QString root = QFile::decodeName(st.f_mntonname);
    const QString from = QFile::decodeName(st.f_mntfromname);
    // FUSE-T serves the mount over NFS: the source may not keep the fsname, but
    // the volume icon of waffle-fuse is always at the root
    if (from.contains("waffle:") || QFileInfo::exists(root + "/.waffle-icon.svg"))
    {
        disk.found = true;
        disk.root = root;
        disk.name = QFileInfo(root).fileName();
    }
#elif defined(Q_OS_WIN)
    const std::wstring native = QDir::toNativeSeparators(file).toStdWString();
    wchar_t volume[MAX_PATH] = {0}, label[MAX_PATH] = {0}, fsName[MAX_PATH] = {0};
    const bool debug = qEnvironmentVariableIsSet("WAFFLE_MODPLAYER_DEBUG");
    // The volume holding the file: a directory mount (WinFsp mounts disks on
    // folders too) or the drive.  WinFsp drive letters are not known to the
    // mount manager: GetVolumePathName fails on them (error 1005), or gives a
    // folder of the drive that is no volume root (error 144 next).  Then the
    // drive letter is the volume.
    const bool onDrive = native.size() >= 3 && native[1] == L':' && native[2] == L'\\';
    auto useDrive = [&] {
        volume[0] = native[0];
        volume[1] = L':';
        volume[2] = L'\\';
        volume[3] = 0;
    };
    if (!GetVolumePathNameW(native.c_str(), volume, MAX_PATH))
    {
        if (debug) std::fprintf(stderr, "GetVolumePathName(%ls): error %lu\n", native.c_str(), GetLastError());
        if (!onDrive) return disk;
        useDrive();
    }
    if (!GetVolumeInformationW(volume, label, MAX_PATH, nullptr, nullptr, nullptr, fsName, MAX_PATH))
    {
        if (debug) std::fprintf(stderr, "GetVolumeInformation(%ls): error %lu\n", volume, GetLastError());
        if (!onDrive) return disk;
        useDrive();
        if (!GetVolumeInformationW(volume, label, MAX_PATH, nullptr, nullptr, nullptr, fsName, MAX_PATH))
        {
            if (debug) std::fprintf(stderr, "GetVolumeInformation(%ls): error %lu\n", volume, GetLastError());
            return disk;
        }
    }
    if (debug) std::fprintf(stderr, "%ls: volume %ls, label %ls, file system %ls\n", native.c_str(), volume, label, fsName);
    // waffle-fuse names its file system AFFS or FAT; WinFsp shows it as FUSE-...
    const QString fs = QString::fromWCharArray(fsName);
    if (fs.compare("FUSE-AFFS", Qt::CaseInsensitive) == 0 || fs.compare("FUSE-FAT", Qt::CaseInsensitive) == 0)
    {
        disk.found = true;
        disk.root = QString::fromWCharArray(volume);
        disk.name = QString::fromWCharArray(label);
    }
#endif
    return disk;
}

#ifdef Q_OS_LINUX
static QString desktopFilePath(const QString &id)
{
    return QStandardPaths::locate(QStandardPaths::ApplicationsLocation, id);
}

// Exec line of a desktop entry, with the file in place of its field codes
static QStringList execCommand(const QString &desktopFile, const QString &file)
{
    QFile f(desktopFile);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return {};
    QString exec;
    bool inEntry = false;
    QTextStream in(&f);
    for (QString line = in.readLine(); !line.isNull(); line = in.readLine())
    {
        line = line.trimmed();
        if (line.startsWith('[')) inEntry = line == "[Desktop Entry]";
        else if (inEntry && line.startsWith("Exec=")) exec = line.mid(5);
    }
    QStringList out;
    bool placed = false;
    for (QString arg : QProcess::splitCommand(exec))
    {
        if (arg == "%f" || arg == "%F" || arg == "%u" || arg == "%U")
        {
            out << file;
            placed = true;
            continue;
        }
        if (arg == "%i" || arg == "%c" || arg == "%k") continue;
        arg.replace("%%", "%");
        out << arg;
    }
    if (!placed && !out.isEmpty()) out << file;
    return out;
}
#endif

bool handOverToPreviousApp(const QString &path)
{
#ifdef Q_OS_LINUX
    // Written by scripts/install-desktop.sh: "<content type>=<desktop id>"
    const QString list = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
                         "/waffle-fuse/previous-handlers";
    QFile f(list);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return false;
    const QMimeType type = QMimeDatabase().mimeTypeForFile(path);
    QStringList types = type.aliases();
    types.prepend(type.name());
    QString app;
    QTextStream in(&f);
    for (QString line = in.readLine(); !line.isNull() && app.isEmpty(); line = in.readLine())
    {
        const int eq = int(line.indexOf('='));
        if (eq > 0 && types.contains(line.left(eq))) app = line.mid(eq + 1).trimmed();
    }
    if (app.isEmpty() || app == "waffle-modplayer.desktop") return false;
    const QString desktop = desktopFilePath(app);
    if (desktop.isEmpty()) return false;
    QStringList cmd = execCommand(desktop, path);
    if (cmd.isEmpty()) return false;
    const QString program = cmd.takeFirst();
    return QProcess::startDetached(program, cmd);
#else
    Q_UNUSED(path);
    return false;
#endif
}
