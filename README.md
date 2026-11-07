# PotPlayer Auto Skip (potplayer-auto-skip)

按剧自动跳过 PotPlayer 的片头（OP）和片尾（ED credit），可以保留冷开剧情和片尾彩蛋（预告/end card）。零依赖——只用 Windows 自带的 PowerShell，不需要任何插件。托盘常驻，全局热键现场校准，不用手输时间。

[English](README.en.md)

## 为什么

PotPlayer 自带的「跳略播放」只能按全局固定秒数跳，每换一部剧就要重新填数字，而且它从 0:00 起跳——片头前有冷开剧情的番会被一起砍掉。本项目通过 PotPlayer 官方 SDK 消息接口做**按剧记忆**的精确跳过：

- **一部剧只配两个时间**：片头时间（`op_end`）+ 片尾时间（`ed_start`），热键现场记录，不用手输
- 进阶可选项：保留冷开（只跳 OP）、保留片尾预告/彩蛋、单集覆盖
- 手动拖进度条、断点续播**不会误触**；续播位置已在片头之后也不会往回跳

## 环境要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带，无需安装任何东西）
- PotPlayer（64/32 位均可）

## 安装

```powershell
git clone https://github.com/anaconda110/potplayer-auto-skip.git
cd potplayer-auto-skip\src
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

默认安装到 `%LOCALAPPDATA%\PotSkip` 并写入开机自启（启动文件夹快捷方式）。可选参数：

```powershell
.\install.ps1 -Dir "D:\Tools\PotSkip"   # 自定义安装目录
.\install.ps1 -NoAutostart              # 不自启
.\install.ps1 -NoStart                  # 只安装不立即启动
```

不想用 git 也可以直接 Download ZIP 解压后运行 `src\install.ps1`。

卸载：`powershell -File .\uninstall.ps1`（加 `-DeleteFiles` 连文件一起删）。

## 使用

一部剧只需要**两个时间**：片头时间、片尾时间。

**第一次看新番第 1 集**（默认第 1 集不自动跳，留给你校准）：

| 时刻 | 按键 | 写入 |
|---|---|---|
| OP 刚结束 | `Ctrl+Alt+I` | `op_end`（片头时间）——**I** = Intro，片头到此为止 |
| ED 刚开始 | `Ctrl+Alt+O` | `ed_start`（片尾时间）——**O** = Outro，片尾从这开始 |

热键是全局的，播放器在后台也有效；按键后托盘气泡确认，数值自动写入 `skip.ini` 对应剧集段，**全程不用手输数字**。从第 2 集起自动生效：打开/换集直接落在正片，播到片尾就跳过进下一集。

- `Ctrl+Alt+S`：暂停/恢复自动跳过（S = Skip）
- 托盘图标右键：暂停/恢复、退出
- 配置改动即时生效，无需重启

## 配置参考（skip.ini）

一部剧最少只要两行：

```ini
[My Show]
op_end = 2:15      ; 片头时间：打开/换集直接跳到这里（正片开始点）
ed_start = 22:10   ; 片尾时间：播到这里就跳过片尾，进下一集
```

时间支持秒（`214.0`）或 `分:秒`（`3:34`）、`时:分:秒`。改完保存即时生效。

### 高级选项（全部可选，默认不用管）

- **保留冷开**（只跳 OP、片头前的剧情照常看）：加 `op_start`，冷开正常播、播到它才跳到 `op_end`
  ```ini
  op_start = 0:45
  ```
- **保留片尾彩蛋**（ED 后的预告/end card）：加 `ed_end`，越过 `ed_start` 后跳到它而不是集尾；热键 `Ctrl+Alt+Shift+O` 记录
  ```ini
  ed_end = 23:20
  ```
- **单集覆盖**：`[My Show\12]` 覆盖文件名含 `12` 的那一集（比如最终话 ED 特别长）
- **从第 N 集才启用**：`apply_from`（默认 `2`，第 1 集留给你校准；改 `1` = 第 1 集也跳）
- **热键记录新剧时的剧名来源**：`paths.root`（取它下面第一级文件夹；留空用文件所在文件夹）
- **自定义快捷键**：与其他程序冲突时，在 `[hotkeys]` 段改（改完重启守护）：
  ```ini
  [hotkeys]
  op_end = Ctrl+Alt+I
  ed_start = Ctrl+Alt+O
  ed_end = Ctrl+Alt+Shift+O
  toggle = Ctrl+Alt+S
  ```
  支持 Ctrl/Alt/Shift/Win 组合 字母/数字/F1-F24。注册失败（被别的程序占用）会写进日志。

## 工作原理

守护进程以 400ms 轮询 PotPlayer 的官方 SDK 窗口消息（[SDK 头文件](https://github.com/ld3l/PotPlayerControl/blob/main/InternalSimpleCmd.h)）：

| 消息 | 用途 |
|---|---|
| `POT_GET_TOTAL_TIME` (0x5002) | 总时长（判断媒体已加载） |
| `POT_GET_CURRENT_TIME` (0x5004) | 当前播放位置 |
| `POT_SET_CURRENT_TIME` (0x5005) | 跳转 |
| `POT_GET_PLAYFILE_NAME` (0x6020) | 当前文件的完整路径（用于按剧匹配） |

跳过只在**自然播放越过**边界时触发（相邻两次采样都在前进且步长正常），所以拖进度条、断点续播不会误触。seek 最终落在目标点之前的关键帧上（播放器固有行为，片源关键帧越密越准）。

## 测试

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

覆盖时间解析、INI 读写、按剧匹配、单集覆盖合并、大小写容忍等逻辑（守护脚本以 `-TestLib` 模式被加载，不启动进程/托盘）。

## 常见问题

- **和 PotPlayer 自带的「跳略播放」冲突** → 请在 PotPlayer 里关闭跳略播放，否则会跳两次。
- **怎么确认它在工作** → 托盘有盾牌图标；`log.txt` 记录每次跳过和校准；加 `-Heartbeat` 参数启动可输出轮询诊断。
- **想暂时不跳** → `Ctrl+Alt+0`，或直接编辑 `skip.ini` 把 `enabled` 改 0。
- **跳过头/没跳干净** → 在正确位置重新按热键覆盖即可，立刻生效。

## License

[MIT](LICENSE)
