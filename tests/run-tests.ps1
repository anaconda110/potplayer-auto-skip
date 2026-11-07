# run-tests.ps1 - dependency-free tests for the parsing / matching logic.
# The daemon is dot-sourced in -TestLib mode: functions are defined, but no
# process, tray, hotkey or mutex work happens.
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$msg) {
    if ($cond) { $script:pass++ } else { $script:fail++; Write-Output ('FAIL: ' + $msg) }
}

. (Join-Path $repo 'src\pot-skip-daemon.ps1') -TestLib

# ---- time parsing ----
Assert ((Get-TimeSeconds '154.2') -eq 154.2) 'Get-TimeSeconds plain seconds'
Assert ((Get-TimeSeconds '2:34') -eq 154) 'Get-TimeSeconds mm:ss'
Assert ((Get-TimeSeconds '1:02:03') -eq 3723) 'Get-TimeSeconds hh:mm:ss'
Assert ((Get-TimeSeconds '') -eq 0) 'Get-TimeSeconds empty -> 0'

# ---- fixture ini + matching ----
$tmp = Join-Path $env:TEMP ('potskip-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$fixture = Join-Path $tmp 'skip.ini'
$body = @'
[global]
enabled = 1
apply_from = 2

[paths]
root = D:\Anime

[Show A]
op_start = 40
op_end = 150
ed_start = 1300
ed_end = 1400

[Show A\03]
op_end = 180

[Show B]
ed_start = 21:30
'@
[IO.File]::WriteAllText($fixture, $body, (New-Object System.Text.UTF8Encoding($true)))
$script:IniPath = $fixture
Get-Rules

Assert ($script:GlobalEnabled -eq $true) 'global.enabled parsed'
Assert ($script:IniRoot -eq 'D:\Anime') 'paths.root parsed'
Assert ($script:Rules.Count -eq 2) 'two series sections parsed'
Assert ($script:EpRules.Count -eq 1) 'one episode override parsed'

$r = Match-Rules 'D:\Anime\Show A\Season 1\01.mkv'
Assert ($null -ne $r) 'series matched by path'
Assert ($r.op_start -eq 40 -and $r.op_end -eq 150) 'series op_start/op_end'
Assert ($r.ed_start -eq 1300 -and $r.ed_end -eq 1400) 'series ed_start/ed_end'

$r = Match-Rules 'D:\Anime\Show A\[sub][Show A][03][1080p].mkv'
Assert ($null -ne $r -and $r.op_end -eq 180) 'episode override applies op_end'
Assert ($r.op_start -eq 40) 'episode override keeps series op_start'

$r = Match-Rules 'D:\Anime\Show B\03.mkv'
Assert ($r.op_end -eq 0 -and $r.ed_start -eq 1290) 'ed-only series; mm:ss parsed'

$r = Match-Rules 'D:\Other\SHOW A\x.mkv'
Assert ($null -ne $r -and $r.op_end -eq 150) 'matching is case-insensitive'

$r = Match-Rules 'D:\Nowhere\x.mkv'
Assert ($null -eq $r) 'unknown file -> no rule'

# ---- Save-IniValue ----
Save-IniValue $fixture 'Show A' 'op_end' '160'
$ini2 = Read-IniFile $fixture
Assert ((Get-TimeSeconds $ini2['Show A']['op_end']) -eq 160) 'Save-IniValue updates existing key'
Assert ($ini2.ContainsKey('Show A\03')) 'Save-IniValue preserves other sections'
Assert ((Get-TimeSeconds $ini2['Show A\03']['op_end']) -eq 180) 'other sections intact'
Assert ($ini2['global']['apply_from'] -eq '2') 'global section intact'
Save-IniValue $fixture 'Show C' 'op_end' '100'
$ini3 = Read-IniFile $fixture
Assert ((Get-TimeSeconds $ini3['Show C']['op_end']) -eq 100) 'Save-IniValue appends new section'

# ---- hotkey spec parsing ----
$hk = ConvertTo-Hotkey 'Ctrl+Alt+O'
Assert ($null -ne $hk -and $hk.vk -eq 0x4F -and $hk.mods -band 0x2 -and $hk.mods -band 0x1) 'Ctrl+Alt+O -> vk O with Ctrl+Alt'
Assert (-not ($hk.mods -band 0x4)) 'no Shift in Ctrl+Alt+O'
$hk = ConvertTo-Hotkey 'Ctrl+Alt+Shift+E'
Assert ($hk.vk -eq 0x45 -and ($hk.mods -band 0x4) -ne 0) 'Shift adds MOD_SHIFT'
$hk = ConvertTo-Hotkey 'Ctrl+Alt+F5'
Assert ($hk.vk -eq 0x74) 'F5 -> VK_F5'
$hk = ConvertTo-Hotkey 'Alt+7'
Assert ($hk.vk -eq 0x37) 'digit 7 -> VK_7'
Assert ($null -eq (ConvertTo-Hotkey '')) 'empty spec rejected'
Assert ($null -eq (ConvertTo-Hotkey 'Ctrl+Foo')) 'unknown key rejected'
$specs = Get-HotkeySpecs @{}
Assert ($specs.Count -eq 4 -and $specs[0].spec -eq 'Ctrl+Alt+O' -and $specs[3].action -eq 'toggle') 'default hotkey specs'
$specs2 = Get-HotkeySpecs @{ hotkeys = @{ ed_start = 'Ctrl+Alt+9' } }
Assert ($specs2[1].vk -eq 0x39) '[hotkeys] overrides a single action'
Assert ($specs2[0].spec -eq 'Ctrl+Alt+O') 'other actions keep defaults'

Remove-Item $tmp -Recurse -Force
Write-Output ('{0} passed, {1} failed' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
