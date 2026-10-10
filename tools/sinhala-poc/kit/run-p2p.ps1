# Free P2P test: one previously troublesome torrent episode, played to the end.
# Usage:
#   .\run-p2p.ps1 -Magnet "magnet:?xt=urn:btih:..." -FileHint "S02E05" -Title "Show S02E05"
param(
  [Parameter(Mandatory = $true)][string]$Magnet,
  [string]$FileHint = "",
  [int]$FileIdx = -1,
  [string]$Title = "",
  [double]$Start = 0,
  [string]$OrvixDir = "",
  [string]$Mpv = ".\mpv\mpv.exe",
  [string]$SeekPlan = "auto"
)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)
. .\common.ps1
Set-GeminiKey
$pocArgs = @("--magnet", $Magnet, "--title", $Title, "--mpv", $Mpv, "--start", $Start, "--seek-plan", $SeekPlan)
if ($FileHint) { $pocArgs += @("--file-hint", $FileHint) }
if ($FileIdx -ge 0) { $pocArgs += @("--file-idx", $FileIdx) }
if ($OrvixDir) { $pocArgs += @("--orvix-dir", $OrvixDir) }
& .\sinhala-poc.exe @pocArgs
