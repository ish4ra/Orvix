#define MyAppName "Orvix"
#ifndef MyAppVersion
#define MyAppVersion "0.5.7"
#endif
#define MyAppPublisher "Ishara Lakshan"
#define MyAppExeName "orvix.exe"
#define MyIconName "orvix-v0.7.9-beta.7.ico"

[Setup]
AppId={{C580B2E6-5A7A-4FD7-8C68-36D238B4497B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\Orvix
DefaultGroupName=Orvix
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\installer-output
OutputBaseFilename=Orvix-Setup-v{#MyAppVersion}-Windows-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyIconName}
SetupIconFile=..\windows\runner\resources\app_icon.ico
SetupLogging=yes
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\windows\runner\resources\app_icon.ico"; DestDir: "{app}"; DestName: "{#MyIconName}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Orvix"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyIconName}"
Name: "{autodesktop}\Orvix"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyIconName}"; Tasks: desktopicon


[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  { beta.2 and older could leave the bundled P2P engine alive after the UI
    process exited. A running executable cannot be replaced on Windows. Stop
    only Orvix's own pinned stream-server before file replacement. }
  Exec(
    ExpandConstant('{sys}\taskkill.exe'),
    '/F /IM orvix-stream-server.exe',
    '',
    SW_HIDE,
    ewWaitUntilTerminated,
    ResultCode
  );
  Exec(
    ExpandConstant('{sys}\taskkill.exe'),
    '/F /IM orvix-media-engine.exe',
    '',
    SW_HIDE,
    ewWaitUntilTerminated,
    ResultCode
  );
  Sleep(350);
  Result := '';
end;

[Run]
; Ask Windows Explorer to refresh icon associations after replacing the app.
Filename: "{sys}\ie4uinit.exe"; Parameters: "-show"; Flags: runhidden waituntilterminated skipifdoesntexist
Filename: "{app}\{#MyAppExeName}"; Description: "Launch Orvix"; Flags: nowait postinstall skipifsilent
