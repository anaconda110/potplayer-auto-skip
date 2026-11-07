# pot-skip-daemon.ps1 — PotPlayer Auto Skip daemon
# https://github.com/anaconda110/potplayer-auto-skip
#
# Per-series automatic intro/outro skipping for PotPlayer via the official
# SDK window messages (WM_USER 0x5002/0x5004/0x5005/0x6020), polled at 400ms.
#
# Skip modes (see config/skip.example.ini):
#   op_end only            -> on episode open, jump to op_end (cold open + OP)
#   op_start + op_end      -> cold open plays; once playback naturally crosses
#                             op_start, jump to op_end (skips only the OP)
#   ed_start (+ ed_end)    -> once playback naturally crosses ed_start, jump to
#                             ed_end (empty = near file end / next episode)
# Manual seeks and resume-from-middle never trigger a skip.
#
# Global hotkeys (player does not need focus; configurable in [hotkeys]):
#   Ctrl+Alt+O          capture current time as op_end   (O = OP ends here)
#   Ctrl+Alt+E          capture current time as ed_start (E = ED starts here)
#   Ctrl+Alt+Shift+E    capture current time as ed_end   (other end of the ED)
#   Ctrl+Alt+S          pause/resume skipping            (S = Skip)
# Tray icon: pause/resume, quit. Config: skip.ini next to this file (hot reload;
# hotkey changes need a restart).

param(
    [string]$Ini,
    [switch]$NoBalloon,
    [switch]$WriteHwndFile,
    [switch]$Heartbeat,
    [switch]$TestLib
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Dir = $PSScriptRoot
if (-not $Ini) { $Ini = Join-Path $Dir 'skip.ini' }
$script:IniPath = $Ini
$script:LogFile = Join-Path $Dir 'log.txt'

# ---------- C# 辅助（PotPlayer SDK 消息 + 消息窗口） ----------
if (-not ('PotApi' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using System.Text;

public class PotApi {
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
    [DllImport("user32.dll")]
    public static extern bool PostMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    public const uint SMTO_ABORTIFHUNG = 0x0002;

    // POT_GET_xxx：返回值即数据（ms / 状态）
    public static long Query(IntPtr pot, uint id) {
        IntPtr res;
        if (SendMessageTimeoutW(pot, 0x400, (IntPtr)(long)id, IntPtr.Zero, SMTO_ABORTIFHUNG, 1500, out res) == IntPtr.Zero) return -1;
        return res.ToInt64();
    }
    // POT_SET_CURRENT_TIME 0x5005
    public static bool Seek(IntPtr pot, long ms) {
        IntPtr res;
        return SendMessageTimeoutW(pot, 0x400, (IntPtr)0x5005, (IntPtr)ms, SMTO_ABORTIFHUNG, 1500, out res) != IntPtr.Zero;
    }
}

public class SkipForm : Form {
    public const uint WM_COPYDATA = 0x004A;
    public const uint WM_HOTKEY = 0x0312;
    public struct COPYDATASTRUCT { public IntPtr dwData; public int cbData; public IntPtr lpData; }
    [DllImport("user32.dll")]
    static extern IntPtr SendMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public event Action<int> Hotkey;
    public string FileNameReply;
    public uint ReplyTag;

    public SkipForm() {
        ShowInTaskbar = false;
        FormBorderStyle = FormBorderStyle.None;
    }
    // message-only 窗口（不可见、不闪窗）
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.Parent = (IntPtr)(-3); return cp; }
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == (int)WM_COPYDATA) {
            COPYDATASTRUCT cds = (COPYDATASTRUCT)Marshal.PtrToStructure(m.LParam, typeof(COPYDATASTRUCT));
            if (cds.cbData > 0 && cds.lpData != IntPtr.Zero) {
                byte[] buf = new byte[cds.cbData];
                Marshal.Copy(cds.lpData, buf, 0, cds.cbData);
                FileNameReply = Encoding.UTF8.GetString(buf);
                ReplyTag = (uint)cds.dwData.ToInt64();
            }
            m.Result = (IntPtr)1;
            return;
        }
        if (m.Msg == (int)WM_HOTKEY) {
            if (Hotkey != null) Hotkey((int)m.WParam);
            m.Result = (IntPtr)0;
            return;
        }
        base.WndProc(ref m);
    }
    // POT_GET_PLAYFILE_NAME 0x6020：发请求，回复以 WM_COPYDATA 到本窗口（调用方需泵消息）
    public void RequestFileName(IntPtr pot) {
        FileNameReply = null;
        SendMessageW(pot, 0x400, (IntPtr)0x6020, this.Handle);
    }
}
'@
}

# ---------- 日志 ----------
function Write-Log([string]$msg) {
    try {
        if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 512KB)) {
            Remove-Item $script:LogFile -Force
        }
        Add-Content -Path $script:LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch {}
}

function Show-Balloon([string]$title, [string]$text) {
    if ($NoBalloon) { return }
    try { $script:Icon.ShowBalloonTip(1800, $title, $text, [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
}

# ---------- 时间格式 ----------
# "154.2" / "2:34" / "1:02:03.5" -> 秒
function Get-TimeSeconds([string]$v) {
    if ([string]::IsNullOrWhiteSpace($v)) { return 0 }
    $v = $v.Trim()
    if ($v -match ':') {
        $sec = 0.0
        foreach ($x in ($v -split ':')) { $sec = $sec * 60 + [double]$x }
        return $sec
    }
    return [double]$v
}

function Format-Sec([double]$s) {
    $neg = ''
    if ($s -lt 0) { $neg = '-'; $s = -$s }
    $m = [int][math]::Floor($s / 60)
    $r = $s - $m * 60
    return ('{0}{1}:{2:00.0}' -f $neg, $m, $r)
}

# ---------- INI 读写 ----------
function Read-IniFile([string]$path) {
    $ini = @{}
    if (-not (Test-Path $path)) { return $ini }
    $sec = ''
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        if ($t.StartsWith('[') -and $t.EndsWith(']')) {
            $sec = $t.Substring(1, $t.Length - 2).Trim()
            if (-not $ini.ContainsKey($sec)) { $ini[$sec] = @{} }
            continue
        }
        $i = $t.IndexOf('=')
        if ($i -gt 0 -and $sec -ne '') {
            $ini[$sec][$t.Substring(0, $i).Trim().ToLower()] = $t.Substring($i + 1).Trim()
        }
    }
    return $ini
}

# 原地更新某一节某键（保留注释），节不存在则追加
function Save-IniValue([string]$path, [string]$section, [string]$key, [string]$value) {
    $lines = @()
    if (Test-Path $path) { $lines = [IO.File]::ReadAllLines($path) } else { $lines = @('[global]') }
    $cur = ''
    $secStart = -1
    $keyLine = -1
    $pat = '^\s*' + [regex]::Escape($key) + '\s*='
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].Trim()
        if ($t.StartsWith('[') -and $t.EndsWith(']')) {
            if ($cur -ieq $section) { break }   # 目标节到此结束
            $cur = $t.Substring(1, $t.Length - 2).Trim()
            if ($cur -ieq $section) { $secStart = $i; $keyLine = -1 }
        } elseif ($secStart -ge 0 -and $t -imatch $pat) {
            $keyLine = $i
        }
    }
    if ($keyLine -ge 0) {
        $lines[$keyLine] = ('{0} = {1}' -f $key, $value)
    } elseif ($secStart -ge 0) {
        $out = $lines[0..$secStart]
        $out += ('{0} = {1}' -f $key, $value)
        $out += $lines[($secStart + 1)..($lines.Count - 1)]
        $lines = $out
    } else {
        $lines += ''
        $lines += ('[{0}]' -f $section)
        $lines += ('{0} = {1}' -f $key, $value)
    }
    [IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($true)))
}

# ---------- 规则 ----------
function Get-Rules {
    $ini = Read-IniFile $script:IniPath
    $script:GlobalEnabled = $true
    if ($ini['global'] -and $null -ne $ini['global']['enabled']) {
        $script:GlobalEnabled = ($ini['global']['enabled'] -eq '1')
    }
    $defApply = 2
    if ($ini['global'] -and $ini['global']['apply_from']) { $defApply = [int](Get-TimeSeconds $ini['global']['apply_from']) }
    $script:IniRoot = ''
    if ($ini['paths'] -and $ini['paths']['root']) { $script:IniRoot = $ini['paths']['root'].Trim().TrimEnd('\') }

    $rules = @()
    $eprules = @()
    foreach ($sec in $ini.Keys) {
        if ($sec -ieq 'global' -or $sec -ieq 'paths') { continue }
        $s = $ini[$sec]
        $op = Get-TimeSeconds $s['op_end']
        $os = Get-TimeSeconds $s['op_start']
        $es = Get-TimeSeconds $s['ed_start']
        $ee = Get-TimeSeconds $s['ed_end']
        $af = $defApply
        if ($s['apply_from']) { $af = [int](Get-TimeSeconds $s['apply_from']) }
        if ($sec.Contains('\')) {
            $parent = $sec.Split('\')[0]
            $ep = $sec.Substring($sec.IndexOf('\') + 1)
            $eprules += @{ section = $parent; ep = $ep; op_start = $os; op_end = $op; ed_start = $es; ed_end = $ee; apply_from = $af }
        } else {
            $rules += @{ section = $sec; op_start = $os; op_end = $op; ed_start = $es; ed_end = $ee; apply_from = $af }
        }
    }
    $script:Rules = $rules
    $script:EpRules = $eprules
}

function Match-Rules([string]$path) {
    $pl = $path.ToLower()
    $best = $null
    $bestLen = -1
    foreach ($r in $script:Rules) {
        $pat = ('\' + $r.section.TrimEnd('\') + '\').ToLower()
        if ($pl.Contains($pat) -and $r.section.Length -gt $bestLen) { $best = $r; $bestLen = $r.section.Length }
    }
    if ($best) {
        $fn = [IO.Path]::GetFileName($path).ToLower()
        $epBest = $null
        $ebl = -1
        foreach ($e in $script:EpRules) {
            if ($e.section.ToLower() -eq $best.section.ToLower() -and $fn.Contains($e.ep.ToLower()) -and $e.ep.Length -gt $ebl) {
                $epBest = $e; $ebl = $e.ep.Length
            }
        }
        if ($epBest) {
            $m = @{ section = $best.section; op_start = $best.op_start; op_end = $best.op_end; ed_start = $best.ed_start; ed_end = $best.ed_end; apply_from = $best.apply_from }
            foreach ($k in @('op_start', 'op_end', 'ed_start', 'ed_end')) { if ($epBest[$k] -gt 0) { $m[$k] = $epBest[$k] } }
            if ($epBest.apply_from -gt 0) { $m.apply_from = $epBest.apply_from }
            return $m
        }
    }
    return $best
}

# 已有配置里匹配当前路径的节名（没有则 $null）
function Match-SeriesSection([string]$path) {
    $r = Match-Rules $path
    if ($r) { return $r.section }
    return $null
}

# 从文件路径推断"剧名"（root 下第一级目录；否则上级目录）
function Get-SeriesName([string]$path) {
    $root = $script:IniRoot
    if ($root -and $path.ToLower().StartsWith($root.ToLower() + '\')) {
        $rest = $path.Substring($root.Length + 1)
        $comp = $rest.Split('\')[0]
        if ($comp) { return $comp }
    }
    $dir = [IO.Path]::GetDirectoryName($path)
    $leaf = Split-Path $dir -Leaf
    if ($leaf -ieq '01-99' -or -not $leaf) { return [IO.Path]::GetFileNameWithoutExtension($path) }
    return $leaf
}

function Get-EpisodeNo([string]$path) {
    $base = [IO.Path]::GetFileNameWithoutExtension($path)
    $m = [regex]::Match($base, '(?<!\d)(\d{1,3})(?!\d)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

# ---------- Hotkeys ----------
# Parse a "Ctrl+Alt+O" style spec into @{ mods; vk } (RegisterHotKey parameters).
# Returns $null when the spec is invalid. MOD_ALT=1 MOD_CONTROL=2 MOD_SHIFT=4
# MOD_WIN=8 MOD_NOREPEAT=0x4000.
function ConvertTo-Hotkey([string]$spec) {
    if ([string]::IsNullOrWhiteSpace($spec)) { return $null }
    $mods = 0x4000
    $vk = 0
    foreach ($p in ($spec.Trim().Split('+') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })) {
        switch ($p) {
            'ctrl' { $mods = $mods -bor 0x2 }
            'alt' { $mods = $mods -bor 0x1 }
            'shift' { $mods = $mods -bor 0x4 }
            'win' { $mods = $mods -bor 0x8 }
            default {
                if ($p -match '^[a-z]$') {
                    $vk = [int][char]($p.ToUpper()) - 65 + 0x41
                } elseif ($p -match '^[0-9]$') {
                    $vk = [int]$p + 0x30
                } elseif ($p -match '^f([1-9]|1[0-9]|2[0-4])$') {
                    $vk = 0x6F + [int]$Matches[1]
                } else {
                    return $null
                }
            }
        }
    }
    if ($vk -eq 0) { return $null }
    return @{ mods = $mods; vk = $vk; spec = $spec.Trim() }
}

# Resolve the four hotkeys from the [hotkeys] ini section, falling back to
# the mnemonic defaults. Returns a list of @{ id; action; spec; mods; vk }.
function Get-HotkeySpecs([hashtable]$ini) {
    $defaults = @{
        op_end = 'Ctrl+Alt+O'          # O = OP: mark where the OP ends
        ed_start = 'Ctrl+Alt+E'        # E = ED: mark where the ED starts
        ed_end = 'Ctrl+Alt+Shift+E'    # the other end of the ED
        toggle = 'Ctrl+Alt+S'          # S = Skip: pause/resume
    }
    $sec = @{}
    if ($ini -and $ini['hotkeys']) { $sec = $ini['hotkeys'] }
    $out = @()
    $id = 1
    foreach ($action in @('op_end', 'ed_start', 'ed_end', 'toggle')) {
        $spec = $defaults[$action]
        if ($sec[$action.ToLower()]) { $spec = $sec[$action.ToLower()] }
        $hk = ConvertTo-Hotkey $spec
        if (-not $hk) { $hk = ConvertTo-Hotkey $defaults[$action] }
        $out += @{ id = $id; action = $action; spec = $hk.spec; mods = $hk.mods; vk = $hk.vk }
        $id++
    }
    return $out
}

# ---------- 状态 ----------
$script:Pot = [IntPtr]::Zero
$script:St = $null
$script:LastPath = $null
$script:LastCurMs = -1L
$script:LastIniWrite = [datetime]::MinValue
$script:tickBusy = $false
Get-Rules

# Library-only mode for tests: functions are defined, no process/tray/hotkey work.
if ($TestLib) { return }

function Toggle-Enabled {
    $script:GlobalEnabled = -not $script:GlobalEnabled
    $v = '0'
    if ($script:GlobalEnabled) { $v = '1' }
    Save-IniValue $script:IniPath 'global' 'enabled' $v
    if ($script:GlobalEnabled) { $txt = '已启用（换集/片尾时自动跳）' } else { $txt = '已暂停（不自动跳，热键记录仍可用）' }
    $script:Icon.Text = ('PotPlayer 跳过守护 · {0}' -f $txt)
    Show-Balloon 'PotPlayer 跳过守护' $txt
    Write-Log ('toggle: enabled=' + $v)
}

# ---------- 单实例 ----------
# stable name across processes: string.GetHashCode() is randomized per process
# on .NET 4.5+, which would silently defeat the single-instance guard
$md5 = [System.Security.Cryptography.MD5]::Create()
$hashHex = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($IniPath.ToLower()))).Replace('-', '')
$script:MutexName = 'pot-skip-daemon-' + $hashHex.Substring(0, 12)
$script:Mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
if (-not $script:Mutex.WaitOne(0, $false)) {
    Write-Output ('already running for this ini: ' + $IniPath)
    exit 1
}

# ---------- UI：托盘 + 热键 ----------
$script:Icon = New-Object System.Windows.Forms.NotifyIcon
$script:Icon.Icon = [System.Drawing.SystemIcons]::Shield
$script:Icon.Text = 'PotPlayer 跳过守护'
$script:Icon.Visible = $true

$form = New-Object SkipForm
[void]$form.Handle

# resolve hotkeys once at startup ([hotkeys] section overrides the defaults;
# edits to hotkeys require a daemon restart)
$script:Hotkeys = Get-HotkeySpecs (Read-IniFile $script:IniPath)
$script:HotkeyByAction = @{}
foreach ($hk in $script:Hotkeys) { $script:HotkeyByAction[$hk.action] = $hk }
$toggleSpec = $script:HotkeyByAction['toggle'].spec

$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add(('暂停/恢复自动跳过 ({0})' -f $toggleSpec), $null, { param($s, $e) Toggle-Enabled })
$menu.Items.Add('-') | Out-Null
[void]$menu.Items.Add('退出', $null, { param($s, $e) [System.Windows.Forms.Application]::Exit() })
$script:Icon.ContextMenuStrip = $menu

foreach ($hk in $script:Hotkeys) {
    if (-not [SkipForm]::RegisterHotKey($form.Handle, $hk.id, $hk.mods, $hk.vk)) {
        Write-Log ('hotkey-register-failed: {0} ({1}) - key may be taken by another app, change [hotkeys] in skip.ini' -f $hk.spec, $hk.action)
    }
}

if ($WriteHwndFile) {
    $hf = Join-Path (Split-Path -Parent $script:IniPath) 'hwnd.txt'
    [IO.File]::WriteAllText($hf, ('hwnd=0x{0:X}' -f $form.Handle.ToInt64()))
}

$form.add_Hotkey({
    param($id)
    try {
        $hk = $script:Hotkeys | Where-Object { $_.id -eq [int]$id } | Select-Object -First 1
        if (-not $hk) { return }
        if ($hk.action -eq 'toggle') { Toggle-Enabled; return }
        $path = $script:LastPath
        $cur = $script:LastCurMs
        if (-not $path -or $cur -lt 0) {
            Show-Balloon 'PotPlayer 跳过守护' '未检测到正在播放的文件'
            return
        }
        $sec = Match-SeriesSection $path
        if (-not $sec) { $sec = Get-SeriesName $path }
        $val = [math]::Round($cur / 100.0) / 10.0
        $key = $hk.action
        Save-IniValue $script:IniPath $sec $key ('{0:0.0}' -f $val)
        Get-Rules
        Show-Balloon '已记录' ('[{0}] {1} = {2}' -f $sec, $key, (Format-Sec $val))
        Write-Log ('capture: [{0}] {1} = {2}s  <- {3}' -f $sec, $key, $val, [IO.Path]::GetFileName($path))
    } catch { Write-Log ('hotkey-error: ' + $_.Exception.Message) }
})

# ---------- 轮询 ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400

$timer.add_Tick({
    if ($Heartbeat) { Write-Log 'tick-enter' }
    if ($script:tickBusy) { return }
    $script:tickBusy = $true
    try {
        if ($Heartbeat) { Write-Log ('hb0: Pot={0} ini={1} busy={2}' -f $script:Pot, $script:IniPath, $script:tickBusy) }
        # 找 PotPlayer
        if ($script:Pot -eq [IntPtr]::Zero) {
            $p = Get-Process -Name 'PotPlayerMini64', 'PotPlayerMini', 'PotPlayer' -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
            if ($Heartbeat) { Write-Log ('hb-find: ' + $(if ($p) { 'pid=' + $p.Id + ' hwnd=' + $p.MainWindowHandle } else { 'NULL' })) }
            if ($p) { $script:Pot = $p.MainWindowHandle } else { return }
        }

        # ini 外部修改 → 重载
        $iniWT = $null
        if (Test-Path $script:IniPath) { $iniWT = (Get-Item $script:IniPath).LastWriteTimeUtc }
        if ($iniWT -ne $script:LastIniWrite) {
            $script:LastIniWrite = $iniWT
            $wasEnabled = $script:GlobalEnabled
            Get-Rules
            if ($wasEnabled -ne $script:GlobalEnabled) {
                $txt = '已暂停'
                if ($script:GlobalEnabled) { $txt = '已启用' }
                $script:Icon.Text = ('PotPlayer 跳过守护 · {0}' -f $txt)
            }
        }

        # 查询进度
        $total = [PotApi]::Query($script:Pot, 0x5002)
        if ($Heartbeat) { Write-Log ('hb: pot=0x{0:X} total={1}' -f $script:Pot.ToInt64(), $total) }
        if ($total -lt 0) { $script:Pot = [IntPtr]::Zero; return }   # 窗口失效，下轮重找
        if ($total -le 0) { return }                                  # 未加载媒体
        $cur = [PotApi]::Query($script:Pot, 0x5004)
        if ($cur -lt 0) { return }
        $script:LastCurMs = $cur

        # 当前文件路径
        $form.RequestFileName($script:Pot)
        $deadline = [datetime]::Now.AddMilliseconds(500)
        while ($null -eq $form.FileNameReply -and [datetime]::Now -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 20
        }
        $fname = $form.FileNameReply
        if ($fname) { $script:LastPath = $fname }
        if ($Heartbeat) { Write-Log ('hb2: cur={0} fname={1}' -f $cur, $fname) }
        if (-not $fname) { return }

        if (-not $script:St -or $script:St.path -cne $fname) {
            $script:St = @{ path = $fname; opPending = $true; lastOpTry = [datetime]::MinValue; openedAt = [datetime]::Now; edDone = $false; opStartDone = $false; prevCur = -1L }
            Write-Log ('now-playing: ' + $fname)
        }

        if (-not $script:GlobalEnabled) { $script:St.prevCur = $cur; return }

        $rule = Match-Rules $fname
        if (-not $rule) { $script:St.prevCur = $cur; return }

        $ep = Get-EpisodeNo $fname
        if ($rule.apply_from -gt 1 -and ($ep -eq 0 -or $ep -lt $rule.apply_from)) { $script:St.prevCur = $cur; return }

        # --- 片头 A：无 op_start 时，换集后若还没播到 op_end，跳过去（含冷开+OP） ---
        if ($rule.op_start -le 0 -and $rule.op_end -gt 0 -and $script:St.opPending) {
            $opMs = [long]($rule.op_end * 1000)
            $now = [datetime]::Now
            if ($cur -gt ($opMs + 2000)) {
                $script:St.opPending = $false   # 续播位置已在片头之后，不跳
            } elseif ($cur -ge ($opMs - 1200)) {
                $script:St.opPending = $false   # 已就位
            } elseif (($now - $script:St.lastOpTry).TotalMilliseconds -gt 1200) {
                $script:St.lastOpTry = $now
                if ([PotApi]::Seek($script:Pot, $opMs)) {
                    Write-Log ('skip-op: -> {0} ({1})' -f (Format-Sec $rule.op_end), [IO.Path]::GetFileName($fname))
                }
            }
            if (($now - $script:St.openedAt).TotalSeconds -gt 20) { $script:St.opPending = $false }
            $cur = [PotApi]::Query($script:Pot, 0x5004)
            if ($cur -lt 0) { $cur = $opMs }
        }

        # --- 片头 B：有 op_start 时，冷开正常播，自然播放越过 op_start 才跳到 op_end（只跳 OP，保留冷开） ---
        if ($rule.op_start -gt 0 -and $rule.op_end -gt $rule.op_start -and -not $script:St.opStartDone) {
            $oss = [long]($rule.op_start * 1000)
            if ($script:St.prevCur -ge 0 -and $script:St.prevCur -lt $oss -and $cur -ge $oss -and ($cur - $script:St.prevCur) -lt 3000) {
                $script:St.opStartDone = $true
                $target = [long]($rule.op_end * 1000)
                if ($cur -lt ($target - 800)) {
                    if ([PotApi]::Seek($script:Pot, $target)) {
                        Write-Log ('skip-op: {0} -> {1} ({2})' -f (Format-Sec $rule.op_start), (Format-Sec $rule.op_end), [IO.Path]::GetFileName($fname))
                    }
                }
                $cur = $target
            }
        }

        # --- 片尾：自然播放越过 ed_start 才触发（手动拖动/续播不误触） ---
        if ($rule.ed_start -gt 0 -and -not $script:St.edDone) {
            $eds = [long]($rule.ed_start * 1000)
            if ($script:St.prevCur -ge 0 -and $script:St.prevCur -lt $eds -and $cur -ge $eds -and ($cur - $script:St.prevCur) -lt 3000) {
                $script:St.edDone = $true
                if ($rule.ed_end -gt $rule.ed_start) {
                    $target = [long][math]::Min($rule.ed_end * 1000, $total - 600)
                } else {
                    $target = [long]($total - 1000)
                }
                if ($cur -lt ($target - 500)) {
                    if ([PotApi]::Seek($script:Pot, $target)) {
                        Write-Log ('skip-ed: -> {0} ({1})' -f (Format-Sec ($target / 1000)), [IO.Path]::GetFileName($fname))
                    }
                }
                $cur = $target
            }
        }

        $script:St.prevCur = $cur
    } catch {
        Write-Log ('tick-error: ' + $_.Exception.Message)
    } finally {
        $script:tickBusy = $false
    }
})

$timer.Start()
Write-Log ('daemon-start: ini=' + $script:IniPath)
if ($script:GlobalEnabled) { $tip = '已启用' } else { $tip = '已暂停' }
$script:Icon.Text = ('PotPlayer 跳过守护 · {0}' -f $tip)
Show-Balloon 'PotPlayer 跳过守护' ('已启动（{0}）。校准热键：{1} 片头 / {2} 片尾。' -f $tip, $script:HotkeyByAction['op_end'].spec, $script:HotkeyByAction['ed_start'].spec)

# 无主窗体消息泵（message-only 窗体不能作 Run(form) 的主窗体，会立即返回）
Write-Log 'pre-run'
$script:Ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($script:Ctx)

# ---------- 清理 ----------
foreach ($hk in $hotkeys) { [void][SkipForm]::UnregisterHotKey($form.Handle, $hk.id) }
$script:Icon.Visible = $false
$script:Icon.Dispose()
$script:Mutex.ReleaseMutex()
$script:Mutex.Dispose()
Write-Log 'daemon-stop'
