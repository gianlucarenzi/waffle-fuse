; waffle-fuse installer for Windows (Inno Setup 6)
;
; Built by windows/make-installer.sh, which downloads the WinFsp MSI into
; windows/build/ and passes the version:
;   ISCC /DAppVersion=1.2.3 /DNumericVersion=1.2.3 /DWinFspVersion=2.1 waffle-fuse.iss
;
; Installs waffle-fuse.exe in Program Files, optionally adds it to the PATH,
; and installs WinFsp (bundled MSI) when it is missing.  WinFsp is left in
; place on uninstall: other programs may use it.

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

[Setup]
AppId={{6B0F3C1E-7A52-4D8B-9C2E-5F1A0D3B8E47}
AppName=waffle-fuse
AppVersion={#AppVersion}
AppVerName=waffle-fuse {#AppVersion}
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
UninstallDisplayIcon={app}\waffle-fuse.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Program Files, the system PATH and the WinFsp MSI need administrator rights
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Windows 10 1903: UTF-8 process code page (see waffle-fuse.exe.manifest)
MinVersion=10.0.18362
ChangesEnvironment=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"

[CustomMessages]
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
Name: "addtopath"; Description: "{cm:AddToPath}"
Name: "winfsp"; Description: "{cm:InstallWinFsp}"; Check: not WinFspInstalled

[Files]
Source: "..\waffle-fuse.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\packaging\windows\README.txt"; DestDir: "{app}"; Flags: ignoreversion isreadme
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "build\winfsp.msi"; DestDir: "{tmp}"; Flags: deleteafterinstall; Tasks: winfsp

[Icons]
; A Command Prompt in the user's folder, with waffle-fuse on its PATH and its help shown
Name: "{group}\{cm:CommandPrompt}"; Filename: "{cmd}"; \
    Parameters: "/k ""path {app};%PATH%& waffle-fuse --help"""; \
    WorkingDir: "{%USERPROFILE}"; IconFilename: "{app}\waffle-fuse.exe"
Name: "{group}\{cm:ReadMe}"; Filename: "{app}\README.txt"
Name: "{group}\{cm:UninstallProgram,waffle-fuse}"; Filename: "{uninstallexe}"

[Registry]
Root: HKLM; Subkey: "{#EnvKey}"; ValueType: expandsz; ValueName: "Path"; \
    ValueData: "{olddata};{app}"; Tasks: addtopath; Check: NeedsAddPath(ExpandConstant('{app}'))

[Code]
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
    RemoveFromPath(ExpandConstant('{app}'));
end;
