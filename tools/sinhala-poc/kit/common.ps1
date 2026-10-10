# Asks for your own Gemini API key once per PowerShell window. The key is kept
# only in this window's environment (never written to disk, never passed on
# the command line) and is sent only to generativelanguage.googleapis.com.
function Set-GeminiKey {
  if (-not $env:ORVIX_POC_GEMINI_KEY) {
    $sec = Read-Host "Paste your Gemini API key (input hidden)" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $env:ORVIX_POC_GEMINI_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
  }
  if (-not (Test-Path ".\mpv\mpv.exe") -and -not (Get-Command mpv -ErrorAction SilentlyContinue)) {
    throw "mpv.exe not found. Put mpv.exe in the 'mpv' folder next to this script (see README)."
  }
  if (Get-Process -Name "orvix" -ErrorAction SilentlyContinue) {
    Write-Warning "Orvix is running. Close it so it does not share or restart the torrent engine during the test."
  }
}
