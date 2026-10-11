; waffle-fuse installer for Windows (Inno Setup 7, 64-bit; Inno Setup 6 builds a 32-bit one)
;
; Built by windows/make-installer.sh, which downloads the WinFsp MSI into
; windows/build/ and passes the version:
;   ISCC /DAppVersion=1.2.3 /DNumericVersion=1.2.3 /DWinFspVersion=2.1 waffle-fuse.iss
;
; Installs the Waffle DiskFlashback tray app and waffle-fuse.exe in Program
; Files, optionally starts the app at login, opens .adf images with it and adds
; waffle-fuse to the PATH, and installs WinFsp (bundled MSI) when it is
; missing.  WinFsp is left in place on uninstall: other programs may use it.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef NumericVersion
  #define NumericVersion "0.0.0"
#endif
#ifndef WinFspVersion
  #define WinFspVersion "2.1"
#endif

#define EnvKey "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
#define RunKey "Software\Microsoft\Windows\CurrentVersion\Run"
#define TrayExe "WaffleDiskFlashback.exe"

[Setup]
AppId={{6B0F3C1E-7A52-4D8B-9C2E-5F1A0D3B8E47}
AppName=Waffle DiskFlashback (waffle-fuse)
AppVersion={#AppVersion}
AppVerName=Waffle DiskFlashback (waffle-fuse) {#AppVersion}
AppPublisher=Gianluca Renzi
AppPublisherURL=https://github.com/gianlucarenzi/waffle-fuse
AppSupportURL=https://github.com/gianlucarenzi/waffle-fuse/issues
VersionInfoVersion={#NumericVersion}
VersionInfoDescription=waffle-fuse setup
DefaultDirName={autopf}\waffle-fuse
DefaultGroupName=waffle-fuse
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
OutputDir=..\dist
OutputBaseFilename=waffle-fuse-setup-{#AppVersion}
SetupIconFile=waffle-fuse.ico
UninstallDisplayIcon={app}\{#TrayExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Program Files, the system PATH and the WinFsp MSI need administrator rights
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#if Ver >= EncodeVer(7, 0, 0)
; Inno Setup 7: Setup and the uninstaller are 64-bit programs too (with
; Inno Setup 6 they stay 32-bit)
SetupArchitecture=x64
#endif
; Windows 10 1903: UTF-8 process code page (see waffle-fuse.exe.manifest)
MinVersion=10.0.18362
ChangesEnvironment=yes
ChangesAssociations=yes
; The app is closed by CloseTrayApp below, which unmounts its disks first: the
; Restart Manager would just end it
CloseApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"

[CustomMessages]
english.StartAtLogin=Start Waffle DiskFlashback when I log in
italian.StartAtLogin=Avvia Waffle DiskFlashback all'accesso
english.Associate=Open .adf floppy images with Waffle DiskFlashback
italian.Associate=Apri le immagini floppy .adf con Waffle DiskFlashback
english.StartNow=Start Waffle DiskFlashback
italian.StartNow=Avvia Waffle DiskFlashback
english.ImageType=Floppy disk image
italian.ImageType=Immagine di dischetto
english.ClosingApp=Closing Waffle DiskFlashback (writing the changes to the disks)...
italian.ClosingApp=Chiusura di Waffle DiskFlashback (scrittura delle modifiche sui dischi)...
english.AddToPath=Add waffle-fuse to the PATH (use it from any Command Prompt)
italian.AddToPath=Aggiungi waffle-fuse al PATH (usabile da qualsiasi Prompt dei comandi)
english.InstallWinFsp=Install WinFsp {#WinFspVersion} (needed to mount disks as drives)
italian.InstallWinFsp=Installa WinFsp {#WinFspVersion} (serve per montare i dischi come unità)
english.InstallingWinFsp=Installing WinFsp...
italian.InstallingWinFsp=Installazione di WinFsp...
english.WinFspFailed=WinFsp could not be installed (error %1).%n%nInstall it from https://winfsp.dev, or waffle-fuse cannot mount disks.
italian.WinFspFailed=Non è stato possibile installare WinFsp (errore %1).%n%nInstallalo da https://winfsp.dev, altrimenti waffle-fuse non può montare i dischi.
english.CommandPrompt=waffle-fuse (Command Prompt)
italian.CommandPrompt=waffle-fuse (Prompt dei comandi)
english.ReadMe=waffle-fuse - Read me
italian.ReadMe=waffle-fuse - Leggimi

[Tasks]
Name: "startup"; Description: "{cm:StartAtLogin}"
Name: "associate"; Description: "{cm:Associate}"
Name: "addtopath"; Description: "{cm:AddToPath}"
Name: "winfsp"; Description: "{cm:InstallWinFsp}"; Check: not WinFspInstalled

[Files]
Source: "..\{#TrayExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\waffle-fuse.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\packaging\windows\README.txt"; DestDir: "{app}"; Flags: ignoreversion isreadme
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "build\winfsp.msi"; DestDir: "{tmp}"; Flags: deleteafterinstall; Tasks: winfsp

[Icons]
Name: "{group}\Waffle DiskFlashback"; Filename: "{app}\{#TrayExe}"
; A Command Prompt in the user's folder, with waffle-fuse on its PATH and its help shown
Name: "{group}\{cm:CommandPrompt}"; Filename: "{cmd}"; \
    Parameters: "/k ""path {app};%PATH%& waffle-fuse --help"""; \
    WorkingDir: "{%USERPROFILE}"; IconFilename: "{app}\waffle-fuse.exe"
Name: "{group}\{cm:ReadMe}"; Filename: "{app}\README.txt"
Name: "{group}\{cm:UninstallProgram,waffle-fuse}"; Filename: "{uninstallexe}"

[Registry]
Root: HKCU; Subkey: "{#RunKey}"; ValueType: string; ValueName: "Waffle DiskFlashback"; \
    ValueData: """{app}\{#TrayExe}"""; Tasks: startup
; "Open with" for .adf/.img/.ima, the default program for .adf (an .img may be
; a CD image that Windows mounts itself)
Root: HKA; Subkey: "Software\Classes\Waffle.FloppyImage"; ValueType: string; ValueData: "{cm:ImageType}"; \
    Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Waffle.FloppyImage\DefaultIcon"; ValueType: string; \
    ValueData: "{app}\{#TrayExe},0"
Root: HKA; Subkey: "Software\Classes\Waffle.FloppyImage\shell\open\command"; ValueType: string; \
    ValueData: """{app}\{#TrayExe}"" ""%1"""
Root: HKA; Subkey: "Software\Classes\.adf\OpenWithProgids"; ValueType: string; ValueName: "Waffle.FloppyImage"; \
    ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.img\OpenWithProgids"; ValueType: string; ValueName: "Waffle.FloppyImage"; \
    ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.ima\OpenWithProgids"; ValueType: string; ValueName: "Waffle.FloppyImage"; \
    ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.adf"; ValueType: string; ValueData: "Waffle.FloppyImage"; \
    Flags: uninsdeletevalue; Tasks: associate
Root: HKLM; Subkey: "{#EnvKey}"; ValueType: expandsz; ValueName: "Path"; \
    ValueData: "{olddata};{app}"; Tasks: addtopath; Check: NeedsAddPath(ExpandConstant('{app}'))

[Run]
; As the user who started the setup, not as the administrator
Filename: "{app}\{#TrayExe}"; Description: "{cm:StartNow}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
// Quit a running Waffle DiskFlashback cleanly: it unmounts its disks first,
// writing the pending changes (an update or uninstall replaces its files)
procedure CloseTrayApp(Dir: String);
var
  ResultCode, I: Integer;
begin
  if not CheckForMutexes('WaffleDiskFlashback') then
    exit;
  if FileExists(AddBackslash(Dir) + '{#TrayExe}') then
    Exec(AddBackslash(Dir) + '{#TrayExe}', '--quit', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  for I := 1 to 120 do
  begin
    if not CheckForMutexes('WaffleDiskFlashback') then
      exit;
    Sleep(500);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  WizardForm.StatusLabel.Caption := CustomMessage('ClosingApp');
  CloseTrayApp(ExpandConstant('{app}'));
  Result := '';
end;

function InitializeUninstall: Boolean;
begin
  CloseTrayApp(ExpandConstant('{app}'));
  Result := True;
end;

// WinFsp records its directory in the 32-bit registry view
function WinFspInstalled: Boolean;
var
  Dir: String;
begin
  Result := RegQueryStringValue(HKLM32, 'SOFTWARE\WinFsp', 'InstallDir', Dir) and
            FileExists(AddBackslash(Dir) + 'bin\winfsp-x64.dll');
end;

function NeedsAddPath(Dir: String): Boolean;
var
  Path: String;
begin
  if not RegQueryStringValue(HKLM, '{#EnvKey}', 'Path', Path) then
    Result := True
  else
    Result := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(Path) + ';') = 0;
end;

procedure RemoveFromPath(Dir: String);
var
  Path: String;
  I: Integer;
begin
  if not RegQueryStringValue(HKLM, '{#EnvKey}', 'Path', Path) then
    exit;
  Path := ';' + Path + ';';
  I := Pos(';' + Uppercase(Dir) + ';', Uppercase(Path));
  if I = 0 then
    exit;
  Delete(Path, I, Length(Dir) + 1);
  Path := Copy(Path, 2, Length(Path) - 2);
  RegWriteExpandStringValue(HKLM, '{#EnvKey}', 'Path', Path);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('winfsp') then
  begin
    WizardForm.StatusLabel.Caption := CustomMessage('InstallingWinFsp');
    // 3010: installed, a restart is needed to complete it
    if not Exec('msiexec.exe', '/i "' + ExpandConstant('{tmp}\winfsp.msi') + '" /qn /norestart',
                '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or
       ((ResultCode <> 0) and (ResultCode <> 3010)) then
      SuppressibleMsgBox(FmtMessage(CustomMessage('WinFspFailed'), [IntToStr(ResultCode)]),
                         mbError, MB_OK, IDOK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    RemoveFromPath(ExpandConstant('{app}'));
    // Also set by "Start at login" in the app's menu
    RegDeleteValue(HKCU, '{#RunKey}', 'Waffle DiskFlashback');
  end;
end;
