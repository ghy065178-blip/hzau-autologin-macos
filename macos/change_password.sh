#!/bin/bash
# HZAU-AutoLogin macOS —— 只重置校园网密码，不重装
# 等价 Windows installer/change_password.ps1 + change_password.bat
#
# 用法：双击 change_password.command
#      或 bash change_password.sh [--password <新密码>] [--silent] [--install-dir <路径>]

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=keychain.sh
. "$DIR/keychain.sh"

INSTALL_DIR="$HOME/Library/Application Support/HZAU-AutoLogin"
PROGRAM='hzau-autologin'
SILENT=0
PASSWORD=''

while [ $# -gt 0 ]; do
    case "$1" in
        --install-dir|-InstallDir) INSTALL_DIR="${2:-}"; shift 2 ;;
        --password|-Password)      PASSWORD="${2:-}"; shift 2 ;;
        --silent|-Silent)          SILENT=1; shift ;;
        --help|-h) echo '用法: change_password.sh [--password <新密码>] [--silent] [--install-dir <路径>]'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

pause_end() { [ "$SILENT" -eq 1 ] || { printf '\n'; read -r -p '按回车键关闭窗口...' _ || true; }; }
fail() { printf '失败: %s\n' "$*" >&2; pause_end; exit 1; }

if [ ! -f "$INSTALL_DIR/config.json" ]; then
    fail "未找到安装目录 ${INSTALL_DIR}（缺 config.json），请先运行 install.command 完成安装"
fi

if [ -z "$PASSWORD" ]; then
    [ "$SILENT" -eq 0 ] || fail '静默模式必须通过 --password 传入密码'
    read -r -s -p '请输入新的校园网密码: ' PASSWORD || true
    printf '\n'
fi
[ -n "$PASSWORD" ] || fail '密码不能为空'

hzau_kc_save "$PASSWORD" || fail '写入登录钥匙串失败（登录钥匙串可能被锁定）'
hzau_write_password_handle "$INSTALL_DIR" || fail '写入 password.bin 句柄失败'

printf '新密码已加密保存（macOS 钥匙串）: %s/password.bin 句柄\n' "$INSTALL_DIR"
printf '下次登录认证或周期巡检即会使用新密码。\n'

if [ "$SILENT" -eq 0 ]; then
    exe="$INSTALL_DIR/$PROGRAM"
    read -r -p '是否立即用新密码认证一次？[Y/N] ' go || true
    if [ "$(printf '%s' "$go" | tr '[:lower:]' '[:upper:]')" = 'Y' ] && [ -x "$exe" ]; then
        "$exe" >/dev/null 2>&1 || true
        log="$INSTALL_DIR/srun_login.log"
        if [ -f "$log" ]; then
            printf '\n--- 最近日志 ---\n'
            /usr/bin/tail -n 8 "$log"
        fi
    fi
fi
pause_end
exit 0
