# PotPlayer Auto Skip (potplayer-auto-skip)

按剧自动跳过 PotPlayer 的片头（OP）和片尾（ED credit），可以保留冷开剧情和片尾彩蛋（预告/end card）。零依赖——只用 Windows 自带的 PowerShell，不需要任何插件。托盘常驻，全局热键现场校准，不用手输时间。

[English](README.en.md)

## 为什么

PotPlayer 自带的「跳略播放」只能按全局固定秒数跳，每换一部剧就要重新填数字，而且它从 0:00 起跳——片头前有冷开剧情的番会被一起砍掉。本项目通过 PotPlayer 官方 SDK 消息接口做**按剧记忆**的精确跳过：

- **片头两种模式**
  - 只配 `op_end`：打开/换集时还没播到它就直接跳（冷开+OP 一起跳）
  - 配 `op_start` + `op_end`：**冷开正常播**，自然播到 `op_start` 才跳到 `op_end`（只跳 OP 正曲）
- **片尾**：自然播放越过 `ed_start` 就跳到 `ed_end`。`ed_end` 填在预告开头 = 保留预告/彩蛋；留空 = 直接进下一集
- 每集冷开/OP 长度不同？支持 `[剧名\05]` 单集覆盖
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

**第一次看新番第 1 集**（默认第 1 集不自动跳，留给你校准）：

| 时刻 | 按键 | 写入 |
|---|---|---|
| OP 刚结束 | `Ctrl+Alt+1` | `op_end`（片头结束点） |
| ED 刚开始 | `Ctrl+Alt+2` | `ed_start`（片尾开始点） |
| ED 刚结束（想保留 ED 后的预告/彩蛋才按） | `Ctrl+Alt+3` | `ed_end`（片尾结束点） |

热键是全局的，播放器在后台也有效；按键后托盘气泡确认，数值自动写入 `skip.ini` 对应剧集段，**全程不用手输数字**。从第 2 集起自动生效；觉得不准随时再按一次覆盖。

- `Ctrl+Alt+0`：暂停/恢复自动跳过
- 托盘图标右键：暂停/恢复、退出
- 配置改动即时生效，无需重启

## 配置参考（skip.ini）

```ini
[global]
enabled = 1          ; 总开关（Ctrl+Alt+0 会写回这里）
apply_from = 2       ; 从第几集开始自动跳；1 = 第 1 集也跳

[paths]
root =               ; 媒体库根目录；热键记录新剧时用它下面第一级文件夹当剧名。
                     ; 留空则用文件所在文件夹名

; 段名 = 剧集文件夹名（按完整路径里的 \段名\ 匹配）
[My Show]
op_start = 0:45      ; 可选。和 op_end 成对：冷开正常播，播到这跳到 op_end（只跳 OP）
op_end = 2:15        ; 片头结束点
ed_start = 22:10     ; 片尾开始点
ed_end = 23:20       ; 跳到的位置；不填 = 跳到本集末尾进下一集

; 单集覆盖：文件名含 12 的那集（比如最终话 ED 特别长）
[My Show\12]
ed_start = 21:40
```

时间支持秒（`214.0`）或 `分:秒`（`3:34`）、`时:分:秒`。改完保存即时生效。

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
