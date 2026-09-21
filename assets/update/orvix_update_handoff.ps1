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

function Find-OrvixExecutable() {
  try {
    $uninstallRoots = @(
      'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
      'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
      'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    foreach ($root in $uninstallRoots) {
      if (-not (Test-Path $root)) { continue }
      foreach ($entry in Get-ChildItem $root -ErrorAction SilentlyContinue) {
        try {
          $props = Get-ItemProperty $entry.PSPath -ErrorAction Stop
          if ($props.DisplayName -ne 'Orvix') { continue }
          $location = [string]$props.InstallLocation
          if ([string]::IsNullOrWhiteSpace($location)) { continue }
          $candidate = Join-Path $location 'orvix.exe'
          if (Test-Path -LiteralPath $candidate) { return $candidate }
        } catch {}
      }
    }
  } catch {}

  $defaultCandidate = Join-Path $env:LOCALAPPDATA 'Programs\Orvix\orvix.exe'
  if (Test-Path -LiteralPath $defaultCandidate) { return $defaultCandidate }

  if (Test-Path -LiteralPath $RestartExe) { return $RestartExe }
  return $null
}

function Start-OrvixAfterUpdate() {
  if (Get-Process -Name 'orvix' -ErrorAction SilentlyContinue) {
    Write-OrvixUpdateLog "Orvix is already running after installer completion."
    return
  }

  $candidate = Find-OrvixExecutable
  if ($null -ne $candidate) {
    Write-OrvixUpdateLog "Launching Orvix from: $candidate"
    Start-Process -FilePath $candidate
  } else {
    Write-OrvixUpdateLog "No Orvix executable could be found after update."
  }
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
    Start-OrvixAfterUpdate
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

  Start-OrvixAfterUpdate
} catch {
  Write-OrvixUpdateLog ("Handoff failed: " + $_.Exception.Message)
  Write-OrvixStatus ("failed|exception|$TargetVersion")
  try { Start-OrvixAfterUpdate } catch {}
  exit 1
}
