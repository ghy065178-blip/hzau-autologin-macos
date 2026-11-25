# HZAU Campus Network Auto Login —— macOS 版

华中农业大学校园网（深澜 Srun）自动认证工具的 **macOS 等价实现**。

> 目标：在**不改变原有功能、配置方式、交互逻辑和自动化行为**的前提下，让这份只适配
> Windows 的发行版能在 macOS（Intel / Apple Silicon）上稳定运行，并与 Windows 版保持
> 功能一致。
>
> 实现策略：**上游 `srun_login.py` 一行不改**。macOS 版以模块方式导入它，复用全部协议、
> 配置、日志、重试与错误处理代码，只在运行时替换依赖 Windows 的平台符号。
> 因此任何对上游协议脚本的升级都会被 macOS 版自动继承，不存在两份协议实现漂移的风险。

---

## 一、Windows 版现状分析

### 1.1 仓库结构（v1.1.2）

| 文件 | 作用 |
|---|---|
| `srun_login.py` (600 行) | 主程序，**纯 Python 标准库**；含 PyInstaller frozen 路径适配 |
| `build.ps1` | 用 PyInstaller 产出 `hzau-autologin.exe` 与 `*-win64.zip` |
| `installer/install.bat` / `install.ps1` | 双击安装：UAC 提权、复制 exe、写配置与 DPAPI 密码、注册计划任务、试跑 |
| `installer/uninstall.bat` | 卸载入口 |
| `installer/change_password.*` | 只重设密码，不重装 |
| `installer/diagnose.*` | 一键诊断，输出报告 txt |
| `.github/workflows/release.yml` | 推送 `v*` tag 后在 `windows-latest` 自动出包 |
| `config.example.json` / `README.md` / `TUTORIAL.md` / `docs/PACKAGING.md` | 配置样例与文档 |

### 1.2 依赖

- 运行时：**零第三方依赖**，`base64 / ctypes / hashlib / hmac / http.client / json / os / re / socket / ssl / subprocess / sys / time / urllib` 全部标准库。
- 构建期：Python 3.12 + PyInstaller（`--noconsole --onefile --noupx --exclude-module tkinter`）。
- 系统接口：Windows DPAPI (`crypt32`)、`user32.MessageBoxW`、`shell32.IsUserAnAdmin`、Task Scheduler、`ipconfig`、UAC、PowerShell 5.1。

### 1.3 登录流程（原版，未改动）

```
main()
 ├─ 读 config.json（BASE_DIR 取 sys.executable 目录，frozen 时）
 ├─ 读 password.bin（base64 DPAPI 密文 → CryptUnprotectData）
 ├─ wait_for_network()     最长 300s；先给 DHCP 45s；每 60s 做一次修复
 │    ├─ UDP connect 向认证服务器选路取本机 IP（避开 VPN 虚拟网卡 26.x）
 │    ├─ 169.254.x.x 视为无 IP
 │    └─ 门户不可达 → ipconfig /flushdns → 自动切换可连通网卡
 ├─ check_online()         /cgi-bin/rad_user_info?callback=_
 ├─ get_portal_ip()        /srun_portal_pc?ac_id=5&theme=pro 里正则取 CONFIG.ip
 ├─ get_challenge()        /cgi-bin/get_challenge?... → token / client_ip
 ├─ calc_login_params()    HMAC-MD5 + xEncode(SBXTEA) + 自定义 base64 + SHA1
 ├─ do_login()             /cgi-bin/srun_portal?action=login&...
 ├─ 重试 max_attempts=3，间隔 3s；E2531 换 IP、E2620 复核在线、凭证错误立即停
 └─ online_status()        认证后二次核对，写中文提示到 srun_login.log
```

### 1.4 配置与自动化

- `config.json` 8 个键：`server / ac_id / username / domain / max_attempts / retry_interval / network_wait_seconds / repair_interval_seconds`。
- 安装目录 `%LOCALAPPDATA%\HZAU-AutoLogin\`，含 exe、`config.json`、`password.bin`、`srun_login.log`。
- 两个计划任务：`HZAU-AutoLogin`（AtLogOn、RunLevel Highest）、`HZAU-AutoLogin-Reconnect`（Once +2min 起、每 30 分钟、持续 3650 天）；共同设置为 `Hidden / MultipleInstances IgnoreNew / StartWhenAvailable / ExecutionTimeLimit 20min`。

### 1.5 必须处理的 Windows 专属点（逐项已定位）

| # | 位置 | Windows 专属实现 | 在 macOS 上的后果 |
|---|---|---|---|
| 1 | `srun_login.py:66` | `ctypes.windll.user32.MessageBoxW` | `ctypes.windll` 不存在 → AttributeError |
| 2 | `srun_login.py:252-271` | `DATA_BLOB` + `crypt32.CryptUnprotectData` + `kernel32.LocalFree` | DPAPI 不可用，密码读不出 |
| 3 | `srun_login.py:317-321` | `shell32.IsUserAnAdmin()` | 恒为 False |
| 4 | `srun_login.py:324-332` | `subprocess.run(..., creationflags=CREATE_NO_WINDOW)` | `ValueError: creationflags is only supported on Windows platforms` |
| 5 | `srun_login.py:345-350, 387` | `ipconfig /flushdns \| /release \| /renew` | 命令不存在 |
| 6 | `srun_login.py:85-96` | `gethostname()/getaddrinfo` 枚举网卡 | macOS 常解析为 `.local`，漏掉物理网卡 IP |
| 7 | `srun_login.py:35, 569-590` | `%LOCALAPPDATA%`、`\` 路径、`.bat` 提示文案 | 路径/文案错误 |
| 8 | `install.ps1` | ScheduledTasks cmdlet、DPAPI `ProtectedData::Protect`、UAC `-Verb RunAs` | 全部不可用 |
| 9 | `build.ps1` / `release.yml` | `--noconsole` → GUI 子系统 `.exe`；`windows-latest` | macOS 上 `--noconsole` 会生成 `.app`，不适合 launchd |
| 10 | `*.bat` / `*.ps1` | 批处理 + PowerShell 5.1（要求 UTF-8 BOM） | macOS 无 PowerShell |

> **附带发现（上游缺陷，未修改）**：三份 `.ps1` 里的交互输入调用的是 `Read-Host`
> （共 10 处），PowerShell 并没有这个 cmdlet，正常应为 `Read-Host`。为遵守「不改变原有」
> 的约束，本次**没有改动任何 Windows 文件**；macOS 版按设计意图实现了等价的交互提问。

---

## 二、差异映射总表

| 维度 | Windows 版 | macOS 版 | 实现文件 |
|---|---|---|---|
| 协议/流程 | `srun_login.py` | **同一份 `srun_login.py`，零改动** | 上游文件 |
| 入口 | `hzau-autologin.exe` | `hzau_autologin_macos.py`（导入上游模块后覆盖平台符号） | `macos/hzau_autologin_macos.py` |
| 安装目录 | `%LOCALAPPDATA%\HZAU-AutoLogin\` | `~/Library/Application Support/HZAU-AutoLogin/` | `install.sh` |
| 配置文件 | `config.json`（8 键） | **完全相同的 8 键、顺序、默认值、UTF-8 无 BOM** | `install.sh:write_config` |
| 密码存储 | DPAPI CurrentUser → `password.bin` 密文 | 登录钥匙串（service `HZAU-AutoLogin`）+ `password.bin` 句柄 | `keychain.sh`、`hzau_autologin_macos.py:mac_load_password` |
| 密码绑定 | 本机 + 当前 Windows 用户 | 本机 + 当前 macOS 用户（登录钥匙串） | 同上 |
| 弹窗 | `user32.MessageBoxW` | `osascript display dialog ... giving up after 20` | `mac_alert` |
| 提权 | UAC（一次）→ 计划任务 RunLevel Highest | `osascript ... with administrator privileges`（一次）→ root 助手 + sudoers 规则 | `install_privileged_helper.sh` |
| 权限判定 | `IsUserAnAdmin()` | `geteuid()==0` 或「特权助手已授权且可用」 | `mac_is_elevated` |
| DNS 刷新 | `ipconfig /flushdns` | `dscacheutil -flushcache` + `killall -HUP mDNSResponder` | `mac_run_cmd` / helper |
| DHCP 续租 | `ipconfig /release` + `/renew` | `ipconfig set <iface> NONE` + `ipconfig set <iface> DHCP`（root 助手） | helper `release` / `renew` |
| 子进程 | `creationflags=CREATE_NO_WINDOW` | 普通 `subprocess.run`（POSIX 无窗口概念） | `mac_run_cmd:_native` |
| 网卡枚举 | `gethostname()` | `/sbin/ifconfig -a` 正则取 `inet` | `mac_list_local_ips` |
| 登录触发 | 计划任务 `AtLogOn` | LaunchAgent `RunAtLoad=true` | `launchd/HZAU-AutoLogin.plist` |
| 周期巡检 | `RepetitionInterval 30min` | `StartInterval=1800`（`--heartbeat-minutes` 可改） | `launchd/HZAU-AutoLogin-Reconnect.plist` |
| 网络变化即时触发 | 无（Windows 也无） | `WatchPaths` 监视系统网络配置/DNS 文件 | `launchd/HZAU-AutoLogin-NetworkChange.plist` |
| 首次 +2min | `Once -At now+2min` | `--reconnect` + `.first_reconnect_done` 标记，首次延后 120s | `reconnect_delay` |
| 不并发 | `MultipleInstances IgnoreNew` | `fcntl.flock` 非阻塞文件锁 | `acquire_lock` |
| 20 分钟时限 | `ExecutionTimeLimit` | `signal.alarm(1200)` 看门狗 | `_watchdog` |
| 错过补跑 | `StartWhenAvailable` | launchd 唤醒后补跑日历/间隔任务 | 系统行为 |
| 无窗口 | `--noconsole` GUI 子系统 exe | 纯命令行二进制由 launchd 启动（无终端/无 Dock 图标） | `build.sh` |
| 签名/拦截 | SmartScreen | `xattr -d com.apple.quarantine` + ad-hoc `codesign -s -` | `install.sh` / `build.sh` |
| 安装入口 | `install.bat` | `install.command`（Finder 双击） | `macos/install.command` |
| 卸载 | `uninstall.bat` | `uninstall.command`（同时删除钥匙串项、助手、sudoers 规则） | `install.sh:do_uninstall` |
| 改密码 | `change_password.bat` | `change_password.command` | 同名 `.command` / `.sh` |
| 诊断 | `diagnose.bat/.ps1` | `diagnose.command/.sh`（章节 1 / 1.5 / 2–7 一一对应） | 同名 `.command` / `.sh` |
| 构建 | `build.ps1` (win64 zip) | `build.sh` (`*-macos-<arch>.zip` + SHA256) | `macos/build.sh` |
| CI | `.github/workflows/release.yml` | 新增并列工作流 `release-macos.yml`（不动原文件） | `.github/workflows/release-macos.yml` |

---

## 三、新增 / 修改文件清单

**未修改任何现有 Windows 文件**（`srun_login.py`、`build.ps1`、`installer/*`、`release.yml`、
`config.example.json`、`README.md`、`TUTORIAL.md`、`docs/*` 均保持原样，验证脚本第 9 项会检查）。

新增（`macos/` 与一个新的 CI 工作流）：

| 文件 | 类型 | 说明 |
|---|---|---|
| `macos/hzau_autologin_macos.py` | 新增 | **核心适配层**：导入原版模块，覆盖 6 个平台符号；文件锁、首巡检延迟、看门狗、文案映射 |
| `macos/keychain.sh` | 新增 | 钥匙串读写共享库（纯 shell，供安装/改密/诊断/卸载复用） |
| `macos/install.sh` | 新增 | 等价 `install.ps1`：参数、交互顺序、配置生成、LaunchAgent 注册、试跑、卸载 |
| `macos/install.command` | 新增 | 双击安装（等价 `install.bat`） |
| `macos/uninstall.command` | 新增 | 双击卸载（等价 `uninstall.bat`） |
| `macos/change_password.sh` / `.command` | 新增 | 等价 `change_password.ps1` / `.bat` |
| `macos/diagnose.sh` / `.command` | 新增 | 等价 `diagnose.ps1` / `.bat`，输出同类报告 txt |
| `macos/network_repair_helper.sh` | 新增 | root 助手，仅接受 `flushdns/release/renew` 三个固定动作 |
| `macos/install_privileged_helper.sh` | 新增 | 一次性管理员授权时以 root 安装助手 + 校验 sudoers |
| `macos/launchd/HZAU-AutoLogin.plist` | 新增 | 登录任务模板 |
| `macos/launchd/HZAU-AutoLogin-Reconnect.plist` | 新增 | 巡检任务模板 |
| `macos/launchd/HZAU-AutoLogin-NetworkChange.plist` | 新增 | 网络变化即时触发模板（`WatchPaths`） |
| `macos/build.sh` | 新增 | 构建二进制与 macOS 分发 zip |
| `macos/README.md` | 新增 | 本文档 |
| `macos/tests/test_offline.py` | 新增 | 本地假门户端到端协议测试（8 项） |
| `macos/tests/test_keychain.py` | 新增 | 钥匙串跨语言一致性测试（3 项） |
| `macos/tests/test_frozen_binary.py` | 新增 | 对真实 PyInstaller 二进制跑完整认证流程（可选） |
| `macos/tests/verify.sh` | 新增 | 一键全量验证（本机实测 41 项） |
| `macos/.gitignore` | 新增 | 忽略本地构建虚拟环境与缓存 |
| `MACOS.md` | 新增 | 仓库根目录的 macOS 版指引（不改动原 README） |
| `.github/workflows/release-macos.yml` | 新增 | 并列 macOS 发布工作流 |

---

## 四、关键改动说明

### 4.1 协议核心零改动

`hzau_autologin_macos.py` 用 `import srun_login as srun` 载入原版，然后只替换 6 个全局符号：

```python
srun.log            = mac_log           # 仅替换提示文案里的 Windows 路径/命令名
srun.alert          = mac_alert         # MessageBoxW -> osascript
srun.load_password  = mac_load_password # DPAPI -> 登录钥匙串
srun.is_elevated    = mac_is_elevated   # IsUserAnAdmin -> geteuid / 助手授权
srun._run_cmd       = mac_run_cmd       # creationflags + ipconfig -> macOS 等价命令
srun.list_local_ips = mac_list_local_ips# gethostname -> ifconfig
```

`run_once()`、`wait_for_network()`、`run_repair()`、`explain_error()`、`do_login()`、
`calc_login_params()`、`xencode()` 等**全部保持原版代码路径**。特别说明：

- 登录请求里的 `os=Windows NT`、`name=Windows` 以及 HTTP `User-Agent` **刻意保留原值**，
  以保证服务端行为与 Windows 版逐字节一致（见离线测试 `test_01` 的断言）。
- `__file__` / `sys.executable` 的 frozen 判定逻辑与原版一致；源码模式另支持
  `HZAU_AUTOLOGIN_DIR` 环境变量，由安装器写进 LaunchAgent 的 `EnvironmentVariables`。

### 4.2 密码：DPAPI → macOS 钥匙串

- 机密存放在**当前用户登录钥匙串**：service = `HZAU-AutoLogin`，account = `id -un`，
  值为 `base64(UTF-8 密码)`（ASCII，避免 `security -w` 的换行/编码歧义），
  写入时带 `-T /usr/bin/security`，保证后台 LaunchAgent 读取不会弹授权框。
- `password.bin` 仍然存在，但内容变成 `base64(JSON 描述符)`（**不含任何机密**），
  用于保留原版「文件存在性检查 / 诊断项 / 卸载清理 / 改密重写」的契约。
- 与 DPAPI CurrentUser 的威胁模型等价：同用户进程可解密，换机/换用户/重装系统必须重设密码。
- 读写两端分别由 shell 与 Python 实现，`test_keychain.py` 专门校验两者格式一致。

### 4.3 权限：UAC → 一次性管理员授权

Windows 用 UAC 让计划任务以「最高权限」运行；macOS 上**必须**用普通用户的
LaunchAgent（否则 root LaunchDaemon 读不到该用户的登录钥匙串）。因此：

- 认证主流程不需要任何管理员权限；
- 安装时（可用 `--no-network-repair` 跳过）通过
  `osascript ... with administrator privileges` 申请一次授权，把 root 助手装到
  `/Library/PrivilegedHelperTools/`（root:wheel 0755），并在 `/etc/sudoers.d/hzau-autologin`
  写一条**只允许执行该固定路径**的 NOPASSWD 规则，用 `visudo -c` 校验；
- `mac_is_elevated()` 把「助手可用」视为等价的「有权限」，从而让原版 `run_repair()`
  的分支与日志文案原样工作；若用户拒绝授权，则走 Windows 完全相同的降级分支
  「无管理员权限，跳过 DHCP 续租，仅被动等待」。

### 4.4 自动化：计划任务 → launchd

三个 `~/Library/LaunchAgents/*.plist` 由安装器按模板渲染（用 `plutil` 做路径转义与
`StartInterval` 整数改写，避免手工拼 XML 出错），随后 `launchctl bootstrap gui/$UID`。
巡检任务额外传 `--reconnect`，程序内用 `.first_reconnect_done` 标记还原 Windows
「首次 +2 分钟」的偏移；`RunAtLoad=true` 在安装时会额外触发一次幂等的在线检查，
由文件锁与 `check_online()` 保证无副作用。

第三个任务 `HZAU-AutoLogin-NetworkChange` 是 **macOS 专属补充**（Windows 版只有前两个）：
launchd 没有「网络状态变化」事件键，但 `WatchPaths` 可在系统网络配置文件被改写时启动
一次性任务。监视 `/Library/Preferences/SystemConfiguration/preferences.plist`、
`com.apple.airport.preferences.plist`、`/var/run/resolv.conf`，分别覆盖 DHCP/服务变化、
加入或遗忘 WiFi、DNS 切换。`ThrottleInterval=30` 抑制抖动；`RunAtLoad=false` 避免在
安装时立刻重复跑。这样「注销下线 + 遗忘网络后重新连接」不再需要等最多 30 分钟。
不需要时可用 `--no-network-trigger` 关闭，行为退回与 Windows 完全一致。

### 4.5 打包与系统拦截

- `build.sh` 生成**无扩展名的纯命令行 Unix 可执行**（不传 `--noconsole`，因为 macOS 上
  它等价于 `--windowed` 会生成 `.app`，不适合 launchd 调用）；
- 构建期做 ad-hoc 签名（Apple Silicon 必需），安装期清除 `com.apple.quarantine`
  （等价 Windows 里「更多信息 → 仍要运行」）；
- 若机器没有预编译二进制，安装器会依次尝试：本地文件 → 从 Release 下载对应架构 zip →
  源码模式（需 Python ≥3.8，生成 shell 启动器）。保证「零 Python 环境」的主路径，
  也给开发者留了可用回退。

---

## 五、安装与使用

```bash
# 方式 A：从 Releases 下载 hzau-autologin-*-macos-<arm64|x86_64>.zip
#         （uname -m 查看架构），解压后双击 install.command
# 方式 B：一行安装（自动拉取源码并以源码模式安装）
bash <(curl -fsSL https://raw.githubusercontent.com/gggggdd/hzau-autologin-release/main/macos/install.sh)
```

交互顺序与 Windows 完全一致：学号 → 运营商后缀（校园网直接回车）→ 密码（不回显）→
「是否现在立即认证一次以验证配置？」→ 打印最近 12 行日志 → 按回车关闭。

| 想做的事 | macOS 上怎么做 |
|---|---|
| 改校园网密码 | 双击安装目录里的 `change_password.command` |
| 一键诊断 | 双击 `diagnose.command`（**不要 sudo**），报告写在安装目录 `diagnose-*.txt` |
| 看日志 | `~/Library/Application Support/HZAU-AutoLogin/srun_login.log` |
| 手动跑一次 | `~/Library/Application Support/HZAU-AutoLogin/hzau-autologin` |
| 检查自动任务 | `launchctl print gui/$(id -u)/HZAU-AutoLogin` |
| 卸载 | 双击 `uninstall.command` |

主要安装参数（与 PowerShell 参数同名，另支持小写长选项）：
`--Username / --Password / --Domain / --SourceExe / --HeartbeatMinutes / --NoHeartbeat /
--Uninstall / --Silent`；macOS 专有 `--no-network-repair`、`--no-network-trigger`、
`--install-dir`、`--no-download`、`--dry-run`。

---

## 六、验证方式

### 6.1 一键验证（已在 macOS 15.8 / arm64 全通过）

```bash
bash macos/tests/verify.sh
```

覆盖 10 组检查（本机实测 **41 项全部通过**）：环境探测、Python 文件编译、
13 个 shell 脚本在 **macOS 自带 bash 3.2** 下的语法、2 个 plist 模板 `plutil -lint`、
安装器 dry-run（确认不写任何文件）、离线端到端协议测试、钥匙串一致性测试、
**PyInstaller 冻结二进制端到端认证**、诊断/改密冒烟测试、以及「上游 Windows 文件
未被改动」的 git 检查。

> 本机已真实执行 `bash macos/build.sh`，在 macOS 15.8 / arm64 上产出
> `dist/hzau-autologin`（ad-hoc 签名通过）与 `*-macos-arm64.zip` + `.sha256`；
> 冻结二进制的端到端认证测试结果为 `PASS`。

### 6.2 离线端到端协议测试

```bash
python3 macos/tests/test_offline.py          # 8 项
python3 macos/tests/test_keychain.py         # 3 项
python3 macos/tests/test_frozen_binary.py    # 可选：需先 bash macos/build.sh
```

`test_offline.py` 在 `127.0.0.1` 起一个假 Srun 门户，让**原版 `srun_login.main()` 完整跑一遍**
真实 HTTP 请求；服务端用独立实现重算 `hmd5` 与 `chksum` 并校验，覆盖：
完整登录成功、已在线短路、缺 `config.json`、缺 `password.bin`、平台覆盖函数、
跨进程文件锁、句柄格式、macOS 入口 `run()` 装配。全程不接触校园网。

### 6.3 真机安装后的验证清单

```bash
# 1) 任务是否已加载
launchctl print gui/$(id -u)/HZAU-AutoLogin
launchctl print gui/$(id -u)/HZAU-AutoLogin-Reconnect

# 2) 手动触发一次并看日志
launchctl kickstart -k gui/$(id -u)/HZAU-AutoLogin
tail -n 20 "$HOME/Library/Application Support/HZAU-AutoLogin/srun_login.log"

# 3) 钥匙串项应存在（不显示密码）
security find-generic-password -s HZAU-AutoLogin -a "$(id -un)" | head -5

# 4) 诊断（正常身份，不要 sudo）
open "$HOME/Library/Application Support/HZAU-AutoLogin/diagnose.command"

# 5) 注销后重新登录，确认 RunAtLoad 自动认证；等待 30 分钟确认巡检触发
```

> **限制说明**：本机不在华中农业大学校园网内，无法执行「真实门户认证」与
> 「DHCP 修复」的现场验证。上述离线测试已覆盖协议、配置、密码、自动化装配与错误分支；
> 真实网络侧的最终确认需按 6.3 在校园网环境完成。

### 6.4 现场排障：代理 TUN / fake-ip 劫持（最常见故障）

如果日志出现下列任一现象，基本可判定本机代理工具接管了认证域名：

- `本机 IP: 28.0.0.1` / `26.x` / `198.18.x` 等非校园网网段
- `有 IP (...) 但门户不可达` 持续出现、`未找到可用的备用网卡`
- `当前已在线，无需认证` 却实际上不了网（代理返回了假的 `rad_user_info` 响应）

现场实测过的完整链路（macOS 15.8）：

```bash
dscacheutil -q host -a name rz.hzau.edu.cn   # 返回 28.0.0.75 → DNS 被 fake-ip 接管
scutil --dns | grep nameserver               # 第一条是 28.0.0.2 → TUN 虚拟 DNS
route -n get 28.0.0.75                       # interface: utun4，gateway: 28.0.0.1
ifconfig -a | grep -E '^utun|inet '          # utun4 上有 28.0.0.1
curl -k -m 8 https://rz.hzau.edu.cn/...     # SSL_ERROR_SYSCALL / remote_ip 为假地址
```

处理顺序：

1. **退出代理工具的 TUN / 增强 / 虚拟网卡模式**（Clash、Mihomo、Surge、Radmin VPN 等），
   或至少把 `rz.hzau.edu.cn` 加入 DIRECT 直连规则并关闭 fake-ip。
2. 验证 DNS 恢复：`dscacheutil -q host -a name rz.hzau.edu.cn` 应返回真实门户 IP，
   且 `scutil --dns` 第一条不再是 28.x。
3. 确认物理网络确实连的是校园网（而非家用路由器 / 手机热点），
   浏览器能打开 `https://rz.hzau.edu.cn` 的认证页。
4. 手动运行一次并看日志：`"<安装目录>/hzau-autologin"`。

适配层已针对该场景做了三处加固（v1.1.2 之后）：

- `get_local_ip` 改为取**默认路由物理网卡**地址，不再被 utun 主机路由带偏；
- `list_local_ips` 排除 utun/tun/tap/ppp 等虚拟网卡，避免把 28.x 当成备用出口；
- 启动时清除 shell 注入的 `HTTP_PROXY / HTTPS_PROXY` 等变量，避免 `urllib` 走本地代理
  而拿到假「已在线」响应；检测到 fake-ip 时在日志里写明原因。
  （确需保留代理时设置 `HZAU_KEEP_PROXY=1`。）

这些加固只让日志与 IP 判定变准确，**不能绕过被劫持的 DNS/路由**——
根本解法仍是第 1 步。

### 6.5 现场排障：下线 / 遗忘网络后仍弹出系统认证窗口

**现象**：在自助服务注销下线、再在 macOS 里「遗忘此网络」重新连接，系统立刻弹出
Captive Portal 认证窗口，工具却没有自动认证。

三个原因叠加：

1. **触发点只有两个**。Windows 版是「登录时」+「每 30 分钟」，macOS 版原样对齐。
   会话中途的网络变化**不是**触发条件，因此从下线到下一次巡检最长要等 30 分钟。
2. **系统弹窗比工具快**。macOS 的 Captive Portal 检测内置在网络栈里，网络状态一变就
   立即探测并弹窗；它不是由我们的 LaunchAgent 控制的，两者没有联动。
3. **下线瞬间门户未必可达**。现场日志中重连后本机 IP 变为 `192.168.1.101`，程序判定
   `有 IP 但门户不可达` 并进入等待循环；此时即便被触发也不会发起登录请求。

**解决办法**：新增 `HZAU-AutoLogin-NetworkChange.plist`，用 launchd 的 `WatchPaths`
监视系统网络配置与 DNS 文件，在这些文件被改写时立即启动一次认证（macOS 专属补充，
Windows 版没有对应能力）。它与原来的两个任务并存，不改变「登录时 / 30 分钟」的语义；
文件锁与 `check_online()` 保证重复触发无副作用。不需要时可用
`--no-network-trigger` 关闭，行为退回与 Windows 完全一致。

plist 放进 `~/Library/LaunchAgents/` 后，需**注销并重新登录一次**让 launchd 加载，
或在「终端」里手工加载：

```bash
launchctl bootstrap gui/$(id -u) \
  "$HOME/Library/LaunchAgents/HZAU-AutoLogin-NetworkChange.plist"
launchctl print gui/$(id -u)/HZAU-AutoLogin-NetworkChange   # 确认已加载
```

边界：WiFi 重连后 DHCP/路由收敛仍需几秒，且必须门户可达；在完全非校园网的环境里
依旧会按 `network_wait_seconds` 超时放弃，属预期行为。

---

## 七、已知边界与注意事项

1. **协议载荷刻意保留 `os=Windows NT` / `name=Windows`**：为的是与 Windows 版行为一致；
   若学校服务端按该字段做设备类型统计，macOS 客户端会被记为 Windows，属预期取舍。
2. **LaunchAgent 而非 LaunchDaemon**：这是钥匙串按用户隔离的必然结果；也使认证主流程
   完全不需要管理员权限。仅 DHCP 修复需要可选的一次性授权。
3. **特权助手是可选增强**：拒绝授权、系统 `/etc/sudoers` 未引入 `sudoers.d`、或
   `sudo -n` 校验不通过时，功能按 Windows 的「普通权限」路径降级，认证不受影响。
4. **密码短暂出现在 `security` 的 argv**：写入钥匙串时以 base64 载荷传入 `-w`。
   这与 Windows PowerShell 用 `SecureStringToBSTR` 后交给 .NET 的暴露面相当，
   且 DPAPI CurrentUser 本身也允许同用户任意进程解密。若要求更严格，可改用
   Security 框架的 `SecKeychainAddGenericPassword` C 接口（本机已验证可用）。
5. **架构**：PyInstaller 单文件二进制与构建机架构绑定。CI 用 `macos-13` / `macos-14`
   矩阵分别出包，zip 名带 `uname -m`；用户需选与自己架构一致的包。
6. **Gatekeeper**：未签名程序可能提示「无法打开」。安装器会清除隔离属性并做 ad-hoc
   签名；若仍被拦，对解压目录执行 `xattr -cr <目录>` 后重试。
7. **上游 `Read-Host` 缺陷**：三份 Windows PowerShell 脚本共 10 处调用了不存在的
   cmdlet。按本次「不改变原有」的约束未做修改；如需修复 Windows 交互安装，
   应另行把 `Read-Host` 统一替换为 `Read-Host`。
8. **macOS bash 3.2**：所有脚本避免使用 `${var^^}`、空数组展开、`$变量` 后紧跟中文等
   在 bash 3.2 上会出错的写法，验证脚本第 2 项专门做语法回归。
