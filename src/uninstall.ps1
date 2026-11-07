# uninstall.ps1 — stop the daemon, remove autostart, optionally delete files.
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1             # stop + remove autostart
#   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -Dir "D:\Tools\PotSkip" -DeleteFiles
param(
    [string]$Dir = "$env:LOCALAPPDATA\PotSkip",
    [switch]$DeleteFiles
)
$ErrorActionPreference = 'Continue'

# 1. stop daemon(s)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'pot-skip-daemon\.ps1' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Output ('stopped pid=' + $_.ProcessId) }

# 2. remove autostart shortcut
$lnkPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\pot-skip.lnk'
if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force; Write-Output 'autostart removed' }

# 3. files
if ($DeleteFiles) {
    if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force; Write-Output ('deleted: ' + $Dir) }
} else {
    Write-Output ('files kept at ' + $Dir + ' (pass -DeleteFiles to remove)')
}
Write-Output 'Uninstall done.'
