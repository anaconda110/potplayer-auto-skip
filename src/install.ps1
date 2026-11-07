# install.ps1 — deploy PotPlayer Auto Skip and register autostart.
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1                # default dir %LOCALAPPDATA%\PotSkip
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Dir "D:\Tools\PotSkip"
#   ... -NoAutostart     # skip the Startup-folder shortcut
#   ... -NoStart         # do not launch the daemon right away
param(
    [string]$Dir = "$env:LOCALAPPDATA\PotSkip",
    [switch]$NoAutostart,
    [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
$srcRoot = Split-Path -Parent $PSScriptRoot

# 1. stop any running daemon whose files we are about to replace
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'pot-skip-daemon\.ps1' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 2. copy files
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Copy-Item (Join-Path $srcRoot 'src\pot-skip-daemon.ps1') $Dir -Force
if (-not (Test-Path (Join-Path $Dir 'skip.ini'))) {
    Copy-Item (Join-Path $srcRoot 'config\skip.example.ini') (Join-Path $Dir 'skip.ini')
}

# 3. launcher vbs (hidden start, no console flash)
$vbs = Join-Path $Dir 'start-pot-skip.vbs'
$vbsBody = @'
' PotPlayer Auto Skip - hidden launcher
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ""__DIR__\pot-skip-daemon.ps1""", 0, False
'@
[IO.File]::WriteAllText($vbs, $vbsBody.Replace('__DIR__', $Dir), (New-Object System.Text.ASCIIEncoding))

# 4. autostart shortcut in the user's Startup folder
if (-not $NoAutostart) {
    $lnkPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\pot-skip.lnk'
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
    $s.TargetPath = 'wscript.exe'
    $s.Arguments = '"' + $vbs + '"'
    $s.WorkingDirectory = $Dir
    $s.WindowStyle = 7
    $s.Save()
    Write-Output ('autostart: ' + $lnkPath)
}

Write-Output ('installed: ' + $Dir)

# 5. launch now
if (-not $NoStart) {
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = 'wscript.exe "' + $vbs + '"' }
    Start-Sleep -Seconds 2
    $alive = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'pot-skip-daemon\.ps1' }
    if ($alive) { Write-Output ('daemon running, pid=' + (@($alive)[0].ProcessId)) }
    else { Write-Output ('daemon launch return=' + $r.ReturnValue + ' (check ' + (Join-Path $Dir 'log.txt') + ')') }
}
Write-Output 'Done. Play something in PotPlayer and tap Ctrl+Alt+1/2/3 to calibrate.'
