// waffle-fuse: run-time loading of the WinFsp DLL (Windows only)
//
// WinFsp installs its DLL in its own directory (C:\Program Files (x86)\WinFsp\bin),
// which is not on the PATH, and records that directory in the registry: the
// way WinFsp recommends for programs that do not link it at build time.

#ifdef _WIN32

#include "fuse_compat.h"

#include <windows.h>
#include <iostream>
#include <string>

#if defined(_M_ARM64) || defined(__aarch64__)
#define WINFSP_DLL L"winfsp-a64.dll"
#elif defined(_WIN64)
#define WINFSP_DLL L"winfsp-x64.dll"
#else
#define WINFSP_DLL L"winfsp-x86.dll"
#endif

// Every function of the WinFsp FUSE API used through <fuse3/fuse.h>
#define WINFSP_FUNCTIONS(X)                \
    X(fsp_fuse3_main_real)                 \
    X(fsp_fuse3_lib_help)                  \
    X(fsp_fuse3_new_30)                    \
    X(fsp_fuse3_new)                       \
    X(fsp_fuse3_destroy)                   \
    X(fsp_fuse3_mount)                     \
    X(fsp_fuse3_unmount)                   \
    X(fsp_fuse3_loop)                      \
    X(fsp_fuse3_loop_mt_31)                \
    X(fsp_fuse3_loop_mt)                   \
    X(fsp_fuse3_exit)                      \
    X(fsp_fuse3_get_context)               \
    X(fsp_fuse3_parse_conn_info_opts)      \
    X(fsp_fuse3_apply_conn_info_opts)      \
    X(fsp_fuse3_version)                   \
    X(fsp_fuse3_pkgversion)                \
    X(fsp_fuse_ntstatus_from_errno)        \
    X(fsp_fuse_signal_handler)             \
    X(fsp_fuse_opt_parse)                  \
    X(fsp_fuse_opt_add_arg)                \
    X(fsp_fuse_opt_insert_arg)             \
    X(fsp_fuse_opt_free_args)              \
    X(fsp_fuse_opt_add_opt)                \
    X(fsp_fuse_opt_add_opt_escaped)        \
    X(fsp_fuse_opt_match)

extern "C" {
#define WINFSP_DEFINE(n) decltype(n##_ptr) n##_ptr = nullptr;
WINFSP_FUNCTIONS(WINFSP_DEFINE)
}

// InstallDir of WinFsp (HKLM\SOFTWARE\WinFsp, in the 32-bit registry view)
static std::wstring winfspInstallDir()
{
    HKEY key;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\WinFsp", 0, KEY_READ | KEY_WOW64_32KEY, &key) != ERROR_SUCCESS)
        return L"";
    wchar_t dir[MAX_PATH] = {};
    DWORD size = sizeof dir - sizeof(wchar_t), type = 0;
    LONG r = RegQueryValueExW(key, L"InstallDir", nullptr, &type, reinterpret_cast<BYTE*>(dir), &size);
    RegCloseKey(key);
    if (r != ERROR_SUCCESS || type != REG_SZ) return L"";
    std::wstring s(dir);
    if (!s.empty() && s.back() != L'\\') s += L'\\';
    return s;
}

bool winfsp_load()
{
    static HMODULE dll = nullptr;
    if (dll) return true;

    // A DLL next to waffle-fuse.exe first (portable use), then the installed one
    dll = LoadLibraryExW(WINFSP_DLL, nullptr, LOAD_LIBRARY_SEARCH_APPLICATION_DIR);
    if (!dll)
    {
        std::wstring dir = winfspInstallDir();
        if (!dir.empty()) dll = LoadLibraryW((dir + L"bin\\" WINFSP_DLL).c_str());
    }
    if (!dll)
    {
        std::cerr << "waffle-fuse: WinFsp is not installed (download it from https://winfsp.dev)\n";
        return false;
    }

#define WINFSP_RESOLVE(n) n##_ptr = reinterpret_cast<decltype(n##_ptr)>(reinterpret_cast<void*>(GetProcAddress(dll, #n)));
    WINFSP_FUNCTIONS(WINFSP_RESOLVE)

    // The ones waffle-fuse calls must be there
    if (!fsp_fuse3_new_ptr || !fsp_fuse3_mount_ptr || !fsp_fuse3_loop_ptr || !fsp_fuse3_exit_ptr ||
        !fsp_fuse3_unmount_ptr || !fsp_fuse3_destroy_ptr || !fsp_fuse3_get_context_ptr ||
        !fsp_fuse_opt_parse_ptr || !fsp_fuse_opt_add_arg_ptr || !fsp_fuse_opt_free_args_ptr)
    {
        std::cerr << "waffle-fuse: the installed WinFsp is too old (install a newer one from https://winfsp.dev)\n";
        FreeLibrary(dll);
        dll = nullptr;
        return false;
    }
    return true;
}

#endif
