#!/bin/bash
# HZAU-AutoLogin macOS —— 一键诊断（等价 Windows installer/diagnose.ps1 + diagnose.bat）
#
# 重要：请用【自己平时登录 macOS 的账号】直接双击 diagnose.command 运行，
#       不要 sudo —— 普通身份才能检测出配置/钥匙串是否装错了用户。
#
# 输出顺序、检查项、报告文件与 Windows 版一一对应：
#   1) 安装目录与文件  1.5) 自动化任务状态  2) 配置  3) 密码能否解密
#   4) 本机网络  5) 服务器连通性  6) 实际运行一次  7) 日志尾部

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=keychain.sh
. "$DIR/keychain.sh"

INSTALL_DIR="$HOME/Library/Application Support/HZAU-AutoLogin"
PROGRAM='hzau-autologin'
NO_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --install-dir|-InstallDir) INSTALL_DIR="${2:-}"; shift 2 ;;
        --no-run)                  NO_RUN=1; shift ;;
        --help|-h) echo '用法: diagnose.sh [--install-dir <路径>] [--no-run]'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

STAMP="$(/bin/date '+%Y%m%d-%H%M%S')"
HOST="$(/bin/hostname -s 2>/dev/null || echo mac)"
REPORT="$INSTALL_DIR/diagnose-$HOST-$STAMP.txt"
[ -d "$INSTALL_DIR" ] && : > "$REPORT" 2>/dev/null || true

say() {
    printf '%s\n' "$*"
    [ -n "$REPORT" ] && [ -f "$REPORT" ] && printf '%s\n' "$*" >> "$REPORT"
}
say_ok()   { say "  [OK] $*"; }
say_warn() { say "  [警告] $*"; }
say_bad()  { say "  [错误] $*"; }
say_step() { say ''; say "=== $* ==="; }

pause_end() { printf '\n'; read -r -p '按回车键关闭窗口...' _ || true; }

say '================================================'
say '   HZAU-AutoLogin 一键诊断（macOS）'
say '================================================'
say "  时间    : $(/bin/date '+%Y-%m-%d %H:%M:%S')"
say "  计算机  : $HOST"
say "  当前用户: $(id -un) (uid=$(id -u))"
if [ "$(id -u)" -eq 0 ]; then
    say '  管理员  : 是  （用 sudo 运行了诊断！钥匙串/LaunchAgent 都属于 root，结果不可用）'
else
    say '  管理员  : 否  （正常，普通身份）'
fi
say "  系统    : $(sw_vers -productVersion 2>/dev/null) / $(uname -m)"
say "  目标目录: $INSTALL_DIR"

# ---------- 1. 安装目录 ----------
say_step '1) 检查安装目录与文件'
if [ ! -d "$INSTALL_DIR" ]; then
    say_bad '未找到安装目录（说明安装可能没成功，或装到了别的 macOS 用户下）。'
    say_warn '常见原因：安装时授权窗口里登录的是【另一个管理员账号】，配置写进了那个账号的目录。'
    say_warn '解决办法：用平时登录的账号重新双击 install.command 完整安装一次。'
    say '请把本窗口内容发给开发者。'
    pause_end; exit 1
fi
say "目录存在: $INSTALL_DIR"
for f in "$PROGRAM" config.json password.bin srun_login.log; do
    p="$INSTALL_DIR/$f"
    if [ -f "$p" ]; then
        sz="$(/usr/bin/stat -f '%z' "$p" 2>/dev/null || echo 0)"
        note=''
        if [ "$f" = "$PROGRAM" ] && [ "$sz" -lt 100000 ] && [ ! -x "$p" ]; then note='  <-- 不可执行'; fi
        say "  [存在] $f  (${sz} B)$note"
    else
        say_warn "  [缺失] $f"
    fi
done
exe="$INSTALL_DIR/$PROGRAM"
if [ ! -x "$exe" ]; then
    say_bad "缺少或不可执行主程序 ${exe}，请重跑 install.command 安装。"
    pause_end; exit 1
fi

# ---------- 1.5 自动化任务状态 ----------
say_step '1.5) LaunchAgent 状态（登录 / 每 30 分钟是否真的会触发）'
uid="$(id -u)"
for label in HZAU-AutoLogin HZAU-AutoLogin-Reconnect HZAU-AutoLogin-NetworkChange; do
    plist="$HOME/Library/LaunchAgents/$label.plist"
    if [ ! -f "$plist" ]; then
        say_warn "  [缺失] LaunchAgent $label 不存在 —— 自动认证根本不会被触发！请重新运行 install.command"
        continue
    fi
    /usr/bin/plutil -lint "$plist" >/dev/null 2>&1 \
        && lint='plist 语法 OK' || lint='plist 语法错误!'
    out="$(/bin/launchctl print "gui/$uid/$label" 2>/dev/null)"
    if [ -n "$out" ]; then
        state="$(printf '%s\n' "$out" | /usr/bin/grep -m1 'state =' | /usr/bin/sed 's/^ *//')"
        lastrc="$(printf '%s\n' "$out" | /usr/bin/grep -m1 'last exit status' | /usr/bin/sed 's/^ *//')"
        say "  [已加载] $label | $lint | ${state:-状态未知} | ${lastrc:-上次结果未知}"
    else
        say_warn "  [未加载] $label 的 plist 存在但 launchd 未加载 —— 请重新运行 install.command"
    fi
    beat="$(/usr/bin/plutil -extract StartInterval raw -o - "$plist" 2>/dev/null || true)"
    [ -n "$beat" ] && say "          StartInterval = ${beat}s（约 $((beat / 60)) 分钟）"
done

# ---------- 2. 配置 ----------
say_step '2) 配置内容 config.json'
cfg="$INSTALL_DIR/config.json"
if [ -f "$cfg" ]; then
    if ! /usr/bin/plutil -lint "$cfg" >/dev/null 2>&1; then
        say_bad '  config.json 不是合法 JSON'
    else
        for k in server ac_id username domain max_attempts retry_interval network_wait_seconds repair_interval_seconds; do
            v="$(/usr/bin/plutil -extract "$k" raw -o - "$cfg" 2>/dev/null || echo '(缺失)')"
            say "  $k = ${v:-（空）}"
        done
        user="$(/usr/bin/plutil -extract username raw -o - "$cfg" 2>/dev/null || true)"
        dom="$(/usr/bin/plutil -extract domain raw -o - "$cfg" 2>/dev/null || true)"
        [ -z "$user" ] && say_warn '  username 为空 —— 安装时学号没填上，请重跑 install.command'
        case "$user" in *@*) say_warn '  username 里带了 @xxx —— 应把 @后缀放到 domain 字段' ;; esac
        [ -n "$dom" ] && say_warn "  填了运营商后缀 $dom —— 请确认账号确实是运营商宽带账号"
    fi
else
    say_bad '  config.json 不存在'
fi

# ---------- 3. 钥匙串 ----------
say_step '3) 密码 password.bin 能否用当前用户从钥匙串取回'
if [ -f "$INSTALL_DIR/password.bin" ]; then
    handle="$(hzau_check_password_handle "$INSTALL_DIR")"
    if [ "$handle" = 'OK' ]; then
        if hzau_kc_exists; then
            n="$(hzau_kc_length 2>/dev/null || echo '?')"
            say_ok "  解密成功，密码长度 ${n} 位（不会显示密码本身）"
            [ "$n" = '0' ] && say_warn '  密码为空 —— 请运行 change_password.command 重新填写'
        else
            say_bad '  password.bin 句柄存在，但当前用户登录钥匙串里找不到密码项'
            say_warn '  原因：密码是用【另一个 macOS 用户】保存的，或换过用户 / 钥匙串被重置。'
            say_warn '  解决：用平时登录的账号重跑 install.command（会覆盖安装并重新保存密码）。'
        fi
    else
        say_bad "  $handle"
        say_warn '  解决：重跑 install.command；不要把 Windows 版目录直接拷到 macOS 用。'
    fi
else
    say_warn '  password.bin 不存在 —— 尚未保存过密码，请运行 install.command 或 change_password.command'
fi

# ---------- 4. 本机网络 ----------
say_step '4) 本机网络状态'
say "  网络服务: $(/usr/sbin/networksetup -listallnetworkservices 2>/dev/null | /usr/bin/tail -n +2 | /usr/bin/tr '\n' '|')"
/sbin/ifconfig -a 2>/dev/null | /usr/bin/awk '
    /^[a-z0-9]+:/ { iface=$1; sub(/:$/,"",iface) }
    /inet / { printf "  %-10s %s\n", iface, $2 }
' | /usr/bin/grep -v '127.0.0.1' | while IFS= read -r l; do
    say "$l"
    case "$l" in *169.254.*) say_warn '    警告：IP 为 169.254.x.x（DHCP 失败的自配地址），脚本会一直等待/修复直到超时。' ;; esac
done
gw="$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:/{print $2}')"
iface="$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2}')"
say "  默认路由: ${gw:-（无）}  接口: ${iface:-（无）}"
[ -z "$gw" ] && say_warn '  未找到 IPv4 默认网关 —— 可能没连网，或连的是纯自配地址网络。'
say "  DNS: $(/usr/sbin/scutil --dns 2>/dev/null | /usr/bin/grep -m3 'nameserver\[' | /usr/bin/awk '{print $3}' | /usr/bin/tr '\n' ' ')"

# ---------- 5. 服务器连通性 ----------
say_step '5) 认证服务器连通性 rz.hzau.edu.cn'
dns="$(/usr/bin/dscacheutil -q host -a name rz.hzau.edu.cn 2>/dev/null | /usr/bin/awk '/ip_address:/{print $2}' | /usr/bin/tr '\n' ' ')"
if [ -n "$dns" ]; then say "  DNS 解析: $dns"; else say_warn '  DNS 解析失败 —— 未连校园网？或 DNS 被劫持/拦截。'; fi
if [ -x /usr/bin/nc ] && /usr/bin/nc -z -G 5 rz.hzau.edu.cn 443 >/dev/null 2>&1; then
    say_ok '  TCP 443(https): 可达'
    TCP_OK=1
else
    say_warn '  TCP 443(https): 不可达 / 超时'
    TCP_OK=0
fi

# ---------- 6. 实际运行 ----------
say_step '6) 实际运行一次自动认证'
run=1
if [ "$NO_RUN" -eq 1 ]; then
    run=0; say '  已指定 --no-run，跳过实际运行'
elif [ "$TCP_OK" -ne 1 ]; then
    read -r -p '  服务器 443 不可达，直接运行会等待网络最长约 5 分钟。仍要运行？[Y/N] ' ans || true
    [ "$(printf '%s' "$ans" | tr '[:lower:]' '[:upper:]')" = 'Y' ] || run=0
fi
if [ "$run" -eq 1 ]; then
    say "  正在运行 ${exe}（无窗口；网络不通时最长约 5 分钟，可关闭本窗口中止）..."
    "$exe" >/dev/null 2>&1
    code=$?
    case "$code" in
        0) say_ok  '  退出码: 0 —— 认证成功，或本来就已经在线' ;;
        1) say_warn '  退出码: 1 —— 环境/配置类问题（结合下方日志判断）' ;;
        2) say_bad  '  退出码: 2 —— 认证失败（结合下方日志与「=>」提示判断）' ;;
        *) say "  退出码: ${code}（未知）" ;;
    esac
fi

# ---------- 7. 日志 ----------
say_step '7) 运行日志尾部 srun_login.log'
log="$INSTALL_DIR/srun_login.log"
if [ -f "$log" ]; then
    /usr/bin/tail -n 35 "$log" | while IFS= read -r l; do say "$l"; done
else
    say_warn '  尚无日志文件 —— 程序可能从未成功启动过（或被安全软件拦截）。'
fi

say ''
if [ -f "$REPORT" ]; then
    say_ok "诊断报告已保存: $REPORT"
else
    say_warn '报告写入失败 —— 请直接截图本窗口'
fi
say '请把【本窗口完整内容】或【上面的诊断报告文件】发给开发者，即可定位原因。'
pause_end
exit 0
