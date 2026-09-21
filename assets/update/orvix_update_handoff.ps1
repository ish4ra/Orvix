param(
  [int]$ParentPid,
  [string]$Installer,
  [string]$RestartExe,
  [string]$TargetVersion,
  [string]$LogPath,
  [string]$InstallerLog,
  [string]$StatusPath
)

$ErrorActionPreference = 'Stop'

function Write-OrvixUpdateLog([string]$Message) {
  try {
    Add-Content -LiteralPath $LogPath -Value ("[" + (Get-Date -Format o) + "] " + $Message)
  } catch {}
}

function Write-OrvixStatus([string]$Value) {
  try {
    Set-Content -LiteralPath $StatusPath -Value $Value -Encoding UTF8
  } catch {}
}

try {
  Write-OrvixUpdateLog "Waiting for Orvix PID $ParentPid to exit."
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) -and
         ((Get-Date) -lt $deadline)) {
    Start-Sleep -Milliseconds 200
  }

  if (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
    Write-OrvixUpdateLog "Parent process did not exit in time."
    Write-OrvixStatus "failed|parent_timeout|$TargetVersion"
    if (Test-Path -LiteralPath $RestartExe) {
      Start-Process -FilePath $RestartExe
    }
    exit 2
  }

  Start-Sleep -Milliseconds 350
  Write-OrvixUpdateLog "Starting installer: $Installer"

  $installerArgs = @(
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
    '/SP-',
    ('/LOG="' + $InstallerLog + '"')
  )

  $process = Start-Process -FilePath $Installer -ArgumentList $installerArgs -Wait -PassThru
  Write-OrvixUpdateLog "Installer exit code: $([int]$process.ExitCode)"

  if ($process.ExitCode -eq 0) {
    Write-OrvixStatus "success|0|$TargetVersion"
  } else {
    Write-OrvixStatus ("failed|" + $process.ExitCode + "|$TargetVersion")
  }

  if (Test-Path -LiteralPath $RestartExe) {
    Start-Process -FilePath $RestartExe
  } else {
    Write-OrvixUpdateLog "Restart executable not found: $RestartExe"
  }
} catch {
  Write-OrvixUpdateLog ("Handoff failed: " + $_.Exception.Message)
  Write-OrvixStatus ("failed|exception|$TargetVersion")
  if (Test-Path -LiteralPath $RestartExe) {
    try { Start-Process -FilePath $RestartExe } catch {}
  }
  exit 1
}
