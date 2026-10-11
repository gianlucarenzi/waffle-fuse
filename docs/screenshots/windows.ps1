# Screenshots of waffle-fuse on Windows, for the documentation.
# Runs on a Windows desktop with WinFsp installed (CI: .github/workflows/screenshots.yml):
#
#   pwsh docs/screenshots/windows.ps1 -Out <dir> -Setup <waffle-fuse-setup.exe>
#
# WaffleDiskFlashback.exe and waffle-fuse.exe must be built in the repository.
# The demo images of docs/examples are opened as virtual disks by the tray app.

param(
    [string]$Out = "docs\images\screenshots",
    [string]$Setup = ""
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;

public static class Win
{
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool r);
    [DllImport("user32")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("dwmapi")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }

    // First visible window with this class (null: any) whose title contains title (null: any)
    public static IntPtr Find(string cls, string title)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) =>
        {
            if (!IsWindowVisible(h)) return true;
            var c = new StringBuilder(256); GetClassName(h, c, 256);
            var t = new StringBuilder(512); GetWindowText(h, t, 512);
            if ((cls == null || c.ToString() == cls) && (title == null || t.ToString().Contains(title)))
            {
                found = h;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // "class | title" of every visible top-level window, for diagnostics
    public static string List()
    {
        var sb = new StringBuilder();
        EnumWindows((h, l) =>
        {
            if (!IsWindowVisible(h)) return true;
            var c = new StringBuilder(256); GetClassName(h, c, 256);
            var t = new StringBuilder(512); GetWindowText(h, t, 512);
            if (t.Length > 0) sb.AppendLine(c + " | " + t);
            return true;
        }, IntPtr.Zero);
        return sb.ToString();
    }

    // What the window shows on the screen (without the invisible resize border)
    public static Bitmap Capture(IntPtr h)
    {
        RECT r;
        if (DwmGetWindowAttribute(h, 9 /* DWMWA_EXTENDED_FRAME_BOUNDS */, out r, 16) != 0) GetWindowRect(h, out r);
        var b = new Bitmap(r.R - r.L, r.B - r.T);
        using (var g = Graphics.FromImage(b)) g.CopyFromScreen(r.L, r.T, 0, 0, b.Size);
        return b;
    }
}
"@

function Wait-Window([string]$Class, [string]$Title, [int]$Seconds = 30) {
    for ($i = 0; $i -lt $Seconds * 4; $i++) {
        $h = [Win]::Find($Class, $Title)
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 250
    }
    Write-Warning "no window: class=$Class title=$Title; visible windows:"
    Write-Host ([Win]::List())
    return [IntPtr]::Zero
}

function Save-Window([IntPtr]$Handle, [string]$Name, [int]$Width = 0, [int]$Height = 0) {
    if ($Handle -eq [IntPtr]::Zero) { return }
    if ($Width) { [Win]::MoveWindow($Handle, 40, 40, $Width, $Height, $true) | Out-Null }
    [Win]::SetForegroundWindow($Handle) | Out-Null
    Start-Sleep -Milliseconds 1500
    $b = [Win]::Capture($Handle)
    $b.Save((Join-Path $Out $Name), [System.Drawing.Imaging.ImageFormat]::Png)
    $b.Dispose()
    Write-Host "saved $Name"
}

$root = Resolve-Path "$PSScriptRoot\..\.."
$tray = Join-Path $root "WaffleDiskFlashback.exe"

# ── The tray app opens the demo images on drive letters, in Explorer ─────────
$work = Join-Path $env:TEMP "waffle-shots"
New-Item -ItemType Directory -Force $work | Out-Null
Copy-Item "$root\docs\examples\WaffleDemo.adf", "$root\docs\examples\WAFFLEDOS.img" $work
Start-Process $tray -ArgumentList "`"$work\WaffleDemo.adf`"", "`"$work\WAFFLEDOS.img`""

Save-Window (Wait-Window "CabinetWClass" "WaffleDemo") "windows-explorer-amiga.png" 900 560
Save-Window (Wait-Window "CabinetWClass" "WAFFLEDOS") "windows-explorer-dos.png" 900 560

# This PC: the floppies as drives, with their volume names
Start-Process explorer.exe "shell:MyComputerFolder"
Save-Window (Wait-Window "CabinetWClass" "This PC") "windows-this-pc.png" 900 600

# ── The tray menu (opened by a second instance with --menu) ──────────────────
[Win]::SetCursorPos(700, 160) | Out-Null
Start-Process $tray -ArgumentList "--menu"
$menu = Wait-Window "#32768" $null 10
if ($menu -ne [IntPtr]::Zero) {
    Start-Sleep -Milliseconds 800
    $b = [Win]::Capture($menu)
    $b.Save((Join-Path $Out "windows-tray-menu.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $b.Dispose()
    Write-Host "saved windows-tray-menu.png"
    [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
}

# ── The installer: first page and the options page ───────────────────────────
if ($Setup) {
    Start-Process $Setup -ArgumentList "/LANG=english"
    $wiz = Wait-Window "TWizardForm" $null 60
    Save-Window $wiz "windows-installer-license.png"
    if ($wiz -ne [IntPtr]::Zero) {
        # Accept the license, Next (folder), Next: the tasks page
        [System.Windows.Forms.SendKeys]::SendWait("%a")
        Start-Sleep -Milliseconds 500
        [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
        Start-Sleep -Seconds 1
        [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
        Start-Sleep -Seconds 1
        Save-Window $wiz "windows-installer-tasks.png"
    }
    Get-Process | Where-Object { $_.Path -like "*\Temp\is-*" } | Stop-Process -Force -ErrorAction SilentlyContinue
}

# ── Quit the app (it unmounts the images) ────────────────────────────────────
Start-Process $tray -ArgumentList "--quit" -Wait
Start-Sleep -Seconds 5
Write-Host "--- app log"
Get-Content "$env:LOCALAPPDATA\Waffle\WaffleDiskFlashback.log" -ErrorAction SilentlyContinue
Get-ChildItem $Out
