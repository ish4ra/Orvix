# Debrid test: one file with an embedded English TEXT subtitle, played to the end.
# Usage:
#   .\run-debrid.ps1 -Url "https://...direct download link..." -SourceId "torbox-12345-678" -Title "Show S01E03"
# SourceId must stay the same for the same file (debrid links change), so
# resumes find the saved translations. The TorBox item id + file id is ideal.
param(
  [Parameter(Mandatory = $true)][string]$Url,
  [Parameter(Mandatory = $true)][string]$SourceId,
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
$pocArgs = @("--url", $Url, "--source-id", $SourceId, "--title", $Title, "--mpv", $Mpv, "--start", $Start, "--seek-plan", $SeekPlan)
if ($OrvixDir) { $pocArgs += @("--orvix-dir", $OrvixDir) }
& .\sinhala-poc.exe @pocArgs
