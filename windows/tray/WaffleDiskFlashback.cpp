// Waffle DiskFlashback for Windows – tray app for the DrawBridge/Waffle floppy
// reader, the Windows counterpart of macos/WaffleDiskFlashback and of
// scripts/waffle-diskflashback.py.
//
//   * insert a disk  -> mounted on a free drive letter (WinFsp) and opened in
//                       Explorer
//   * eject          -> menu "Eject": pending changes are written, then "the
//                       disk can be removed"
//   * take it out    -> if it was still mounted it is unmounted automatically
//   * .adf/.img/.ima -> "Open with > Waffle DiskFlashback" (or the menu) mounts
//                       the image as a virtual disk
//
// States (as in the Linux daemon and the macOS app):
//   noPort    no DrawBridge found, polling the COM ports
//   waiting   port open, waiting for a disk (waffle-fuse --wait-disk)
//   mounting  waffle-fuse reading the disk
//   mounted   disk mounted
//   ejecting  unmount requested, waiting for pending writes
//   remove    disk unmounted (or unreadable): waiting for it to be taken out
//   busy      copying the disk to an image file / writing an image to it
//
// Every disk operation is done by waffle-fuse.exe (next to this program),
// whose "WAFFLE key=value" lines on stdout drive the state machine.
//
//   WaffleDiskFlashback.exe [image...]   start, or open images in the running app
//   WaffleDiskFlashback.exe --quit       quit the running app (unmounting first)
//   WaffleDiskFlashback.exe --menu       open the menu of the running app
//
// Settings (HKCU\Software\Waffle\DiskFlashback): MountDir (REG_SZ) mounts disks
// as <MountDir>\<volume name> instead of drive letters.  Environment:
// WAFFLE_MOUNT_DIR (same), WAFFLE_DEBUG=1 (FUSE trace in the log).

#include <windows.h>
#include <windowsx.h>
#include <shellapi.h>
#include <commctrl.h>
#include <commdlg.h>
#include <shlobj.h>

#include <algorithm>
#include <cstdio>
#include <cwctype>
#include <deque>
#include <functional>
#include <iterator>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "resource.h"

// ── waffle-fuse exit codes ───────────────────────────────────────────────────
enum
{
    EXIT_OK = 0, EXIT_PORT = 2, EXIT_NODISK = 3, EXIT_UNKNOWN_FMT = 4, EXIT_DRIVE = 5,
    EXIT_FILESYSTEM = 6, EXIT_REMOVED = 7, EXIT_REMOVED_DIRTY = 8, EXIT_WRITE_ERROR = 9,
};

// ── Window messages ──────────────────────────────────────────────────────────
enum
{
    WM_APP_TRAY = WM_APP + 1,   // notification icon callback
    WM_APP_LINE,                // wParam Proc*, lParam Line*
    WM_APP_EXIT,                // wParam Proc*, lParam exit code
    WM_APP_CALL,                // lParam std::function<void()>*
};

static const wchar_t* kWindowClass = L"WaffleDiskFlashbackTray";
static const wchar_t* kJobClass    = L"WaffleDiskFlashbackJob";
static const wchar_t* kAppName     = L"Waffle DiskFlashback";
static const wchar_t* kRunKey      = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
static const wchar_t* kSettingsKey = L"Software\\Waffle\\DiskFlashback";

static HINSTANCE g_inst;
static HWND      g_hwnd;
static UINT      g_taskbarCreated;

// ── Strings ──────────────────────────────────────────────────────────────────

static std::wstring widen(const std::string& s)
{
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    if (n) MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
    return w;
}

static std::string narrow(const std::wstring& w)
{
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    if (n) WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

static std::wstring upper(std::wstring s)
{
    for (auto& c : s) c = (wchar_t)towupper(c);
    return s;
}

static std::wstring fileName(const std::wstring& path)
{
    size_t p = path.find_last_of(L"\\/");
    return p == std::wstring::npos ? path : path.substr(p + 1);
}

static std::wstring dirName(const std::wstring& path)
{
    size_t p = path.find_last_of(L"\\/");
    return p == std::wstring::npos ? L"." : path.substr(0, p);
}

static std::wstring extension(const std::wstring& path)
{
    std::wstring name = fileName(path);
    size_t p = name.rfind(L'.');
    return p == std::wstring::npos ? L"" : upper(name.substr(p + 1));
}

static std::wstring fullPath(const std::wstring& path)
{
    wchar_t buf[MAX_PATH * 4];
    DWORD n = GetFullPathNameW(path.c_str(), (DWORD)std::size(buf), buf, nullptr);
    return n && n < std::size(buf) ? std::wstring(buf) : path;
}

static std::wstring envVar(const wchar_t* name)
{
    wchar_t buf[MAX_PATH * 4];
    DWORD n = GetEnvironmentVariableW(name, buf, (DWORD)std::size(buf));
    return n && n < std::size(buf) ? std::wstring(buf) : L"";
}

static std::wstring expandEnv(const std::wstring& s)
{
    wchar_t buf[MAX_PATH * 4];
    DWORD n = ExpandEnvironmentStringsW(s.c_str(), buf, (DWORD)std::size(buf));
    return n && n <= std::size(buf) ? std::wstring(buf) : s;
}

static std::wstring knownFolder(REFKNOWNFOLDERID id)
{
    PWSTR p = nullptr;
    std::wstring s;
    if (SUCCEEDED(SHGetKnownFolderPath(id, 0, nullptr, &p))) s = p;
    CoTaskMemFree(p);
    return s;
}

static bool isDir(const std::wstring& p)
{
    DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
}

static bool fileExists(const std::wstring& p)
{
    DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

// ── Paths and settings ───────────────────────────────────────────────────────

static std::wstring exeDir()
{
    wchar_t buf[MAX_PATH * 4];
    DWORD n = GetModuleFileNameW(nullptr, buf, (DWORD)std::size(buf));
    return dirName(std::wstring(buf, n));
}

static std::wstring exePath()
{
    wchar_t buf[MAX_PATH * 4];
    DWORD n = GetModuleFileNameW(nullptr, buf, (DWORD)std::size(buf));
    return std::wstring(buf, n);
}

static const std::wstring& waffleBin()
{
    static std::wstring bin = exeDir() + L"\\waffle-fuse.exe";
    return bin;
}

static std::wstring regString(HKEY root, const wchar_t* key, const wchar_t* value, REGSAM extra = 0)
{
    HKEY h;
    if (RegOpenKeyExW(root, key, 0, KEY_READ | extra, &h) != ERROR_SUCCESS) return L"";
    wchar_t buf[MAX_PATH * 4] = {};
    DWORD size = sizeof buf - sizeof(wchar_t), type = 0;
    LONG r = RegQueryValueExW(h, value, nullptr, &type, reinterpret_cast<BYTE*>(buf), &size);
    RegCloseKey(h);
    return r == ERROR_SUCCESS && (type == REG_SZ || type == REG_EXPAND_SZ) ? std::wstring(buf) : L"";
}

/// Where disks are mounted: "" = a free drive letter each, else <dir>\<volume name>
static const std::wstring& mountDir()
{
    static std::wstring dir = []
    {
        std::wstring d = envVar(L"WAFFLE_MOUNT_DIR");
        if (d.empty()) d = expandEnv(regString(HKEY_CURRENT_USER, kSettingsKey, L"MountDir"));
        return d;
    }();
    return dir;
}

/// waffle-fuse arguments for the mountpoint
static std::vector<std::wstring> mountTarget()
{
    if (mountDir().empty()) return {L"*"};
    return {L"--automount", mountDir()};
}

static std::vector<std::wstring> driverDebug()
{
    return envVar(L"WAFFLE_DEBUG").empty() ? std::vector<std::wstring> {} : std::vector<std::wstring> {L"-d"};
}

static bool winfspInstalled()
{
    std::wstring dir = regString(HKEY_LOCAL_MACHINE, L"SOFTWARE\\WinFsp", L"InstallDir", KEY_WOW64_32KEY);
    if (dir.empty()) return false;
    if (dir.back() != L'\\') dir += L'\\';
    return fileExists(dir + L"bin\\winfsp-x64.dll");
}

// ── Log: %LOCALAPPDATA%\Waffle\WaffleDiskFlashback.log ───────────────────────

static std::wstring g_logPath;
static std::mutex   g_logMutex;

static void logLine(const std::string& msg)
{
    std::lock_guard<std::mutex> lock(g_logMutex);
    if (g_logPath.empty()) return;
    FILE* f = _wfopen(g_logPath.c_str(), L"ab");
    if (!f) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    fprintf(f, "%04u-%02u-%02u %02u:%02u:%02u %s\r\n", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond,
            msg.c_str());
    fclose(f);
}

static void logLine(const std::wstring& msg) { logLine(narrow(msg)); }

/// Start a new log, keeping the previous one as .old
static void rotateLog()
{
    std::wstring dir = knownFolder(FOLDERID_LocalAppData) + L"\\Waffle";
    CreateDirectoryW(dir.c_str(), nullptr);
    g_logPath = dir + L"\\WaffleDiskFlashback.log";
    MoveFileExW(g_logPath.c_str(), (g_logPath + L".old").c_str(), MOVEFILE_REPLACE_EXISTING);
}

// ── Main thread helpers ──────────────────────────────────────────────────────

/// Run f on the main thread (from any thread)
static void postCall(std::function<void()> f)
{
    PostMessageW(g_hwnd, WM_APP_CALL, 0, reinterpret_cast<LPARAM>(new std::function<void()>(std::move(f))));
}

static std::map<UINT_PTR, std::function<void()>> g_timers;
static UINT_PTR g_nextTimer = 100;

/// Run f on the main thread after ms milliseconds
static void runLater(UINT ms, std::function<void()> f)
{
    UINT_PTR id = g_nextTimer++;
    g_timers[id] = std::move(f);
    SetTimer(g_hwnd, id, ms, nullptr);
}

// ── Processes ────────────────────────────────────────────────────────────────

/// Quote one argument for CreateProcess (the rules of CommandLineToArgvW)
static std::wstring quoteArg(const std::wstring& a)
{
    if (!a.empty() && a.find_first_of(L" \t\"") == std::wstring::npos) return a;
    std::wstring q = L"\"";
    size_t backslashes = 0;
    for (wchar_t c : a)
    {
        if (c == L'\\') { backslashes++; continue; }
        if (c == L'"') q.append(backslashes * 2 + 1, L'\\');
        else q.append(backslashes, L'\\');
        backslashes = 0;
        q += c;
    }
    q.append(backslashes * 2, L'\\');
    return q + L"\"";
}

static std::wstring commandLine(const std::vector<std::wstring>& args)
{
    std::wstring cmd = quoteArg(waffleBin());
    for (auto& a : args) cmd += L" " + quoteArg(a);
    return cmd;
}

/// Run waffle-fuse and wait (at most timeoutMs); its exit status, -1 on failure
static int runSync(const std::vector<std::wstring>& args, DWORD timeoutMs)
{
    std::wstring cmd = commandLine(args);
    STARTUPINFOW si = {};
    si.cb = sizeof si;
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(waffleBin().c_str(), &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr,
                        &si, &pi))
        return -1;
    CloseHandle(pi.hThread);
    DWORD code = (DWORD)-1;
    if (WaitForSingleObject(pi.hProcess, timeoutMs) == WAIT_OBJECT_0) GetExitCodeProcess(pi.hProcess, &code);
    else TerminateProcess(pi.hProcess, 1);
    CloseHandle(pi.hProcess);
    return (int)code;
}

/// Unmount a disk mounted by waffle-fuse; false if it is still mounted (files open)
static bool unmount(const std::wstring& mountpoint)
{
    return runSync({L"--unmount", mountpoint}, 30000) == 0;
}

using Event = std::map<std::string, std::string>;

/// 'WAFFLE event=mounted mountpoint=C:\x y' -> {event: mounted, mountpoint: C:\x y}
static bool parseEvent(const std::string& line, Event& fields)
{
    if (line.compare(0, 7, "WAFFLE ") != 0) return false;
    std::string rest = line.substr(7);
    while (!rest.empty())
    {
        size_t eq = rest.find('=');
        if (eq == std::string::npos) break;
        std::string key = rest.substr(0, eq);
        rest = rest.substr(eq + 1);
        if (key == "volume" || key == "mountpoint")      // always last: the value may contain anything
        {
            fields[key] = rest;
            break;
        }
        size_t sp = rest.find(' ');
        fields[key] = rest.substr(0, sp);
        rest = sp == std::string::npos ? "" : rest.substr(sp + 1);
    }
    return true;
}

/// A waffle-fuse child: its stdout events and its exit reach the main thread, in order
struct Proc
{
    std::wstring name;
    HANDLE process = nullptr;
    DWORD pid = 0;
    std::deque<std::string> stderrTail;
    bool cancelled = false;
    std::function<void(const Event&)> onEvent;
    std::function<void(int)> onExit;

    ~Proc() { if (process) CloseHandle(process); }

    bool running() const { return process && WaitForSingleObject(process, 0) == WAIT_TIMEOUT; }

    /// Stop a waiting helper (never used on a mounted driver)
    void cancel()
    {
        cancelled = true;
        if (running()) TerminateProcess(process, 1);
    }

    /// Ask a disk job to stop between two tracks
    void stop() const
    {
        HANDLE ev = OpenEventW(EVENT_MODIFY_STATE, FALSE, (L"Local\\waffle-fuse-stop:" + std::to_wstring(pid)).c_str());
        if (ev)
        {
            SetEvent(ev);
            CloseHandle(ev);
        }
    }
};
using ProcPtr = std::shared_ptr<Proc>;

static std::map<Proc*, ProcPtr> g_procs;    // running children, until their exit is handled

struct Line
{
    std::string text;
    bool isStderr;
};

static void readLines(HANDLE h, Proc* p, bool isStderr)
{
    std::string buf;
    char chunk[4096];
    DWORD n;
    while (ReadFile(h, chunk, sizeof chunk, &n, nullptr) && n > 0)
    {
        buf.append(chunk, n);
        size_t nl;
        while ((nl = buf.find('\n')) != std::string::npos)
        {
            std::string line = buf.substr(0, nl);
            buf.erase(0, nl + 1);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            PostMessageW(g_hwnd, WM_APP_LINE, reinterpret_cast<WPARAM>(p),
                         reinterpret_cast<LPARAM>(new Line{line, isStderr}));
        }
    }
    CloseHandle(h);
}

static ProcPtr startProc(const std::vector<std::wstring>& args, std::function<void(const Event&)> onEvent = nullptr,
                         std::function<void(int)> onExit = nullptr)
{
    auto p = std::make_shared<Proc>();
    p->name = args.empty() ? L"" : args[0];
    p->onEvent = std::move(onEvent);
    p->onExit = std::move(onExit);
    std::wstring cmd = commandLine(args);
    logLine(L"run: " + cmd);

    SECURITY_ATTRIBUTES sa = {sizeof sa, nullptr, TRUE};
    HANDLE outR, outW, errR, errW;
    CreatePipe(&outR, &outW, &sa, 0);
    CreatePipe(&errR, &errW, &sa, 0);
    SetHandleInformation(outR, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(errR, HANDLE_FLAG_INHERIT, 0);
    HANDLE nul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, nullptr);

    STARTUPINFOW si = {};
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = nul;
    si.hStdOutput = outW;
    si.hStdError = errW;
    PROCESS_INFORMATION pi;
    BOOL ok = CreateProcessW(waffleBin().c_str(), &cmd[0], nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr,
                             nullptr, &si, &pi);
    CloseHandle(outW);
    CloseHandle(errW);
    CloseHandle(nul);
    if (!ok)
    {
        logLine(L"cannot run " + waffleBin() + L": error " + std::to_wstring(GetLastError()));
        CloseHandle(outR);
        CloseHandle(errR);
        Proc* raw = p.get();
        g_procs[raw] = p;
        PostMessageW(g_hwnd, WM_APP_EXIT, reinterpret_cast<WPARAM>(raw), 127);
        return p;
    }
    CloseHandle(pi.hThread);
    p->process = pi.hProcess;
    p->pid = pi.dwProcessId;
    Proc* raw = p.get();
    g_procs[raw] = p;

    std::thread errThread(readLines, errR, raw, true);
    std::thread([raw, outR, errThread = std::move(errThread)]() mutable
    {
        readLines(outR, raw, false);
        errThread.join();
        WaitForSingleObject(raw->process, INFINITE);
        DWORD code = 0;
        GetExitCodeProcess(raw->process, &code);
        PostMessageW(g_hwnd, WM_APP_EXIT, reinterpret_cast<WPARAM>(raw), (LPARAM)code);
    }).detach();
    return p;
}

/// Run done on the main thread once p has exited, at most timeoutMs later
static void waitExit(const ProcPtr& p, DWORD timeoutMs, std::function<void()> done)
{
    std::thread([p, timeoutMs, done]
    {
        if (p->process) WaitForSingleObject(p->process, timeoutMs);
        postCall(done);
    }).detach();
}

// ── COM ports ────────────────────────────────────────────────────────────────

/// USB serial ports (FTDI, CDC, CP210x, CH340...): the built-in and Bluetooth
/// ones are left alone, probing them is slow or pointless
static std::vector<std::wstring> candidatePorts()
{
    std::vector<std::pair<int, std::wstring>> ports;
    HKEY h;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"HARDWARE\\DEVICEMAP\\SERIALCOMM", 0, KEY_READ, &h) != ERROR_SUCCESS)
        return {};
    for (DWORD i = 0;; i++)
    {
        wchar_t name[256], data[64];
        DWORD nameLen = (DWORD)std::size(name), dataSize = sizeof data - sizeof(wchar_t), type;
        LONG r = RegEnumValueW(h, i, name, &nameLen, nullptr, &type, reinterpret_cast<BYTE*>(data), &dataSize);
        if (r == ERROR_NO_MORE_ITEMS) break;
        if (r != ERROR_SUCCESS || type != REG_SZ) continue;
        data[dataSize / sizeof(wchar_t)] = 0;
        std::wstring dev = upper(name), port = data;
        if (dev.find(L"\\DEVICE\\SERIAL") == 0 || dev.find(L"BTHMODEM") != std::wstring::npos) continue;
        if (upper(port).compare(0, 3, L"COM") != 0) continue;
        ports.push_back({_wtoi(port.c_str() + 3), port});
    }
    RegCloseKey(h);
    std::sort(ports.begin(), ports.end());
    std::vector<std::wstring> out;
    for (auto& p : ports) out.push_back(p.second);
    return out;
}

// ── Notification icon ────────────────────────────────────────────────────────

static NOTIFYICONDATAW g_nid;

static HICON trayIcon(int id)
{
    HICON icon = nullptr;
    if (FAILED(LoadIconMetric(g_inst, MAKEINTRESOURCEW(id), LIM_SMALL, &icon)))
        icon = (HICON)LoadImageW(g_inst, MAKEINTRESOURCEW(id), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                                 GetSystemMetrics(SM_CYSMICON), 0);
    return icon;
}

static void copyTrunc(wchar_t* dst, size_t size, const std::wstring& src)
{
    lstrcpynW(dst, src.c_str(), (int)size);
}

static void trayAdd(int iconId, const std::wstring& tip)
{
    g_nid = {};
    g_nid.cbSize = sizeof g_nid;
    g_nid.hWnd = g_hwnd;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE | NIF_SHOWTIP;
    g_nid.uCallbackMessage = WM_APP_TRAY;
    g_nid.hIcon = trayIcon(iconId);
    copyTrunc(g_nid.szTip, std::size(g_nid.szTip), tip);
    Shell_NotifyIconW(NIM_ADD, &g_nid);
    g_nid.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &g_nid);
}

static void traySet(int iconId, const std::wstring& tip)
{
    if (g_nid.hIcon) DestroyIcon(g_nid.hIcon);
    g_nid.hIcon = trayIcon(iconId);
    g_nid.uFlags = NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    copyTrunc(g_nid.szTip, std::size(g_nid.szTip), tip);
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);
}

static void notify(const std::wstring& title, const std::wstring& message)
{
    logLine(L"notify: " + title + L": " + message);
    NOTIFYICONDATAW n = g_nid;
    n.uFlags = NIF_INFO;
    n.dwInfoFlags = NIIF_INFO;
    copyTrunc(n.szInfoTitle, std::size(n.szInfoTitle), title);
    copyTrunc(n.szInfo, std::size(n.szInfo), message);
    Shell_NotifyIconW(NIM_MODIFY, &n);
}

static void openInExplorer(const std::wstring& path)
{
    std::wstring p = path.size() == 2 && path[1] == L':' ? path + L"\\" : path;
    ShellExecuteW(nullptr, L"open", p.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

// ── Start at login (HKCU\...\Run) ────────────────────────────────────────────

static bool startsAtLogin()
{
    return !regString(HKEY_CURRENT_USER, kRunKey, kAppName).empty();
}

static void setStartAtLogin(bool on)
{
    HKEY h;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &h, nullptr) != ERROR_SUCCESS)
        return;
    if (on)
    {
        std::wstring cmd = L"\"" + exePath() + L"\"";
        RegSetValueExW(h, kAppName, 0, REG_SZ, reinterpret_cast<const BYTE*>(cmd.c_str()),
                       (DWORD)((cmd.size() + 1) * sizeof(wchar_t)));
    }
    else
    {
        RegDeleteValueW(h, kAppName);
    }
    RegCloseKey(h);
}

// ── The app ──────────────────────────────────────────────────────────────────

enum class State { noPort, waiting, mounting, mounted, ejecting, remove, busy };

struct Job
{
    enum Kind { dump, write } kind;
    std::wstring path;
    bool full = false;          // write: erase and rewrite every track
    bool remount = false;
    std::wstring tmp;           // dump: the copy goes to a temporary file first
    int tracks = 0;
    int bad = 0;
    int written = -1;
    bool cancelled = false;
};

/// An image opened as a virtual disk
struct VirtualDisk
{
    ProcPtr proc;
    std::wstring path;
    std::wstring mountpoint;
};

enum MenuId
{
    ID_OPEN = 1, ID_EJECT, ID_REMOUNT, ID_DUMP, ID_WRITE, ID_OPEN_IMAGE, ID_LOG, ID_LOGIN, ID_QUIT,
    ID_IMAGE_EJECT = 1000,      // + index of the virtual disk
};

class App
{
public:
    State state = State::noPort;
    std::wstring port;
    ProcPtr proc;               // current waffle-fuse child
    ProcPtr driver;             // the mounted waffle-fuse (subset of proc)
    std::wstring mountpoint;
    std::wstring info;
    std::wstring tooltip;
    std::wstring volume;        // volume name / label of the current disk
    std::string fsKind;         // "amiga" or "fat"
    std::unique_ptr<Job> job;
    HWND jobWindow = nullptr, jobBar = nullptr, jobStatus = nullptr;
    std::map<std::wstring, std::shared_ptr<VirtualDisk>> images;     // upper-case full path -> disk
    bool quitting = false;

    // ── Startup / quit ───────────────────────────────────────────────────────

    void start(const std::vector<std::wstring>& args)
    {
        logLine(L"Waffle DiskFlashback started, driver " + waffleBin() + L", disks " +
                (mountDir().empty() ? std::wstring(L"on drive letters") : L"in " + mountDir()));
        trayAdd(IDI_TRAY_IDLE, kAppName);
        findPort();
        openArgs(args);
    }

    /// Images given on the command line (or by a second instance)
    void openArgs(const std::vector<std::wstring>& args)
    {
        for (auto& a : args)
        {
            if (a == L"--quit")
            {
                quit();
                return;
            }
            if (a == L"--menu")
            {
                showMenu();
                return;
            }
            std::wstring ext = extension(a);
            if ((ext == L"ADF" || ext == L"IMG" || ext == L"IMA") && fileExists(a)) openImage(fullPath(a));
        }
    }

    /// Unmount cleanly so pending writes reach the disk, then exit.  sync: wait
    /// here (Windows is shutting down), else in the background
    void quit(bool sync = false)
    {
        if (quitting && !sync) return;
        quitting = true;
        std::vector<ProcPtr> waits;
        if (driver && !mountpoint.empty())
        {
            unmount(mountpoint);
            waits.push_back(driver);
        }
        else if (proc)
        {
            if (state == State::busy)
            {
                proc->stop();                       // waffle-fuse stops between two tracks
                waits.push_back(proc);
            }
            else
            {
                proc->cancel();
            }
        }
        for (auto& [key, disk] : images)
        {
            if (!disk->mountpoint.empty()) unmount(disk->mountpoint);
            else disk->proc->cancel();
            waits.push_back(disk->proc);
        }
        auto wait = [waits](DWORD timeoutMs)
        {
            DWORD deadline = GetTickCount() + timeoutMs;
            for (auto& p : waits)
            {
                if (!p->process) continue;
                DWORD now = GetTickCount();
                WaitForSingleObject(p->process, now < deadline ? deadline - now : 0);
            }
        };
        if (sync)
        {
            wait(20000);
            finishQuit();
            return;
        }
        std::thread([this, wait]
        {
            wait(60000);
            postCall([this] { finishQuit(); });
        }).detach();
    }

    void finishQuit()
    {
        if (job && !job->tmp.empty()) DeleteFileW(job->tmp.c_str());
        logLine("quit");
        Shell_NotifyIconW(NIM_DELETE, &g_nid);
        PostQuitMessage(0);
    }

    bool anythingMounted() const
    {
        if (driver || state == State::busy) return true;
        for (auto& [key, disk] : images)
            if (!disk->mountpoint.empty()) return true;
        return false;
    }

    // ── UI ───────────────────────────────────────────────────────────────────

    void setState(State s, const std::wstring& tip, int icon)
    {
        if (s != state || tip != tooltip) logLine(L"state: " + tip);
        state = s;
        tooltip = tip;
        traySet(icon, tip);
    }

    void showMenu()
    {
        HMENU m = CreatePopupMenu();
        auto item = [m](UINT id, const std::wstring& title, bool enabled = true, bool checked = false)
        {
            AppendMenuW(m, MF_STRING | (enabled ? 0 : MF_GRAYED) | (checked ? MF_CHECKED : 0), id, title.c_str());
        };
        std::wstring head = !info.empty() ? info : !tooltip.empty() ? tooltip : kAppName;
        AppendMenuW(m, MF_STRING | MF_DISABLED, 0, head.c_str());
        AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
        bool mounted = state == State::mounted;
        bool diskIn = mounted || state == State::remove;
        item(ID_OPEN, L"&Open", mounted);
        item(ID_EJECT, L"&Eject", mounted);
        item(ID_REMOUNT, L"&Mount again", state == State::remove);
        item(ID_DUMP, L"&Copy disk to image file…", diskIn);
        item(ID_WRITE, L"&Write image to disk…", diskIn);
        AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
        item(ID_OPEN_IMAGE, L"Open &image as virtual disk…");
        int i = 0;
        for (auto& [key, disk] : images)
        {
            std::wstring where = disk->mountpoint.empty() ? L"opening…" : disk->mountpoint;
            item(ID_IMAGE_EJECT + i++, L"Eject " + fileName(disk->path) + L" (" + where + L")",
                 !disk->mountpoint.empty());
        }
        AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
        item(ID_LOGIN, L"Start at &login", true, startsAtLogin());
        item(ID_LOG, L"Show lo&g");
        item(ID_QUIT, L"&Quit");

        POINT pt;
        GetCursorPos(&pt);
        SetForegroundWindow(g_hwnd);
        UINT cmd = TrackPopupMenuEx(m, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, pt.x, pt.y, g_hwnd, nullptr);
        PostMessageW(g_hwnd, WM_NULL, 0, 0);
        DestroyMenu(m);
        command(cmd);
    }

    void command(UINT cmd)
    {
        switch (cmd)
        {
        case ID_OPEN:
            if (!mountpoint.empty()) openInExplorer(mountpoint);
            break;
        case ID_EJECT:
            eject();
            break;
        case ID_REMOUNT:
            remount();
            break;
        case ID_DUMP:
            dumpAsk();
            break;
        case ID_WRITE:
            writeAsk();
            break;
        case ID_OPEN_IMAGE:
            openImageAsk();
            break;
        case ID_LOGIN:
            setStartAtLogin(!startsAtLogin());
            break;
        case ID_LOG:
            ShellExecuteW(nullptr, L"open", L"notepad.exe", quoteArg(g_logPath).c_str(), nullptr, SW_SHOWNORMAL);
            break;
        case ID_QUIT:
            quit();
            break;
        default:
            if (cmd >= ID_IMAGE_EJECT && cmd < ID_IMAGE_EJECT + images.size())
            {
                auto it = images.begin();
                std::advance(it, cmd - ID_IMAGE_EJECT);
                ejectImage(it->second);
            }
            break;
        }
    }

    // ── Port discovery ───────────────────────────────────────────────────────

    void findPort()
    {
        setState(State::noPort, L"Waffle: looking for the DrawBridge…", IDI_TRAY_IDLE);
        info.clear();
        std::thread([this]
        {
            std::wstring found;
            for (auto& candidate : candidatePorts())
            {
                int code = runSync({L"--probe", candidate}, 20000);
                if (code == 0 || code == 1)         // answered: it is a DrawBridge
                {
                    found = candidate;
                    break;
                }
            }
            postCall([this, found]
            {
                if (!found.empty()) portFound(found);
                else runLater(3000, [this] { if (state == State::noPort && !quitting) findPort(); });
            });
        }).detach();
    }

    void portFound(const std::wstring& p)
    {
        if (state != State::noPort || quitting) return;
        port = p;
        waitDisk();
    }

    // ── Waiting for a disk ───────────────────────────────────────────────────

    void waitDisk()
    {
        if (port.empty() || quitting) return;
        setState(State::waiting, L"Waffle: insert a disk (" + port + L")", IDI_TRAY_IDLE);
        info.clear();
        proc = startProc({L"--wait-disk", port}, nullptr, [this](int code)
        {
            proc = nullptr;
            if (code == 0)
            {
                mount();
            }
            else
            {
                // Port gone or busy (e.g. WaffleCopyPRO is using it): look again later
                port.clear();
                runLater(3000, [this] { if (state == State::waiting) findPort(); });
            }
        });
    }

    // ── Mounting ─────────────────────────────────────────────────────────────

    void mount()
    {
        if (port.empty() || quitting) return;
        setState(State::mounting, L"Waffle: reading disk…", IDI_TRAY_MOUNTING);
        std::vector<std::wstring> args = {port};
        for (auto& a : mountTarget()) args.push_back(a);
        for (auto& a : driverDebug()) args.push_back(a);
        driver = proc = startProc(args, [this](const Event& ev) { driverEvent(ev); },
                                  [this](int code) { driverExit(code); });
    }

    static std::string field(const Event& ev, const char* key)
    {
        auto it = ev.find(key);
        return it == ev.end() ? "" : it->second;
    }

    void driverEvent(const Event& ev)
    {
        std::string e = field(ev, "event");
        if (e == "detected")
        {
            volume = widen(field(ev, "volume"));
            fsKind = field(ev, "format");
            std::wstring kind = fsKind == "amiga" ? L"Amiga" : L"PC";
            std::wstring ro = field(ev, "readonly") == "1" ? L", read-only" : L"";
            info = (volume.empty() ? L"unnamed" : volume) + L" – " + kind + L" " + widen(field(ev, "fs")) + L" " +
                   widen(field(ev, "density")) + ro;
        }
        else if (e == "mounted")
        {
            mountpoint = widen(field(ev, "mountpoint"));
            setState(State::mounted, L"Waffle: " + info + L" (" + mountpoint + L")", IDI_TRAY_MOUNTED);
            notify(L"Disk inserted", info + L" on " + mountpoint);
            openInExplorer(mountpoint);
        }
        else if (e == "write-error")
        {
            notify(L"Disk write error", L"Some changes could not be written. Do not remove the disk; "
                   L"check that it is not write-protected or damaged.");
        }
    }

    static std::wstring joinTail(const std::deque<std::string>& tail)
    {
        std::string s;
        for (auto& l : tail) s += (s.empty() ? "" : " ") + l;
        return widen(s);
    }

    void driverExit(int code)
    {
        std::deque<std::string> tail = driver ? driver->stderrTail : std::deque<std::string> {};
        proc = nullptr;
        driver = nullptr;
        mountpoint.clear();
        if (quitting) return;
        if (code == EXIT_OK && job)
        {
            startJob();                     // unmounted to free the port for a disk job
        }
        else if (code == EXIT_OK)
        {
            notify(L"Disk ejected", L"All changes written: the disk can be removed.");
            waitRemoval();
        }
        else if (code == EXIT_REMOVED)
        {
            notify(L"Disk removed", info.empty() ? L"The disk was unmounted." : info);
            waitDisk();
        }
        else if (code == EXIT_REMOVED_DIRTY)
        {
            notify(L"Disk removed too early",
                   L"The disk was taken out while changes were still being written: they are lost.");
            waitDisk();
        }
        else if (code == EXIT_NODISK)
        {
            waitDisk();
        }
        else if (code == EXIT_PORT)
        {
            port.clear();
            findPort();
        }
        else
        {
            std::wstring detail;
            switch (code)
            {
            case EXIT_UNKNOWN_FMT: detail = L"Not a DOS disk: unformatted, NDOS (game) or copy-protected."; break;
            case EXIT_DRIVE:       detail = L"Cannot read track 0: the disk may be damaged."; break;
            case EXIT_FILESYSTEM:  detail = L"The filesystem on the disk is not valid."; break;
            case EXIT_WRITE_ERROR: detail = L"Some changes could not be written to the disk."; break;
            default:               detail = tail.empty() ? L"error " + std::to_wstring(code) : joinTail(tail); break;
            }
            notify(L"Cannot use this disk", detail);
            info = detail;
            waitRemoval();
        }
    }

    // ── Eject ────────────────────────────────────────────────────────────────

    void eject()
    {
        if (state != State::mounted || mountpoint.empty()) return;
        if (!unmount(mountpoint))
        {
            notify(L"Disk in use", L"Close the windows and programs that are using the disk, then eject again.");
            return;
        }
        // waffle-fuse now writes any pending changes and exits (see driverExit)
        setState(State::ejecting, L"Waffle: writing changes, do not remove the disk…", IDI_TRAY_MOUNTING);
    }

    // ── After eject: wait for the disk to be taken out ───────────────────────

    void waitRemoval()
    {
        if (port.empty() || quitting)
        {
            findPort();
            return;
        }
        setState(State::remove, info.empty() ? L"Waffle: remove the disk" : L"Waffle: remove the disk (" + info + L")",
                 IDI_TRAY_IDLE);
        proc = startProc({L"--wait-removal", port}, nullptr, [this](int code)
        {
            proc = nullptr;
            if (code == 0)
            {
                waitDisk();
            }
            else
            {
                runLater(3000, [this]
                {
                    if (state == State::remove)
                    {
                        port.clear();
                        findPort();
                    }
                });
            }
        });
    }

    /// Stop a waiting helper (--wait-removal / --wait-disk) to free the port
    void stopHelper(std::function<void()> done)
    {
        if (!proc || proc == driver)
        {
            done();
            return;
        }
        ProcPtr p = proc;
        p->cancel();
        proc = nullptr;
        waitExit(p, 5000, done);
    }

    void remount()
    {
        if (state != State::remove) return;
        stopHelper([this] { mount(); });
    }

    // ── Disk jobs: copy the disk to an image file / write an image to the disk

    static std::wstring startFolder()
    {
        std::wstring home = knownFolder(FOLDERID_Profile);
        if (isDir(home + L"\\WaffleFolder")) return home + L"\\WaffleFolder";
        std::wstring docs = knownFolder(FOLDERID_Documents);
        return docs.empty() ? home : docs;
    }

    void dumpAsk()
    {
        if (state != State::mounted && state != State::remove) return;
        std::wstring ext = fsKind == "fat" ? L"img" : L"adf";
        std::wstring name = (volume.empty() ? (fsKind == "fat" ? L"floppy" : L"disk") : volume) + L"." + ext;
        for (auto& c : name)
            if (wcschr(L"<>:\"/\\|?*", c)) c = L'_';
        wchar_t file[MAX_PATH * 4] = {};
        lstrcpynW(file, name.c_str(), (int)std::size(file));
        std::wstring dir = startFolder();
        OPENFILENAMEW ofn = {};
        ofn.lStructSize = sizeof ofn;
        ofn.hwndOwner = g_hwnd;
        ofn.lpstrFilter = L"Disk image: copy of the sectors (*.adf, *.img)\0*.adf;*.img;*.ima\0"
                          L"Raw magnetic flux, also for copy-protected disks (*.scp)\0*.scp\0";
        ofn.lpstrFile = file;
        ofn.nMaxFile = (DWORD)std::size(file);
        ofn.lpstrInitialDir = dir.c_str();
        ofn.lpstrTitle = L"Copy disk to image file";
        ofn.lpstrDefExt = ext.c_str();
        ofn.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER;
        SetForegroundWindow(g_hwnd);
        if (!GetSaveFileNameW(&ofn)) return;
        std::wstring path = file;
        if (ofn.nFilterIndex == 2 && extension(path) != L"SCP")
        {
            size_t dot = path.rfind(L'.');
            if (dot != std::wstring::npos && dot > path.find_last_of(L"\\/")) path.erase(dot);
            path += L".scp";
        }
        Job j;
        j.kind = Job::dump;
        j.path = path;
        queueJob(j);
    }

    static ULONGLONG fileSize(const std::wstring& path)
    {
        WIN32_FILE_ATTRIBUTE_DATA a;
        if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &a)) return 0;
        return (ULONGLONG(a.nFileSizeHigh) << 32) | a.nFileSizeLow;
    }

    bool askImage(const wchar_t* title, std::wstring& path)
    {
        wchar_t file[MAX_PATH * 4] = {};
        std::wstring dir = images.empty() ? startFolder() : dirName(images.begin()->second->path);
        OPENFILENAMEW ofn = {};
        ofn.lStructSize = sizeof ofn;
        ofn.hwndOwner = g_hwnd;
        ofn.lpstrFilter = L"Floppy image (*.adf, *.img, *.ima)\0*.adf;*.img;*.ima\0";
        ofn.lpstrFile = file;
        ofn.nMaxFile = (DWORD)std::size(file);
        ofn.lpstrInitialDir = dir.c_str();
        ofn.lpstrTitle = title;
        ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER;
        SetForegroundWindow(g_hwnd);
        if (!GetOpenFileNameW(&ofn)) return false;
        path = fullPath(file);
        return true;
    }

    void writeAsk()
    {
        if (state != State::mounted && state != State::remove) return;
        std::wstring path;
        if (!askImage(L"Write image to disk", path)) return;
        std::wstring name = fileName(path);
        ULONGLONG size = fileSize(path);
        if (size != 901120 && size != 1802240 && size != 737280 && size != 1474560)
        {
            notify(L"Cannot write image", name + L" is not an 880K/1.76M ADF or a 720K/1.44M PC floppy image.");
            return;
        }

        // Confirm: everything on the real disk is overwritten
        std::wstring instruction = L"Write " + name + L" to " + (volume.empty() ? L"the disk in the drive" : volume) + L"?";
        TASKDIALOG_BUTTON buttons[] = {{IDOK, L"Write"}};
        TASKDIALOGCONFIG tc = {};
        tc.cbSize = sizeof tc;
        tc.hwndParent = g_hwnd;
        tc.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW;
        tc.dwCommonButtons = TDCBF_CANCEL_BUTTON;
        tc.pszWindowTitle = kAppName;
        tc.pszMainIcon = TD_WARNING_ICON;
        tc.pszMainInstruction = instruction.c_str();
        tc.pszContent = L"Everything on the disk in the drive will be overwritten. "
                        L"Only the tracks that differ are rewritten, each one verified.";
        tc.pszVerificationText = L"Erase and rewrite every track (slower, like formatting)";
        tc.cButtons = 1;
        tc.pButtons = buttons;
        int button = 0;
        BOOL full = FALSE;
        SetForegroundWindow(g_hwnd);
        if (FAILED(TaskDialogIndirect(&tc, &button, nullptr, &full)) || button != IDOK) return;
        Job j;
        j.kind = Job::write;
        j.path = path;
        j.full = full != FALSE;

        // Close the image if it is open as a virtual disk, so every change is in the file
        auto it = images.find(upper(path));
        if (it != images.end() && !it->second->mountpoint.empty())
        {
            if (!unmount(it->second->mountpoint))
            {
                notify(L"Image in use", L"Close the windows using the virtual disk " + it->second->mountpoint +
                       L", then try again.");
                return;
            }
            waitExit(it->second->proc, 30000, [this, j] { queueJob(j); });
            return;
        }
        queueJob(j);
    }

    /// Free the port (unmount the real disk or stop the waiting helper), then run the job
    void queueJob(Job j)
    {
        if (state != State::mounted && state != State::remove) return;    // the disk went away meanwhile
        // Remount afterwards: the same disk after a dump, the new content after a write
        j.remount = state == State::mounted || j.kind == Job::write;
        job = std::make_unique<Job>(j);
        if (state == State::mounted && !mountpoint.empty())
        {
            if (!unmount(mountpoint))
            {
                job.reset();
                notify(L"Disk in use", L"Close the windows and programs using the disk, then try again.");
                return;
            }
            setState(State::ejecting, L"Waffle: writing pending changes first…", IDI_TRAY_MOUNTING);
            // driverExit starts the job once the driver has released the port
        }
        else
        {
            stopHelper([this] { startJob(); });
        }
    }

    void startJob()
    {
        if (!job || port.empty()) return;
        Job& j = *job;
        std::wstring name = fileName(j.path);
        j.tracks = 0;
        std::vector<std::wstring> args;
        if (j.kind == Job::dump)
        {
            setState(State::busy, L"Waffle: copying the disk to " + name + L"…", IDI_TRAY_MOUNTING);
            showJobWindow(L"Copying disk", L"Copying the disk to\n" + j.path);
            // Into a temporary file: an existing file is only replaced by a finished copy
            std::wstring ext = extension(j.path);
            for (auto& c : ext) c = (wchar_t)towlower(c);
            j.tmp = j.path + L".part" + (ext.empty() ? L"" : L"." + ext);
            args = {L"--dump", port, j.tmp};
        }
        else
        {
            setState(State::busy, L"Waffle: writing " + name + L" to the disk…", IDI_TRAY_MOUNTING);
            showJobWindow(L"Writing image to disk", L"Writing\n" + j.path + L"\nto the disk in the drive");
            args = {L"--write-image", port, j.path, L"--yes"};
            if (j.full) args.push_back(L"--full");
        }
        proc = startProc(args, [this](const Event& ev) { jobEvent(ev); }, [this](int code) { jobExit(code); });
    }

    void showJobWindow(const std::wstring& title, const std::wstring& text)
    {
        HDC dc = GetDC(nullptr);
        int dpi = GetDeviceCaps(dc, LOGPIXELSY);
        ReleaseDC(nullptr, dc);
        auto px = [dpi](int v) { return MulDiv(v, dpi, 96); };

        RECT r = {0, 0, px(440), px(160)};
        DWORD style = WS_CAPTION | WS_POPUP | WS_SYSMENU;
        AdjustWindowRectEx(&r, style, FALSE, WS_EX_TOPMOST | WS_EX_TOOLWINDOW);
        int w = r.right - r.left, h = r.bottom - r.top;
        int x = (GetSystemMetrics(SM_CXSCREEN) - w) / 2, y = (GetSystemMetrics(SM_CYSCREEN) - h) / 2;
        jobWindow = CreateWindowExW(WS_EX_TOPMOST, kJobClass, title.c_str(), style, x, y, w, h, nullptr, nullptr,
                                    g_inst, nullptr);

        NONCLIENTMETRICSW ncm = {};
        ncm.cbSize = sizeof ncm;
        SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof ncm, &ncm, 0);
        static HFONT font = CreateFontIndirectW(&ncm.lfMessageFont);

        HWND label = CreateWindowExW(0, L"STATIC", text.c_str(), WS_CHILD | WS_VISIBLE | SS_LEFT | SS_PATHELLIPSIS,
                                     px(16), px(12), px(408), px(56), jobWindow, nullptr, g_inst, nullptr);
        jobBar = CreateWindowExW(0, PROGRESS_CLASSW, nullptr, WS_CHILD | WS_VISIBLE, px(16), px(76), px(408), px(20),
                                 jobWindow, nullptr, g_inst, nullptr);
        SendMessageW(jobBar, PBM_SETRANGE32, 0, 160);
        jobStatus = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_LEFT, px(16), px(118), px(300),
                                    px(20), jobWindow, nullptr, g_inst, nullptr);
        HWND cancel = CreateWindowExW(0, L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
                                      px(334), px(112), px(90), px(30), jobWindow, (HMENU)IDCANCEL, g_inst, nullptr);
        for (HWND c : {label, jobStatus, cancel}) SendMessageW(c, WM_SETFONT, (WPARAM)font, TRUE);
        ShowWindow(jobWindow, SW_SHOWNORMAL);
        SetForegroundWindow(jobWindow);
    }

    void closeJobWindow()
    {
        if (jobWindow) DestroyWindow(jobWindow);
        jobWindow = jobBar = jobStatus = nullptr;
    }

    void jobEvent(const Event& ev)
    {
        if (!job) return;
        std::string e = field(ev, "event");
        if (e == "track")
        {
            job->tracks++;
            if (jobBar) SendMessageW(jobBar, PBM_SETPOS, std::min(job->tracks, 160), 0);
            std::string st = field(ev, "status");
            std::wstring s = L"cylinder " + widen(field(ev, "cylinder")) + L"  head " + widen(field(ev, "head"));
            if (st == "unchanged" || st == "failed" || st == "bad") s += L"  (" + widen(st) + L")";
            if (jobStatus) SetWindowTextW(jobStatus, s.c_str());
        }
        else if (e == "dumped")
        {
            job->bad = atoi(field(ev, "bad").c_str());
        }
        else if (e == "written")
        {
            std::string t = field(ev, "tracks");
            if (!t.empty()) job->written = atoi(t.c_str());
        }
    }

    void jobCancel()
    {
        if (proc && job && state == State::busy)
        {
            job->cancelled = true;
            proc->stop();                   // waffle-fuse stops between two tracks
        }
    }

    void jobExit(int code)
    {
        if (!job) return;
        Job j = *job;
        job.reset();
        std::deque<std::string> tail = proc ? proc->stderrTail : std::deque<std::string> {};
        proc = nullptr;
        closeJobWindow();
        std::wstring name = fileName(j.path);
        std::wstring lastError = L"error " + std::to_wstring(code);
        if (!tail.empty())
        {
            std::string l = tail.back();
            if (l.compare(0, 13, "waffle-fuse: ") == 0) l.erase(0, 13);
            lastError = widen(l);
        }

        if (j.kind == Job::dump)
        {
            if (fileExists(j.tmp) && (code == EXIT_OK || code == EXIT_DRIVE) && !j.cancelled)
                MoveFileExW(j.tmp.c_str(), j.path.c_str(), MOVEFILE_REPLACE_EXISTING);
            else
                DeleteFileW(j.tmp.c_str());     // never leave a half-written image around
            if (j.cancelled)
                notify(L"Copy cancelled", name);
            else if (code == EXIT_OK)
                notify(L"Disk copied", j.path);
            else if (code == EXIT_DRIVE && j.bad > 0)
                notify(L"Disk copied with errors", j.path + L"\n" + std::to_wstring(j.bad) +
                       L" sectors could not be read (saved as zeros).");
            else if (code == EXIT_DRIVE && fileExists(j.path))
                notify(L"Disk copied with errors", j.path + L"\nSome tracks had read problems.");
            else
                notify(L"Copy failed", name + L": " + lastError);
        }
        else
        {
            if (j.cancelled)
                notify(L"Write stopped", L"The disk now holds part of the image only.");
            else if (code == EXIT_OK)
                notify(L"Image written", name + L" written to the disk" +
                       (j.written >= 0 ? L" (" + std::to_wstring(j.written) + L" tracks rewritten and verified)." : L"."));
            else
                notify(L"Write failed", name + L": " + lastError);
        }
        if (quitting) return;
        if (j.remount && code != EXIT_NODISK) mount();
        else waitRemoval();
    }

    // ── Floppy images as virtual disks ───────────────────────────────────────

    void openImageAsk()
    {
        std::wstring path;
        if (askImage(L"Open image as virtual disk", path)) openImage(path);
    }

    void openImage(const std::wstring& path)
    {
        std::wstring key = upper(path);
        auto it = images.find(key);
        if (it != images.end())
        {
            if (!it->second->mountpoint.empty()) openInExplorer(it->second->mountpoint);   // already open: show it
            return;
        }
        logLine(L"open: " + path);
        auto disk = std::make_shared<VirtualDisk>();
        disk->path = path;
        std::weak_ptr<VirtualDisk> weak = disk;
        std::vector<std::wstring> args = {L"--image", path};
        for (auto& a : mountTarget()) args.push_back(a);
        for (auto& a : driverDebug()) args.push_back(a);
        disk->proc = startProc(args, [weak](const Event& ev)
        {
            auto d = weak.lock();
            if (d && field(ev, "event") == "mounted")
            {
                d->mountpoint = widen(field(ev, "mountpoint"));
                openInExplorer(d->mountpoint);
            }
        }, [this, key, weak](int code)
        {
            auto d = weak.lock();
            images.erase(key);
            if (d && code != EXIT_OK && d->mountpoint.empty())
            {
                std::wstring reason;
                switch (code)
                {
                case EXIT_UNKNOWN_FMT:
                    reason = L"Not an AmigaDOS or FAT image (NDOS game, copy-protected or not a floppy).";
                    break;
                case EXIT_FILESYSTEM:
                    reason = L"The filesystem in the image is not valid.";
                    break;
                default:
                    reason = d->proc->stderrTail.empty() ? L"error " + std::to_wstring(code)
                                                         : widen(d->proc->stderrTail.back());
                }
                notify(L"Cannot open " + fileName(d->path), reason);
            }
        });
        images[key] = disk;
    }

    void ejectImage(const std::shared_ptr<VirtualDisk>& disk)
    {
        if (disk->mountpoint.empty()) return;
        if (!unmount(disk->mountpoint))
            notify(L"Image in use", L"Close the windows using " + disk->mountpoint + L", then eject again.");
        else
            notify(L"Image closed", fileName(disk->path) + L": all changes saved.");
    }
};

static App g_app;

// ── Window procedures ────────────────────────────────────────────────────────

static LRESULT CALLBACK jobProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg)
    {
    case WM_COMMAND:
        if (LOWORD(wp) == IDCANCEL) g_app.jobCancel();
        return 0;
    case WM_CLOSE:
        g_app.jobCancel();
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static LRESULT CALLBACK wndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg)
    {
    case WM_APP_TRAY:
        switch (LOWORD(lp))
        {
        case WM_CONTEXTMENU:
        case NIN_SELECT:
        case NIN_KEYSELECT:
            g_app.showMenu();
            break;
        }
        return 0;

    case WM_APP_LINE:
    {
        std::unique_ptr<Line> line(reinterpret_cast<Line*>(lp));
        auto it = g_procs.find(reinterpret_cast<Proc*>(wp));
        if (it == g_procs.end()) return 0;
        ProcPtr p = it->second;
        std::string name = narrow(p->name);
        if (line->isStderr)
        {
            logLine("  [" + name + "] " + line->text);
            p->stderrTail.push_back(line->text);
            if (p->stderrTail.size() > 5) p->stderrTail.pop_front();
            return 0;
        }
        Event ev;
        if (!parseEvent(line->text, ev)) return 0;
        if (App::field(ev, "event") != "track") logLine("  [" + name + "] " + line->text);
        if (!p->cancelled && p->onEvent) p->onEvent(ev);
        return 0;
    }

    case WM_APP_EXIT:
    {
        auto it = g_procs.find(reinterpret_cast<Proc*>(wp));
        if (it == g_procs.end()) return 0;
        ProcPtr p = it->second;         // alive until the callback is done
        g_procs.erase(it);
        logLine("  [" + narrow(p->name) + "] exit " + std::to_string((int)lp));
        if (!p->cancelled && p->onExit) p->onExit((int)lp);
        return 0;
    }

    case WM_APP_CALL:
    {
        std::unique_ptr<std::function<void()>> f(reinterpret_cast<std::function<void()>*>(lp));
        (*f)();
        return 0;
    }

    case WM_TIMER:
    {
        KillTimer(hwnd, wp);
        auto it = g_timers.find(wp);
        if (it == g_timers.end()) return 0;
        auto f = std::move(it->second);
        g_timers.erase(it);
        f();
        return 0;
    }

    case WM_COPYDATA:
    {
        // A second instance: images to open, or --quit
        auto* cd = reinterpret_cast<COPYDATASTRUCT*>(lp);
        if (cd->dwData != 1) return FALSE;
        std::wstring all(static_cast<const wchar_t*>(cd->lpData), cd->cbData / sizeof(wchar_t));
        std::vector<std::wstring> args;
        size_t start = 0, nl;
        while ((nl = all.find(L'\n', start)) != std::wstring::npos)
        {
            args.push_back(all.substr(start, nl - start));
            start = nl + 1;
        }
        if (start < all.size()) args.push_back(all.substr(start));
        // After returning: the sender is waiting for this message
        postCall([args] { g_app.openArgs(args); });
        return TRUE;
    }

    case WM_QUERYENDSESSION:
        if (g_app.anythingMounted()) ShutdownBlockReasonCreate(hwnd, L"Writing the changes to the floppy disk");
        return TRUE;

    case WM_ENDSESSION:
        if (wp) g_app.quit(true);
        return 0;

    case WM_CLOSE:
        g_app.quit();
        return 0;

    default:
        if (msg == g_taskbarCreated && g_taskbarCreated)
        {
            // Explorer restarted: the icon must be added again
            NOTIFYICONDATAW n = g_nid;
            n.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE | NIF_SHOWTIP;
            Shell_NotifyIconW(NIM_ADD, &n);
            n.uVersion = NOTIFYICON_VERSION_4;
            Shell_NotifyIconW(NIM_SETVERSION, &n);
            return 0;
        }
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

// ── main ─────────────────────────────────────────────────────────────────────

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int)
{
    g_inst = inst;
    int argc = 0;
    wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    std::vector<std::wstring> args(argv + 1, argv + argc);
    LocalFree(argv);

    // One instance: a second launch ("Open with" while running, --quit) goes to
    // the first.  The mutexes also let the installer see that the app is running.
    HANDLE mutex = CreateMutexW(nullptr, FALSE, L"WaffleDiskFlashback");
    bool running = GetLastError() == ERROR_ALREADY_EXISTS;
    CreateMutexW(nullptr, FALSE, L"Global\\WaffleDiskFlashback");
    if (running)
    {
        HWND other = nullptr;
        for (int i = 0; i < 50 && !(other = FindWindowW(kWindowClass, nullptr)); i++) Sleep(100);
        if (other && !args.empty())
        {
            std::wstring all;
            for (auto& a : args)
            {
                std::wstring ext = extension(a);
                all += (ext != L"ADF" && ext != L"IMG" && ext != L"IMA" ? a : fullPath(a)) + L"\n";
            }
            COPYDATASTRUCT cd = {1, (DWORD)(all.size() * sizeof(wchar_t)), (PVOID)all.c_str()};
            AllowSetForegroundWindow(ASFW_ANY);     // --menu: the menu takes the focus
            DWORD_PTR result;
            SendMessageTimeoutW(other, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&cd), SMTO_ABORTIFHUNG, 10000, &result);
        }
        return 0;
    }
    if (args.size() == 1 && args[0] == L"--quit") return 0;     // nothing running

    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    INITCOMMONCONTROLSEX icc = {sizeof icc, ICC_PROGRESS_CLASS | ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&icc);
    rotateLog();

    if (!fileExists(waffleBin()))
    {
        MessageBoxW(nullptr, (L"waffle-fuse.exe is missing: it must be next to WaffleDiskFlashback.exe.\n\n" +
                              waffleBin()).c_str(), kAppName, MB_ICONERROR);
        return 1;
    }
    if (!winfspInstalled())
    {
        logLine("WinFsp not installed");
        if (MessageBoxW(nullptr, L"WinFsp is not installed.\n\nWaffle DiskFlashback mounts floppies as drives with "
                        L"WinFsp, free software. Open winfsp.dev to download it?", kAppName,
                        MB_ICONWARNING | MB_YESNO) == IDYES)
            ShellExecuteW(nullptr, L"open", L"https://winfsp.dev", nullptr, nullptr, SW_SHOWNORMAL);
        return 1;
    }

    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = wndProc;
    wc.hInstance = inst;
    wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(IDI_APP));
    wc.lpszClassName = kWindowClass;
    RegisterClassExW(&wc);
    WNDCLASSEXW jc = {};
    jc.cbSize = sizeof jc;
    jc.lpfnWndProc = jobProc;
    jc.hInstance = inst;
    jc.hIcon = wc.hIcon;
    jc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    jc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    jc.lpszClassName = kJobClass;
    RegisterClassExW(&jc);

    // A hidden top-level window: it gets the icon callbacks and TaskbarCreated
    g_hwnd = CreateWindowExW(WS_EX_TOOLWINDOW, kWindowClass, kAppName, WS_OVERLAPPED, 0, 0, 0, 0, nullptr, nullptr,
                             inst, nullptr);
    g_taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
    ChangeWindowMessageFilterEx(g_hwnd, g_taskbarCreated, MSGFLT_ALLOW, nullptr);
    ChangeWindowMessageFilterEx(g_hwnd, WM_COPYDATA, MSGFLT_ALLOW, nullptr);

    g_app.start(args);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0)
    {
        if (g_app.jobWindow && IsDialogMessageW(g_app.jobWindow, &msg)) continue;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    CloseHandle(mutex);
    return 0;
}
