#define MyAppName "Orvix"
#ifndef MyAppVersion
#define MyAppVersion "0.5.7"
#endif
#define MyAppPublisher "Ishara Lakshan"
#define MyAppExeName "orvix.exe"

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
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile=..\windows\runner\resources\app_icon.ico
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Orvix"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\Orvix"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch Orvix"; Flags: nowait postinstall skipifsilent
Filename: "{app}\{#MyAppExeName}"; Flags: nowait; Check: WizardSilent

[Code]
function IsOrvixRunning(): Boolean;
var
  ResultCode: Integer;
  PowerShellPath: String;
  Params: String;
begin
  PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Params :=
    '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ' +
    '"if (Get-Process -Name ''''orvix'''' -ErrorAction SilentlyContinue) { exit 7 } else { exit 0 }"';

  if Exec(PowerShellPath, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := ResultCode = 7
  else
    Result := False;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Attempt: Integer;
begin
  Result := '';

  { Older Orvix beta updaters start the installer while the app is still
    alive and then exit shortly afterwards. Wait here before file replacement
    so that beta.17/beta.18 can safely bootstrap into the new handoff updater. }
  for Attempt := 0 to 120 do
  begin
    if not IsOrvixRunning() then
      Exit;
    Sleep(250);
  end;

  Result :=
    'Orvix is still running. Close Orvix completely, then run the update again.';
end;
