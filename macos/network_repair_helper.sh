#!/bin/sh
# HZAU-AutoLogin macOS —— 特权网络修复助手（以 root 运行）
#
# 由 install_privileged_helper.sh 安装到
#   /Library/PrivilegedHelperTools/hzau-autologin-network-repair  (root:wheel 0755)
# 并配套 /etc/sudoers.d/hzau-autologin 中的一条 NOPASSWD 规则。
#
# 安全约束：
#   * 文件属主 root、目录不可被普通用户写，因此规则不会被用来提权执行任意代码
#   * 只接受三个固定动作，不接收用户可控的接口名/命令串
#   * 不做任何与网络修复无关的操作
#
# 等价 Windows：ipconfig /flushdns、/release、/renew（需要管理员/最高运行级别）
# macOS 上 `ipconfig set` 需要 root（见 man ipconfig），且只建立临时服务，
# 恰好适合「一次性重新发起 DHCP」，不会改动持久网络配置。

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

action="${1:-}"

primary_iface() {
    /sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}'
}

# 把接口名（如 en0）映射到 networksetup 的服务名（如 Wi-Fi）
service_for_iface() {
    [ -n "$1" ] || return 0
    /usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null | /usr/bin/awk -v dev="$1" '
        /^\([0-9]+\) / { svc = $0; sub(/^\([0-9]+\) /, "", svc); next }
        /Hardware Port:/ { if (index($0, "Device: " dev ")")) { print svc; exit } }
    '
}

case "$action" in
    flushdns)
        # 用户态 dscacheutil -flushcache 由主程序执行；这里补 mDNSResponder 的 HUP（需 root）
        /usr/bin/dscacheutil -flushcache 2>/dev/null
        /usr/bin/killall -HUP mDNSResponder 2>/dev/null
        exit 0
        ;;
    release)
        iface="$(primary_iface)"
        if [ -n "$iface" ]; then
            /usr/sbin/ipconfig set "$iface" NONE 2>/dev/null
        fi
        exit 0
        ;;
    renew)
        iface="$(primary_iface)"
        if [ -n "$iface" ]; then
            if ! /usr/sbin/ipconfig set "$iface" DHCP 2>/dev/null; then
                svc="$(service_for_iface "$iface")"
                [ -n "$svc" ] && /usr/sbin/networksetup -setdhcp "$svc" 2>/dev/null
            fi
        fi
        exit 0
        ;;
    *)
        echo "usage: hzau-autologin-network-repair {flushdns|release|renew}" >&2
        exit 2
        ;;
esac
