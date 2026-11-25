#!/bin/bash
# HZAU 校园网自动认证 —— macOS 一键安装 / 卸载
#
# 等价 Windows installer/install.ps1 + install.bat + uninstall.bat。
# 参数名、交互顺序、配置项、自动化行为与 Windows 版保持一致：
#
#   双击 install.command          == 双击 install.bat
#   双击 uninstall.command        == 双击 uninstall.bat
#   --Username / --Password       == -Username / -Password
#   --Domain                      == -Domain
#   --SourceExe（--source-bin）   == -SourceExe
#   --HeartbeatMinutes            == -HeartbeatMinutes
#   --NoHeartbeat                 == -NoHeartbeat
#   --Uninstall                   == -Uninstall
#   --Silent                      == -Silent
#
# macOS 专有补充（不影响上述行为）：
#   --no-network-repair  不申请一次性管理员授权安装特权网络修复助手
#                        （等价 Windows 上 UAC 被拒绝后的降级安装）
#   --install-dir        覆盖安装目录
#   --dry-run            只打印将要执行的动作，不写入任何文件/系统配置

set -u

# ---------------------------------------------------------------- 管道执行引导
# 支持 curl -fsSL <raw>/macos/install.sh | bash 的一行安装（等价 Windows 的 irm | iex）
SELF="${BASH_SOURCE[0]:-}"
if [ -z "$SELF" ] || [ ! -f "$SELF" ]; then
    echo '==> 管道模式：正在下载源码到本地临时目录...'
    TMPREPO="$(/usr/bin/mktemp -d /tmp/hzau-autologin.XXXXXX)" || exit 1
    /usr/bin/curl -fsSL \
        'https://github.com/gggggdd/hzau-autologin-release/archive/refs/heads/main.tar.gz' \
        -o "$TMPREPO/src.tar.gz" || { echo '下载源码失败' >&2; exit 1; }
    /usr/bin/tar -xzf "$TMPREPO/src.tar.gz" -C "$TMPREPO" || exit 1
    SRCROOT="$(/usr/bin/find "$TMPREPO" -maxdepth 1 -type d -name 'hzau-autologin-release-*' | /usr/bin/head -1)"
    [ -n "$SRCROOT" ] && [ -f "$SRCROOT/macos/install.sh" ] || { echo '源码结构异常' >&2; exit 1; }
    exec /bin/bash "$SRCROOT/macos/install.sh" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=keychain.sh
. "$SCRIPT_DIR/keychain.sh"

# ---------------------------------------------------------------- 默认值
INSTALL_DIR="$HOME/Library/Application Support/HZAU-AutoLogin"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL_LOGIN='HZAU-AutoLogin'
LABEL_BEAT='HZAU-AutoLogin-Reconnect'
LABEL_NET='HZAU-AutoLogin-NetworkChange'
HEARTBEAT_MINUTES=30
NO_HEARTBEAT=0
NO_NETWORK_TRIGGER=0
UNINSTALL=0
SILENT=0
NO_NETWORK_REPAIR=0
NO_DOWNLOAD=0
DRY_RUN=0
USERNAME_ARG=''
PASSWORD_ARG=''
DOMAIN=''
SOURCE_BIN=''
PROGRAM_NAME='hzau-autologin'
HELPER='/Library/PrivilegedHelperTools/hzau-autologin-network-repair'
SUDOERS='/etc/sudoers.d/hzau-autologin'

usage() {
    cat <<'USAGE'
用法: install.sh [选项]

  --username, -Username <学号>          不给则交互式询问
  --password, -Password <密码>          建议留空由交互输入（命令行传参会出现在进程列表）
  --domain, -Domain <后缀>              @cmcc / @unicom / @telecom，默认空
  --source-bin, -SourceExe <路径>       本地 macOS 二进制；不给则自动查找/下载
  --heartbeat-minutes, -HeartbeatMinutes <分钟>  默认 30
  --no-heartbeat, -NoHeartbeat          只保留登录时触发，不装周期巡检
  --no-network-trigger                   不装「网络变化时立即认证」任务（macOS 专属补充）
  --uninstall, -Uninstall                卸载
  --silent, -Silent                      非交互：不提问、结尾不暂停
  --no-network-repair                    不安装特权网络修复助手（DHCP 续租降级）
  --no-download                          不联网下载 Release（离线/测试用）
  --install-dir <路径>                   覆盖安装目录
  --dry-run                              只打印计划动作，不写入
  --help                                 显示本帮助
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --username|-Username|-u)            USERNAME_ARG="${2:-}"; shift 2 ;;
        --password|-Password|-p)            PASSWORD_ARG="${2:-}"; shift 2 ;;
        --domain|-Domain|-d)                DOMAIN="${2:-}"; shift 2 ;;
        --source-bin|-SourceExe|--sourceexe) SOURCE_BIN="${2:-}"; shift 2 ;;
        --heartbeat-minutes|-HeartbeatMinutes) HEARTBEAT_MINUTES="${2:-30}"; shift 2 ;;
        --no-heartbeat|-NoHeartbeat)        NO_HEARTBEAT=1; shift ;;
        --no-network-trigger)               NO_NETWORK_TRIGGER=1; shift ;;
        --uninstall|-Uninstall)             UNINSTALL=1; shift ;;
        --silent|-Silent)                   SILENT=1; shift ;;
        --no-network-repair)                NO_NETWORK_REPAIR=1; shift ;;
        --no-download)                      NO_DOWNLOAD=1; shift ;;
        --install-dir)                      INSTALL_DIR="${2:-}"; shift 2 ;;
        --dry-run)                          DRY_RUN=1; shift ;;
        --help|-h)                          usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 1 ;;
    esac
done

say()   { printf '%s\n' "$*"; }
step()  { printf '\n==> %s\n' "$*"; }
warn()  { printf '  [警告] %s\n' "$*" >&2; }
upper() { printf '%s' "$1" | /usr/bin/tr '[:lower:]' '[:upper:]'; }
die()   { printf '\n安装失败: %s\n' "$*" >&2; [ "$SILENT" -eq 1 ] || read -r -p '按回车键关闭窗口...' _ || true; exit 1; }
pause_end() { [ "$SILENT" -eq 1 ] || { printf '\n'; read -r -p '按回车键关闭窗口...' _ || true; }; }

json_escape() {
    printf '%s' "$1" | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}
xml_escape() {
    printf '%s' "$1" | /usr/bin/sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# ---------------------------------------------------------------- 卸载
do_uninstall() {
    step '卸载 HZAU-AutoLogin（macOS）'
    local uid plist label
    uid="$(id -u)"
    for label in "$LABEL_LOGIN" "$LABEL_BEAT" "$LABEL_NET"; do
        plist="$AGENT_DIR/$label.plist"
        say "  [dry-run] 或实际执行: launchctl bootout gui/$uid/$label; rm -f $plist"
        if [ "$DRY_RUN" -eq 0 ]; then
            /bin/launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || \
                /bin/launchctl unload -w "$plist" >/dev/null 2>&1 || true
            /bin/rm -f "$plist"
            say "  已移除 LaunchAgent: $label"
        fi
    done
    if [ "$DRY_RUN" -eq 0 ]; then
        # 清除历史上可能存在的所有变体（等价 Windows 清理旧启动项）
        /usr/bin/find "$AGENT_DIR" -maxdepth 1 -name 'HZAU-AutoLogin*.plist' -type f \
            -exec /bin/rm -f {} \; 2>/dev/null || true
        hzau_kc_delete && say '  已删除登录钥匙串中的密码项' || true
        if [ -f "$SUDOERS" ] || [ -f "$HELPER" ]; then
            say '  检测到特权网络修复助手，需要管理员权限清理：'
            local cmd="/bin/rm -f '$SUDOERS' '$HELPER'"
            /usr/bin/osascript -e 'on run argv' \
                -e 'do shell script (item 1 of argv) with administrator privileges' \
                -e 'end run' -- "$cmd" >/dev/null 2>&1 \
                && say '  已移除助手与 sudoers 规则' \
                || warn '未获得管理员权限，请手动删除 /etc/sudoers.d/hzau-autologin 与 /Library/PrivilegedHelperTools/hzau-autologin-network-repair'
        fi
    fi
    if [ -d "$INSTALL_DIR" ]; then
        local ans='N'
        if [ "$SILENT" -eq 1 ]; then ans='Y'
        elif [ "$DRY_RUN" -eq 0 ]; then read -r -p "  删除安装目录（含配置与加密密码）$INSTALL_DIR ? [Y/N] " ans || true; fi
        if [ "$(upper "$ans")" = 'Y' ]; then
            if [ "$DRY_RUN" -eq 0 ]; then
                # 安全护栏：只允许删除本工具自己的安装目录，避免误伤用户目录
                case "$INSTALL_DIR" in
                    "$HOME"/Library/Application\ Support/HZAU-AutoLogin)
                        /bin/rm -rf "$INSTALL_DIR" ;;
                    *)
                        warn "自定义安装目录不自动删除，请手动处理: $INSTALL_DIR" ;;
                esac
            fi
            say '  已删除安装目录'
        else
            say '  保留安装目录（可手动删除）'
        fi
    fi
    say ''
    say '卸载完成。'
}

if [ "$UNINSTALL" -eq 1 ]; then do_uninstall; pause_end; exit 0; fi

# ---------------------------------------------------------------- 定位程序
find_python() {
    local p
    for p in "${PYTHON_BIN:-}" python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
        [ -n "$p" ] || continue
        command -v "$p" >/dev/null 2>&1 || continue
        if "$p" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
            command -v "$p"; return 0
        fi
    done
    return 1
}

resolve_payload() {
    # 输出两行：MODE(binary|source) 与 源路径；失败返回 1
    local c tmpzip tmpdir arch found
    for c in "$SOURCE_BIN" \
             "$SCRIPT_DIR/$PROGRAM_NAME" \
             "$REPO_ROOT/dist/$PROGRAM_NAME" \
             "$INSTALL_DIR/$PROGRAM_NAME"; do
        if [ -n "$c" ] && [ -f "$c" ]; then
            printf 'binary\n%s\n' "$c"; return 0
        fi
    done

    if [ "$NO_DOWNLOAD" -eq 0 ]; then
        warn '本地未找到 macOS 二进制，尝试从 GitHub Release 下载...'
        arch="$(uname -m)"
        tmpdir="$(/usr/bin/mktemp -d /tmp/hzau-autologin-dl.XXXXXX)" || return 1
        tmpzip="$tmpdir/macos.zip"
        if /usr/bin/curl -fsSL --max-time 120 \
            "https://github.com/gggggdd/hzau-autologin-release/releases/latest/download/hzau-autologin-macos-$arch.zip" \
            -o "$tmpzip" 2>/dev/null; then
            /usr/bin/unzip -q -o "$tmpzip" -d "$tmpdir/pkg" 2>/dev/null || true
            found="$(/usr/bin/find "$tmpdir/pkg" -type f -name "$PROGRAM_NAME" | /usr/bin/head -1)"
            if [ -n "$found" ] && [ -x "$found" ]; then printf 'binary\n%s\n' "$found"; return 0; fi
        fi
        /bin/rm -rf "$tmpdir"
    else
        warn '已指定 --no-download，跳过 Release 下载'
    fi

    # 源码回退：需要 Python 3.8+（开发/自构建场景）
    if [ -f "$REPO_ROOT/srun_login.py" ] && [ -f "$SCRIPT_DIR/hzau_autologin_macos.py" ]; then
        local py
        py="$(find_python)" || return 1
        printf 'source\n%s\n' "$py"; return 0
    fi
    return 1
}

# ---------------------------------------------------------------- 生成 config.json
write_config() {
    local dir="$1" user="$2" dom="$3"
    local eu ed
    eu="$(json_escape "$user")"; ed="$(json_escape "$dom")"
    # 字段、顺序、默认值与 Windows Save-Config 完全一致（UTF-8 无 BOM）
    # 用 printf + %s 传参，避免 heredoc 二次展开用户输入里的 $() / 反引号
    printf '%s\n' \
        '{' \
        '  "server": "https://rz.hzau.edu.cn",' \
        '  "ac_id": "5",' \
        "  \"username\": \"$eu\"," \
        "  \"domain\": \"$ed\"," \
        '  "max_attempts": 3,' \
        '  "retry_interval": 3,' \
        '  "network_wait_seconds": 300,' \
        '  "repair_interval_seconds": 60' \
        '}' > "$dir/config.json"
    chmod 600 "$dir/config.json"
}

# ---------------------------------------------------------------- 生成 LaunchAgent plist
render_plist() {
    local template="$1" out="$2" program="$3" beat_seconds="$4"
    HZ_PROGRAM="$(xml_escape "$program")" \
    HZ_INDIR="$(xml_escape "$INSTALL_DIR")" \
    HZ_STDOUT="$(xml_escape "$INSTALL_DIR/launchd-stdout.log")" \
    HZ_STDERR="$(xml_escape "$INSTALL_DIR/launchd-stderr.log")" \
    /usr/bin/awk '
        function rep(s, from, to,   p, o) {
            o = ""
            while ((p = index(s, from)) > 0) {
                o = o substr(s, 1, p - 1) to
                s = substr(s, p + length(from))
            }
            return o s
        }
        BEGIN { p = ENVIRON["HZ_PROGRAM"]; d = ENVIRON["HZ_INDIR"]
                o = ENVIRON["HZ_STDOUT"]; e = ENVIRON["HZ_STDERR"] }
        {
            line = $0
            line = rep(line, "__PROGRAM__", p)
            line = rep(line, "__INSTALL_DIR__", d)
            line = rep(line, "__STDOUT_LOG__", o)
            line = rep(line, "__STDERR_LOG__", e)
            print line
        }
    ' "$template" > "$out"
    # 模板本身必须是合法 plist（能被 plutil -lint）；巡检间隔用 plutil 原地改整数，
    # 避免占位符出现在 <integer> 里导致模板非法。
    if /usr/bin/plutil -extract StartInterval raw -o - "$out" >/dev/null 2>&1; then
        /usr/bin/plutil -replace StartInterval -integer "$beat_seconds" "$out" >/dev/null || return 1
    fi
    /usr/bin/plutil -lint "$out" >/dev/null || return 1
}

# ---------------------------------------------------------------- 一次性提权
install_helper() {
    if [ "$NO_NETWORK_REPAIR" -eq 1 ]; then
        warn '已指定 --no-network-repair：跳过特权助手，DHCP 续租将按「无管理员权限」降级'
        return 0
    fi
    if [ -f "$SUDOERS" ] && [ -x "$HELPER" ]; then
        say '  特权网络修复助手已存在，跳过'
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  [dry-run] 申请一次管理员授权，安装 $HELPER 与 $SUDOERS"
        return 0
    fi
    step '申请管理员权限（等价 Windows UAC，仅需一次）'
    local wrapper cmd
    wrapper="$(/usr/bin/mktemp /tmp/hzau-helper-install.XXXXXX)"
    {
        printf '#!/bin/sh\n'
        printf 'exec /bin/sh %q %q %q\n' \
            "$SCRIPT_DIR/install_privileged_helper.sh" \
            "$(id -un)" \
            "$SCRIPT_DIR/network_repair_helper.sh"
    } > "$wrapper"
    chmod 0700 "$wrapper"
    cmd="/bin/sh $wrapper"
    if /usr/bin/osascript -e 'on run argv' \
        -e 'do shell script (item 1 of argv) with administrator privileges' \
        -e 'end run' -- "$cmd" >/dev/null 2>&1; then
        say '  已安装特权网络修复助手（DHCP 续租可用）'
        # 从普通用户侧验证这条 NOPASSWD 规则确实生效；不生效时明确告知降级结果
        if ! /usr/bin/sudo -n -l "$HELPER" >/dev/null 2>&1; then
            warn '规则已写入但 sudo -n 校验未通过（/etc/sudoers 可能未引入 sudoers.d）。'
            warn '开机自动认证不受影响；DHCP 续租将按「无管理员权限」降级。'
        fi
    else
        warn '未获得管理员权限。将以「普通权限」继续：开机可自动认证，'
        warn '但拿不到 IP 时无法自动执行 DHCP 续租（与 Windows 降级行为一致）。'
    fi
    /bin/rm -f "$wrapper"
}

# ================================================================ 主流程
trap 'true' ERR

if ! [[ "$HEARTBEAT_MINUTES" =~ ^[0-9]+$ ]] || [ "$HEARTBEAT_MINUTES" -lt 1 ]; then
    die '--heartbeat-minutes 必须是正整数'
fi
BEAT_SECONDS=$((HEARTBEAT_MINUTES * 60))

step '准备安装目录'
say "  安装目录: $INSTALL_DIR"
say "  LaunchAgent 目录: $AGENT_DIR"
PAYLOAD="$(resolve_payload)" || die '找不到 macOS 可执行程序，也无法下载 Release 或进入源码模式。请从 Releases 下载 hzau-autologin-macos-*.zip，解压后双击 install.command。'
MODE="$(printf '%s\n' "$PAYLOAD" | /usr/bin/head -1)"
PAYLOAD_PATH="$(printf '%s\n' "$PAYLOAD" | /usr/bin/tail -1)"
say "  程序来源: $MODE -> $PAYLOAD_PATH"

step '配置账号'
USERNAME="$USERNAME_ARG"
if [ -z "$USERNAME" ] && [ "$SILENT" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    read -r -p '请输入学号: ' USERNAME || true
fi
USERNAME="$(printf '%s' "$USERNAME" | /usr/bin/sed 's/@.*$//')"   # 后缀统一走 domain 字段
[ -n "$USERNAME" ] || die '学号不能为空（静默模式请用 --username 传入）'

if [ -z "$DOMAIN" ] && [ "$SILENT" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    read -r -p '运营商宽带后缀（校园网账号直接回车，如移动填 @cmcc）: ' DOMAIN || true
fi

PASSWORD="$PASSWORD_ARG"
if [ -z "$PASSWORD" ] && [ "$SILENT" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    read -r -s -p '请输入校园网密码: ' PASSWORD || true
    printf '\n'
fi
if [ -z "$PASSWORD" ] && [ "$DRY_RUN" -eq 0 ]; then
    die '密码不能为空（静默模式请用 --password 传入）'
fi

if [ "$DRY_RUN" -eq 1 ]; then
    say '  [dry-run] 将写入 config.json:'
    printf '  {\n    "server": "https://rz.hzau.edu.cn",\n    "ac_id": "5",\n    "username": "%s",\n    "domain": "%s",\n    "max_attempts": 3,\n    "retry_interval": 3,\n    "network_wait_seconds": 300,\n    "repair_interval_seconds": 60\n  }\n' "$USERNAME" "$DOMAIN"
    say '  [dry-run] 将把密码写入当前用户登录钥匙串，并在安装目录生成 password.bin 句柄'
else
    /bin/mkdir -p "$INSTALL_DIR" || die "无法创建 $INSTALL_DIR"
    chmod 700 "$INSTALL_DIR"
    write_config "$INSTALL_DIR" "$USERNAME" "$DOMAIN"
    hzau_kc_save "$PASSWORD" || die '写入登录钥匙串失败（登录钥匙串可能被锁定）'
    hzau_write_password_handle "$INSTALL_DIR"
    say '  已保存 config.json 与 macOS 钥匙串加密的 password.bin 句柄'
fi

step '安装程序文件'
PROGRAM="$INSTALL_DIR/$PROGRAM_NAME"
if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$MODE" = 'binary' ]; then
        /bin/cp -f "$PAYLOAD_PATH" "$PROGRAM"
        /bin/chmod 0755 "$PROGRAM"
        /usr/bin/xattr -d com.apple.quarantine "$PROGRAM" >/dev/null 2>&1 || true
        # 未签名的自编译程序在 Apple Silicon 上需要有效签名；已有有效签名则保留
        /usr/bin/codesign --verify "$PROGRAM" >/dev/null 2>&1 || \
            /usr/bin/codesign --force --sign - "$PROGRAM" >/dev/null 2>&1 || true
        say "  已安装二进制: $PROGRAM"
    else
        # 源码模式：把原版协议脚本 + macOS 适配层 + 启动器一起放进安装目录
        /bin/cp -f "$REPO_ROOT/srun_login.py" "$INSTALL_DIR/srun_login.py"
        /bin/cp -f "$SCRIPT_DIR/hzau_autologin_macos.py" "$INSTALL_DIR/hzau_autologin_macos.py"
        /bin/cat > "$PROGRAM" <<LAUNCHER
#!/bin/sh
# HZAU-AutoLogin 源码模式启动器（由 install.sh 生成，Python 路径在安装时固定）
DIR="\$(cd "\$(dirname "\$0")" && pwd)"
export HZAU_AUTOLOGIN_DIR="\$DIR"
exec "$PAYLOAD_PATH" "\$DIR/hzau_autologin_macos.py" "\$@"
LAUNCHER
        /bin/chmod 0755 "$PROGRAM"
        say "  已安装源码模式启动器: $PROGRAM (Python: $PAYLOAD_PATH)"
    fi
    # 附带日常维护工具（等价 Windows 把 change_password.* 复制进安装目录）
    for f in install.sh keychain.sh change_password.sh change_password.command \
             diagnose.sh diagnose.command uninstall.command \
             network_repair_helper.sh install_privileged_helper.sh; do
        [ -f "$SCRIPT_DIR/$f" ] && /bin/cp -f "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
    done
    /bin/mkdir -p "$INSTALL_DIR/launchd"
    /bin/cp -f "$SCRIPT_DIR/launchd/"*.plist "$INSTALL_DIR/launchd/" 2>/dev/null || true
    [ -f "$REPO_ROOT/config.example.json" ] && /bin/cp -f "$REPO_ROOT/config.example.json" "$INSTALL_DIR/config.example.json"
    [ -f "$SCRIPT_DIR/README.md" ] && /bin/cp -f "$SCRIPT_DIR/README.md" "$INSTALL_DIR/README.md"
    /bin/chmod +x "$INSTALL_DIR/"*.command 2>/dev/null || true
    /usr/bin/xattr -dr com.apple.quarantine "$INSTALL_DIR" >/dev/null 2>&1 || true
else
    say "  [dry-run] 将安装程序到 ${PROGRAM}（模式: ${MODE}）及维护脚本"
fi

install_helper

step '注册 LaunchAgent（等价 Windows 计划任务）'
TMPD="$(/usr/bin/mktemp -d /tmp/hzau-plist.XXXXXX)"
if render_plist "$SCRIPT_DIR/launchd/$LABEL_LOGIN.plist" "$TMPD/$LABEL_LOGIN.plist" "$PROGRAM" "$BEAT_SECONDS"; then
    say "  [生成] $LABEL_LOGIN.plist (RunAtLoad=true，登录时触发)"
else
    /bin/rm -rf "$TMPD"; die '登录任务 plist 生成失败'
fi
if [ "$NO_HEARTBEAT" -eq 0 ]; then
    if render_plist "$SCRIPT_DIR/launchd/$LABEL_BEAT.plist" "$TMPD/$LABEL_BEAT.plist" "$PROGRAM" "$BEAT_SECONDS"; then
        say "  [生成] $LABEL_BEAT.plist (StartInterval=$BEAT_SECONDS 秒，每 $HEARTBEAT_MINUTES 分钟巡检)"
    else
        /bin/rm -rf "$TMPD"; die '巡检任务 plist 生成失败'
    fi
fi

if [ "$NO_NETWORK_TRIGGER" -eq 0 ]; then
    if render_plist "$SCRIPT_DIR/launchd/$LABEL_NET.plist" "$TMPD/$LABEL_NET.plist" "$PROGRAM" "$BEAT_SECONDS"; then
        say "  [生成] $LABEL_NET.plist (WatchPaths，网络变化时立即触发)"
    else
        /bin/rm -rf "$TMPD"; die '网络变化任务 plist 生成失败'
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    say '  [dry-run] 上述 plist 内容预览：'
    /bin/cat "$TMPD/$LABEL_LOGIN.plist"
    if [ "$NO_HEARTBEAT" -eq 0 ]; then /bin/cat "$TMPD/$LABEL_BEAT.plist"; fi
    if [ "$NO_NETWORK_TRIGGER" -eq 0 ]; then /bin/cat "$TMPD/$LABEL_NET.plist"; fi
    say "  [dry-run] 将复制到 $AGENT_DIR 并执行 launchctl bootstrap gui/$(id -u)"
else
    /bin/mkdir -p "$AGENT_DIR"
    uid="$(id -u)"
    for label in "$LABEL_LOGIN" "$LABEL_BEAT" "$LABEL_NET"; do
        plist="$AGENT_DIR/$label.plist"
        /bin/launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || \
            /bin/launchctl unload -w "$plist" >/dev/null 2>&1 || true
        /bin/rm -f "$plist"
    done
    /bin/cp -f "$TMPD/$LABEL_LOGIN.plist" "$AGENT_DIR/$LABEL_LOGIN.plist"
    /bin/launchctl bootstrap "gui/$uid" "$AGENT_DIR/$LABEL_LOGIN.plist" 2>/dev/null || \
        /bin/launchctl load -w "$AGENT_DIR/$LABEL_LOGIN.plist"
    /bin/launchctl enable "gui/$uid/$LABEL_LOGIN" >/dev/null 2>&1 || true
    say "  已注册: ${LABEL_LOGIN}（登录时触发，普通用户 LaunchAgent）"
    if [ "$NO_HEARTBEAT" -eq 0 ]; then
        /bin/cp -f "$TMPD/$LABEL_BEAT.plist" "$AGENT_DIR/$LABEL_BEAT.plist"
        /bin/launchctl bootstrap "gui/$uid" "$AGENT_DIR/$LABEL_BEAT.plist" 2>/dev/null || \
            /bin/launchctl load -w "$AGENT_DIR/$LABEL_BEAT.plist"
        /bin/launchctl enable "gui/$uid/$LABEL_BEAT" >/dev/null 2>&1 || true
        say "  已注册: ${LABEL_BEAT}（每 $HEARTBEAT_MINUTES 分钟检查一次，断线自动重连）"
    else
        say '  已按 --NoHeartbeat 跳过周期巡检任务'
    fi
    if [ "$NO_NETWORK_TRIGGER" -eq 0 ]; then
        /bin/cp -f "$TMPD/$LABEL_NET.plist" "$AGENT_DIR/$LABEL_NET.plist"
        /bin/launchctl bootstrap "gui/$uid" "$AGENT_DIR/$LABEL_NET.plist" 2>/dev/null || \
            /bin/launchctl load -w "$AGENT_DIR/$LABEL_NET.plist"
        /bin/launchctl enable "gui/$uid/$LABEL_NET" >/dev/null 2>&1 || true
        say "  已注册: ${LABEL_NET}（WiFi 重连 / DNS 变化时立即认证，无需等 30 分钟）"
    else
        /bin/rm -f "$AGENT_DIR/$LABEL_NET.plist"
        say '  已按 --no-network-trigger 跳过网络变化触发任务'
    fi
    # 清理旧启动方式残留（等价 Windows 清理 Startup\HZAU-AutoLogin.cmd）
    /usr/bin/find "$AGENT_DIR" -maxdepth 1 -type f -name 'com.hzau.autologin*.plist' \
        -exec /bin/rm -f {} \; 2>/dev/null || true
fi
/bin/rm -rf "$TMPD"

# ---------------------------------------------------------------- 立即试跑（失败不算安装失败）
DO_TEST='Y'
if [ "$SILENT" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    read -r -p $'\n是否现在立即认证一次以验证配置？[Y/N] ' DO_TEST || true
fi
if [ "$DRY_RUN" -eq 1 ]; then
    say '  [dry-run] 将运行一次认证并打印最近日志'
elif [ "$(upper "$DO_TEST")" = 'Y' ]; then
    step '正在认证...'
    "$PROGRAM" >/dev/null 2>&1 || true
    log="$INSTALL_DIR/srun_login.log"
    if [ -f "$log" ]; then
        printf '\n--- 最近日志 ---\n'
        /usr/bin/tail -n 12 "$log"
        printf '完整日志: %s\n' "$log"
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    say ''
    say 'dry-run 完成：未写入任何文件、钥匙串、LaunchAgent 或系统配置。'
else
    cat <<DONE

安装完成。以后登录 macOS 联网后会自动认证，无需任何操作。
  安装目录: $INSTALL_DIR
  运行日志: $INSTALL_DIR/srun_login.log
  改密码  : 双击 $INSTALL_DIR/change_password.command
  诊断    : 双击 $INSTALL_DIR/diagnose.command
  卸载    : 双击 $INSTALL_DIR/uninstall.command
DONE
fi
pause_end
exit 0
