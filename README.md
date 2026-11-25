# HZAU 校园网自动认证 · macOS 版

华中农业大学校园网（深澜 Srun）**开机自动认证**工具的 macOS 版本。装好之后无需任何操作：登录 macOS 时自动认证、每 30 分钟巡检、WiFi 重连或网络变化时立即补认证。

> 本项目是 [gggggdd/hzau-autologin-release](https://github.com/gggggdd/hzau-autologin-release) 的 macOS 移植版。
> 协议核心 `srun_login.py` 与原仓库**逐字节一致、未做任何修改**，macOS 差异集中在 `macos/` 目录。
> 仅供学习交流，请遵守学校网络使用相关规定。

---

## 一、适用环境

| 项目 | 要求 |
|---|---|
| 系统 | macOS 12 及以上（已在 macOS 15.8 实测） |
| 架构 | Apple Silicon（arm64）/ Intel（x86_64），请下载与 `uname -m` 一致的包 |
| Python | **不需要**。分发包内含单文件可执行程序 |
| 网络 | 必须连接华中农业大学校园网 |

---

## 二、安装（约 2 分钟）

1. 从 [Releases](../../releases) 下载与本机架构一致的
   `hzau-autologin-<版本>-macos-<arm64|x86_64>.zip`，解压到任意位置。
   终端执行 `uname -m` 可查看架构。
2. **双击解压目录里的 `install.command`**，会自动打开「终端」窗口。
3. 按提示依次输入：

   | 提示 | 怎么填 |
   |---|---|
   | `请输入学号` | 纯学号，`@` 后缀不要放这里 |
   | `运营商宽带后缀` | 校园网账号直接回车；移动/联通/电信填 `@cmcc` / `@unicom` / `@telecom` |
   | `请输入校园网密码` | 输入时不显示字符，正常现象 |
   | `是否现在立即认证一次以验证配置？` | 输入 `Y`，看到 `认证成功` 即完成 |

4. 首次会弹出**一次系统授权框**，输入本机解锁密码即可。它用于安装 DHCP 网络修复助手（等价 Windows 的 UAC）；拒绝也不影响认证，只是拿不到 IP 时无法自动续租。

> **若 Finder 提示「无法打开，因为来自身份不明的开发者」**：右键 `install.command` 选「打开」，
> 或在终端执行 `xattr -cr <解压目录>` 后重试。程序为自编译未签名，属正常提示，Release 附 SHA256 可自行比对。

安装完成后建议注销重新登录一次做最终确认。

---

## 三、装完之后会自动做什么

| 场景 | 行为 | 多久 |
|---|---|---|
| 每次登录 macOS | 自动认证 | 立即；网络未就绪时最多等 300 秒 |
| 掉线 / 会话过期 | 周期巡检发现后补认证 | 每 30 分钟 |
| WiFi 重连、遗忘网络、DNS 变化 | 网络变化触发，立即认证 | 几秒内（DHCP 收敛后） |
| 已经在线 | 跳过，不重复登录 | 日志写「当前已在线，无需认证」 |

对应三个 LaunchAgent：`HZAU-AutoLogin`（登录时）、`HZAU-AutoLogin-Reconnect`（30 分钟）、
`HZAU-AutoLogin-NetworkChange`（网络变化）。程序是**一次性进程**，跑完就退出，
在 `launchctl` 里看到 `state = not running` 是正常的。

---

## 四、日常操作

安装目录：`~/Library/Application Support/HZAU-AutoLogin/`

| 想做的事 | 怎么做 |
|---|---|
| 查看是否成功 | `tail -n 10 "$HOME/Library/Application Support/HZAU-AutoLogin/srun_login.log"` |
| 手动跑一次 | `"$HOME/Library/Application Support/HZAU-AutoLogin/hzau-autologin"` |
| 改校园网密码 | 双击安装目录里的 `change_password.command` |
| 认证失败排查 | 双击 `diagnose.command`（**不要加 sudo**），报告生成在安装目录 `diagnose-*.txt` |
| 检查自动任务 | `launchctl print gui/$(id -u)/HZAU-AutoLogin` |
| 卸载 | 双击 `uninstall.command`（会清除钥匙串项、LaunchAgent、助手与 sudoers 规则） |

> `diagnose.command` 只是排障工具，正常情况一次都不需要打开。

---

## 五、常见问题

**装完却一直上不了网 / 日志反复出现「有 IP 但门户不可达」**

按顺序检查三件事：

1. **关闭代理工具的 TUN / 增强 / 虚拟网卡模式**（Clash、Mihomo、Surge、Radmin VPN 等），
   或把 `rz.hzau.edu.cn` 加入 DIRECT 直连规则并关闭 fake-ip。
   判断方法：`dscacheutil -q host -a name rz.hzau.edu.cn` 若返回 `28.x` / `198.18.x`，
   说明 DNS 被 fake-ip 劫持；`ifconfig -a` 里出现 `utun` 且 IP 为 `28.0.0.1` 也是同一症状。
2. **确认连的是校园网**：浏览器打开 `https://rz.hzau.edu.cn` 应能看到认证页。
   连着家用路由器或手机热点时不会认证成功，属预期行为。
3. 恢复后手动触发一次：`launchctl kickstart -k gui/$(id -u)/HZAU-AutoLogin`。

**日志显示 `当前已在线，无需认证` 却上不了网**

服务器认为该账号仍在线（会话可能绑在别的 IP 或设备上）。到 `zizhu.hzau.edu.cn` 自助服务
下线其他设备后重试。若仍异常，运行 `diagnose.command` 并把报告发给维护者。

**E2620 / 在线设备数超限**

同上，到自助服务下线其他设备。

**改了校园网密码 / 换电脑 / 重装系统 / 换 macOS 账号**

密码存在**当前用户的登录钥匙串**里，绑定「本机 + 当前 macOS 用户」。
改密码双击 `change_password.command`；换机或重装需重新双击 `install.command`。

**卸载后想彻底清理**

`uninstall.command` 已覆盖全部内容。如需手工确认，检查
`~/Library/LaunchAgents/HZAU-AutoLogin*.plist` 与
`/Library/PrivilegedHelperTools/hzau-autologin-network-repair` 是否残留。

---

## 六、配置项

配置文件 `config.json` 位于安装目录，字段与原 Windows 版完全一致：

| 键 | 默认 | 含义 |
|---|---|---|
| `server` | `https://rz.hzau.edu.cn` | 认证服务器 |
| `ac_id` | `"5"` | 深澜 AC id |
| `username` | — | 学号 |
| `domain` | `""` | 运营商后缀，如 `@cmcc` |
| `max_attempts` / `retry_interval` | `3` / `3` | 登录重试次数与间隔（秒） |
| `network_wait_seconds` | `300` | 开机后最长等待网络的时间 |
| `repair_interval_seconds` | `60` | 两次网络修复的最小间隔 |

模板见 `config.example.json`。一般不需要手工编辑，重新运行 `install.command` 即可。

---

## 七、给开发者

### 目录结构

```
srun_login.py                  协议核心（原仓库文件，零改动）
config.example.json            配置模板
macos/
  hzau_autologin_macos.py      macOS 平台适配层（导入并覆盖原模块平台符号）
  keychain.sh                  钥匙串读写共享库
  install.sh / install.command 安装
  uninstall.command            卸载
  change_password.*            改密
  diagnose.*                   一键诊断
  network_repair_helper.sh     root 网络修复助手
  install_privileged_helper.sh 助手安装器
  launchd/*.plist              三个 LaunchAgent 模板
  build.sh                     构建二进制与分发 zip
  tests/                       离线测试与一键验证
  README.md                    平台差异、映射表、验证方式
.github/workflows/release-macos.yml   tag 触发的双架构发布流水线
```

### 本地构建与验证

```bash
bash macos/build.sh --version v1.2.0     # 产出 dist/*-macos-<arch>.zip + .sha256
bash macos/tests/verify.sh               # 全量验证（本机实测 43 项）
python3 macos/tests/test_offline.py      # 本地假门户端到端协议测试
```

构建需要 Python ≥ 3.8 + PyInstaller；脚本会自动在项目内建虚拟环境。
`build.sh --arch universal2` 需配合 universal2 Python，否则请使用 CI 的
`macos-13`（Intel）/ `macos-14`（Apple Silicon）矩阵分别出包。

### 安装器参数

与 Windows 版 PowerShell 参数同名：`--Username / --Password / --Domain / --SourceExe /
--HeartbeatMinutes / --NoHeartbeat / --Uninstall / --Silent`。

macOS 专有：`--no-network-repair`（跳过特权助手）、`--no-network-trigger`（跳过网络变化触发）、
`--install-dir`、`--no-download`、`--dry-run`（只打印计划动作，不写入任何文件）。

一行安装（源码模式，需 Python ≥ 3.8）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/macos/install.sh)
```

### 发布到你自己的 GitHub

仓库根目录的 `publish.sh` 封装了创建公开仓库、推送 `main`、创建 Release 并上传
arm64 包与 SHA256 的全部动作。**发布前需先在自己的终端完成交互式登录**（Agent 无法代做）：

```bash
gh auth login                 # 选择 GitHub.com / HTTPS / 浏览器登录
gh auth status                # 确认账号正确
./publish.sh <GitHub用户名> hzau-autologin-macos v1.2.0
```

脚本只读取 `dist/` 下已构建的资产，不会上传 `config.json`、`password.bin` 或日志。
推送 `v*` tag 会触发 `release-macos.yml`，CI 构建的包会追加到同一个 Release。

### 验证方式

`macos/tests/verify.sh` 覆盖：Python 编译、macOS 自带 bash 3.2 语法、plist 严格解析、
安装器 dry-run、离线假门户端到端协议测试（服务端独立重算 hmd5/chksum）、
钥匙串跨语言一致性、PyInstaller 冻结二进制真实认证、诊断/改密冒烟、
以及「协议核心未被改动」的 git 检查。完整说明见 `macos/README.md`。

---

## 八、声明

- 本项目仅做校园网认证的自动化，不破解、不绕过任何计费或访问控制。
- 密码保存在当前用户登录钥匙串中，不落明文、不上传、不写日志。
- 原项目协议分析见 [gggggdd/hzau-autologin](https://github.com/gggggdd/hzau-autologin)。
- 仅供学习交流，请遵守学校网络使用相关规定。
