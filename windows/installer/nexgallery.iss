; nexGallery Windows installer (Inno Setup 6).
;
;   flutter build windows --release        (after dart run tool/build_server.dart)
;   iscc /DAppVersion=0.1.0 windows\installer\nexgallery.iss
;
; Installs per user without administrator rights, matching the background
; server, which runs with the signed-in user's own permissions. Reinstalling
; the same or a newer version upgrades in place; keeping the previous signed
; installer is the rollback path.
;
; Release builds are signed: configure a SignTool named "nexsign" in the Inno
; Setup IDE or with /Snexsign="signtool sign /fd sha256 /tr <timestamp> ..."
; and build with /DSign. Development builds are unsigned.

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#define AppName "nexGallery"
#define AppExe "nex_gallery.exe"
#define AgentExe "nexgallery_server.exe"
#define BuildDir "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={{6C7E5D39-6F57-4B0B-9C8E-2E4F0B1A7D21}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=TheNex
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir=..\..\build\installer
OutputBaseFilename=nexGallery-{#AppVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#AppExe}
CloseApplications=yes
#ifdef Sign
SignTool=nexsign
SignedUninstaller=yes
#endif

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked

[Run]
Filename: "{app}\{#AppExe}"; Description: "Open {#AppName}"; Flags: nowait postinstall skipifsilent
; In-app updates run this installer with /SILENT; reopen the app afterwards.
Filename: "{app}\{#AppExe}"; Flags: nowait; Check: WizardSilent

[UninstallRun]
; Stop the background server so its files can be removed.
Filename: "{sys}\taskkill.exe"; Parameters: "/IM {#AgentExe} /F"; Flags: runhidden; RunOnceId: "StopAgent"

[Registry]
; The app adds this sign-in entry only when the owner turns on "Keep running
; when nexGallery is closed"; uninstalling always removes it.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "nexGalleryServer"; ValueData: """{app}\server\bin\nexgallery_server.exe"" --config ""{localappdata}\nexGallery\server\agent.json"""; Flags: uninsdeletevalue dontcreatekey; Check: ServerAutoStartEnabled

[Code]
// Upgrades relocate the agent's complete native-asset bundle. Keep a user's
// existing sign-in choice while avoiding an automatic opt-in on new installs.
function ServerAutoStartEnabled: Boolean;
begin
  Result := RegValueExists(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'nexGalleryServer');
end;

// Upgrades replace the agent, so it must not be running.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM {#AgentExe} /F', '',
    SW_HIDE, ewWaitUntilTerminated, Code);
  Result := '';
end;

// The catalogue, paired phones, server identity and caches are personal
// data. Originals are never inside this folder.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Data: String;
begin
  if CurUninstallStep <> usPostUninstall then Exit;
  Data := ExpandConstant('{localappdata}\nexGallery');
  if not DirExists(Data) then Exit;
  if UninstallSilent then Exit;
  if MsgBox('Also delete nexGallery''s albums, paired phones, server identity '
    + 'and caches from this PC?' + #13#10#13#10
    + 'Your photos and files are not affected. Choose No to keep them for a '
    + 'later reinstall.', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    DelTree(Data, True, True, True);
end;
