#!/bin/bash
# HZAU-AutoLogin macOS —— 钥匙串访问共享库（纯 shell，不需要 Python）
#
# 格式约定（必须与 hzau_autologin_macos.py 中的 mac_load_password() 完全一致）：
#   * 钥匙串项：service = HZAU-AutoLogin，account = `id -un`（当前 macOS 用户）
#   * 存入值  ：base64(UTF-8 明文密码) 的 ASCII 字符串（不含换行）
#   * password.bin：base64(JSON 描述符)，只含 service/account/backend，不含机密
#
# 与 Windows DPAPI CurrentUser 的对应关系：
#   DPAPI 密文绑定「本机 + 当前用户」，同用户任意进程可解密；
#   登录钥匙串同样绑定「本机 + 当前用户」，且 -T /usr/bin/security 保证后台
#   LaunchAgent 通过系统自带 security 读取时不会弹出授权框。
#
# 用法：source keychain.sh 之后调用 hzau_kc_save / hzau_kc_load / hzau_kc_delete 等

HZAU_KC_SERVICE="${HZAU_KC_SERVICE:-HZAU-AutoLogin}"
HZAU_KC_LABEL="${HZAU_KC_LABEL:-HZAU Campus Network Password}"
HZAU_KC_ACCOUNT="${HZAU_KC_ACCOUNT:-$(id -un)}"
HZAU_KC_SECURITY='/usr/bin/security'

# 把明文密码转成可安全写入钥匙串的 ASCII 载荷
hzau_kc_payload() {
    printf '%s' "$1" | /usr/bin/base64 | tr -d '\n'
}

# 写入/更新钥匙串项；参数是明文密码（shell 函数内部传参，不会进入外部进程 argv）
# 使用 -X/-w 会把载荷短暂放进 security 进程的 argv，这与 Windows 版 PowerShell
# 通过 .NET ProtectedData.Protect() 传递 SecureString 的暴露面相当。
hzau_kc_save() {
    local payload
    payload="$(hzau_kc_payload "$1")"
    [ -n "$payload" ] || return 1
    "$HZAU_KC_SECURITY" add-generic-password \
        -a "$HZAU_KC_ACCOUNT" \
        -s "$HZAU_KC_SERVICE" \
        -l "$HZAU_KC_LABEL" \
        -T "$HZAU_KC_SECURITY" \
        -U -w "$payload" >/dev/null 2>&1
}

# 读取明文密码到 stdout（不追加换行）；失败返回非 0
hzau_kc_load() {
    local payload
    payload="$("$HZAU_KC_SECURITY" find-generic-password \
        -a "$HZAU_KC_ACCOUNT" -s "$HZAU_KC_SERVICE" -w 2>/dev/null)" || return 1
    [ -n "$payload" ] || return 1
    printf '%s' "$payload" | /usr/bin/base64 -D
}

# 仅用于诊断：返回密码字符数，不输出密码内容
hzau_kc_length() {
    local n
    n="$(hzau_kc_load | LC_ALL=en_US.UTF-8 /usr/bin/wc -m | tr -d ' ')"
    printf '%s' "$n"
}

hzau_kc_exists() {
    "$HZAU_KC_SECURITY" find-generic-password \
        -a "$HZAU_KC_ACCOUNT" -s "$HZAU_KC_SERVICE" >/dev/null 2>&1
}

hzau_kc_delete() {
    "$HZAU_KC_SECURITY" delete-generic-password \
        -a "$HZAU_KC_ACCOUNT" -s "$HZAU_KC_SERVICE" >/dev/null 2>&1
}

# 写 password.bin 句柄（0600）
hzau_write_password_handle() {
    local dir="$1" desc
    desc="{\"backend\":\"keychain\",\"service\":\"$HZAU_KC_SERVICE\",\"account\":\"$HZAU_KC_ACCOUNT\",\"v\":1}"
    printf '%s' "$desc" | /usr/bin/base64 | tr -d '\n' > "$dir/password.bin"
    chmod 600 "$dir/password.bin"
}

# 校验句柄格式（诊断用）：输出 OK 或错误原因
hzau_check_password_handle() {
    local dir="$1" raw
    if [ ! -f "$dir/password.bin" ]; then
        echo 'password.bin 不存在'; return 1
    fi
    raw="$(/usr/bin/base64 -D < "$dir/password.bin" 2>/dev/null)"
    case "$raw" in
        *'"backend":"keychain"'*) echo 'OK' ;;
        *) echo 'password.bin 不是 macOS 钥匙串格式（可能是 Windows 版残留）'; return 1 ;;
    esac
}
