#!/bin/sh
# HZAU-AutoLogin macOS —— 安装特权网络修复助手（必须以 root 执行）
#
# 由 install.sh 通过 osascript「with administrator privileges」调用一次，
# 等价 Windows install.ps1 的 UAC 提权（Start-Process -Verb RunAs）。
#
# 用法（root）：install_privileged_helper.sh <目标用户名> <助手源文件路径>

set -eu

TARGET_USER="$1"
HELPER_SRC="$2"

HELPER_DIR='/Library/PrivilegedHelperTools'
HELPER="$HELPER_DIR/hzau-autologin-network-repair"
SUDOERS='/etc/sudoers.d/hzau-autologin'

[ "$(id -u)" -eq 0 ] || { echo '需要 root 权限' >&2; exit 1; }
[ -f "$HELPER_SRC" ] || { echo "找不到助手源文件: $HELPER_SRC" >&2; exit 1; }

/usr/bin/id -u "$TARGET_USER" >/dev/null 2>&1 || {
    echo "目标用户不存在: $TARGET_USER" >&2; exit 1;
}

/bin/mkdir -p "$HELPER_DIR"
/bin/chmod 0755 "$HELPER_DIR"
/usr/bin/install -o root -g wheel -m 0755 "$HELPER_SRC" "$HELPER"

# 规则只允许当前用户以 root 免密执行这一个固定路径的助手；
# 用户名与路径中若含特殊字符，sudoers 可能校验失败，故先做严格校验。
case "$TARGET_USER" in
    *[!A-Za-z0-9._-]*|'') echo '用户名含 sudoers 不允许的字符' >&2; exit 1 ;;
esac

TMP_SUDOERS="$(/usr/bin/mktemp /tmp/hzau-sudoers.XXXXXX)"
printf '%s\n' "$TARGET_USER ALL=(root) NOPASSWD: $HELPER" > "$TMP_SUDOERS"
if ! /usr/sbin/visudo -cf "$TMP_SUDOERS" >/dev/null 2>&1; then
    /bin/rm -f "$TMP_SUDOERS"
    echo 'sudoers 规则校验失败，未安装' >&2
    exit 1
fi
/bin/cat "$TMP_SUDOERS" > "$SUDOERS"
/bin/rm -f "$TMP_SUDOERS"
/usr/sbin/chown root:wheel "$SUDOERS"
/bin/chmod 0440 "$SUDOERS"

# 文件名不能含「.」：sudo 会跳过 sudoers.d 里带点的文件（见 man sudoers）
case "$(/usr/bin/basename "$SUDOERS")" in
    *.*) echo 'sudoers 文件名含点会被 sudo 忽略' >&2; exit 1 ;;
esac

# 确认系统主 sudoers 确实引入了 /etc/sudoers.d；极少数精简过的系统会缺这一行。
if ! /usr/bin/grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers 2>/dev/null; then
    echo '警告: /etc/sudoers 未引入 /etc/sudoers.d，DHCP 续租助手可能不生效' >&2
    echo '      （不影响开机自动认证；网络修复会按「无管理员权限」降级）' >&2
fi
if ! /usr/sbin/visudo -c >/dev/null 2>&1; then
    /bin/rm -f "$SUDOERS"
    echo 'sudoers 整体校验失败，已回滚规则文件' >&2
    exit 1
fi

echo "已安装特权网络修复助手: $HELPER"
echo "已写入 sudoers 规则: $SUDOERS"
