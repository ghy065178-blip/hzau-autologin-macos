#!/bin/bash
# HZAU-AutoLogin macOS 版 —— 一键验证（静态检查 + 离线功能测试 + 脚本 dry-run）
#
# 全程不联网认证、不注册 LaunchAgent、不安装特权助手、不改动真实钥匙串密码项。
# 用法： bash macos/tests/verify.sh

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS="$ROOT/macos"
PY="${PYTHON:-python3}"
FAIL=0
PASS=0

ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
step() { printf '\n=== %s ===\n' "$*"; }
has()  { command -v "$1" >/dev/null 2>&1; }

step '0) 环境'
printf '  macOS %s / %s / python %s\n' \
    "$(sw_vers -productVersion 2>/dev/null)" "$(uname -m)" "$($PY --version 2>&1)"
has /usr/bin/security && ok 'security 可用' || bad '缺少 security'
has /usr/bin/plutil   && ok 'plutil 可用'   || bad '缺少 plutil'
has /bin/launchctl    && ok 'launchctl 可用' || bad '缺少 launchctl'
has /usr/bin/osascript && ok 'osascript 可用' || bad '缺少 osascript'

step '1) Python 语法编译'
while IFS= read -r f; do
    if "$PY" -m py_compile "$f" 2>/dev/null; then ok "$f"; else bad "$f"; fi
done < <(/usr/bin/find "$ROOT" -name '*.py' -type f -not -path '*/.build-venv/*' -not -path '*/dist/*')

step '2) Shell 语法检查（macOS 自带 bash 3.2）'
while IFS= read -r f; do
    if /bin/bash -n "$f" 2>/dev/null; then ok "$f"; else bad "$f: $(/bin/bash -n "$f" 2>&1 | head -2)"; fi
done < <(/usr/bin/find "$MACOS" -type f \( -name '*.sh' -o -name '*.command' \))

step '3) LaunchAgent plist 模板校验'
for p in "$MACOS"/launchd/*.plist; do
    if /usr/bin/plutil -lint "$p" >/dev/null 2>&1; then ok "$(basename "$p")"; else bad "$(basename "$p")"; fi
done

step '4) 安装器 dry-run（不写入任何文件/系统配置）'
# 用隔离的、尚不存在的安装目录做检查，避免与用户已真实安装的目录互相干扰
DRY_TMP="$(/usr/bin/mktemp -d /tmp/hzau-dryrun.XXXXXX)"
DRY_TARGET="$DRY_TMP/HZAU-AutoLogin"
DRY_OUT="$(/bin/bash "$MACOS/install.sh" --dry-run --silent --no-download \
    --no-network-repair --install-dir "$DRY_TARGET" \
    --username 20210001 --password 'unit-test-pw' 2>&1)"
DRY_RC=$?
[ "$DRY_RC" -eq 0 ] && ok 'install.sh --dry-run 退出码 0' || bad "install.sh --dry-run 退出码 $DRY_RC"
printf '%s\n' "$DRY_OUT" | /usr/bin/grep -q 'RunAtLoad' && ok '生成了登录任务 plist' || bad '登录任务 plist 未生成'
printf '%s\n' "$DRY_OUT" | /usr/bin/grep -q 'StartInterval' && ok '生成了巡检任务 plist' || bad '巡检任务 plist 未生成'
printf '%s\n' "$DRY_OUT" | /usr/bin/grep -q 'WatchPaths' && ok '生成了网络变化触发 plist' || bad '网络变化触发 plist 未生成'
printf '%s\n' "$DRY_OUT" | /usr/bin/grep -q '"server": "https://rz.hzau.edu.cn"' \
    && ok 'config.json 字段与原版一致' || bad 'config.json 字段不一致'
[ ! -d "$DRY_TARGET" ] \
    && ok 'dry-run 未创建安装目录' || bad 'dry-run 意外创建了安装目录'

UNI_OUT="$(/bin/bash "$MACOS/install.sh" --dry-run --silent --uninstall \
    --install-dir "$DRY_TARGET" 2>&1)"
[ $? -eq 0 ] && ok 'install.sh --dry-run --uninstall 退出码 0' || bad '卸载 dry-run 失败'
/bin/rm -rf "$DRY_TMP"
unset DRY_OUT UNI_OUT

step '5) 离线端到端协议测试（本地假门户，服务端独立重算 hmd5/chksum）'
if "$PY" "$MACOS/tests/test_offline.py" > /tmp/hzau-offline-test.log 2>&1; then
    ok 'test_offline.py 全部通过 (10 项)'
else
    bad 'test_offline.py 失败'; /usr/bin/tail -30 /tmp/hzau-offline-test.log
fi

step '6) 钥匙串跨语言一致性测试（shell 写入 / Python 读取）'
if "$PY" "$MACOS/tests/test_keychain.py" > /tmp/hzau-keychain-test.log 2>&1; then
    ok 'test_keychain.py 全部通过 (3 项)'
else
    bad 'test_keychain.py 失败'; /usr/bin/tail -30 /tmp/hzau-keychain-test.log
fi

step '6b) PyInstaller 冻结二进制端到端（已构建时执行，否则跳过）'
if [ -x "$ROOT/dist/hzau-autologin" ]; then
    if "$PY" "$MACOS/tests/test_frozen_binary.py" > /tmp/hzau-frozen-test.log 2>&1; then
        ok 'frozen 二进制完整认证流程（sys.frozen 路径 + 钥匙串 + 协议）'
        /usr/bin/tail -2 /tmp/hzau-frozen-test.log
    else
        bad 'frozen 二进制测试失败'; /usr/bin/tail -30 /tmp/hzau-frozen-test.log
    fi
else
    printf '  [SKIP] 尚无 dist/hzau-autologin，运行 bash macos/build.sh 后可补测\n'
fi

step '7) 诊断脚本功能冒烟（隔离的临时安装目录，不发起认证）'
FAKE="$(/usr/bin/mktemp -d /tmp/hzau-diag-smoke.XXXXXX)"
/bin/cat > "$FAKE/config.json" <<'JSON'
{
  "server": "https://rz.hzau.edu.cn",
  "ac_id": "5",
  "username": "20210001",
  "domain": "",
  "max_attempts": 3,
  "retry_interval": 3,
  "network_wait_seconds": 300,
  "repair_interval_seconds": 60
}
JSON
printf '%s' "$(printf '%s' '{"backend":"keychain","service":"HZAU-AutoLogin-VERIFY","account":"nobody","v":1}' | /usr/bin/base64 | tr -d '\n')" > "$FAKE/password.bin"
printf '%s\n' '2026-01-01 00:00:00 当前已在线，无需认证' > "$FAKE/srun_login.log"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/hzau-autologin"; /bin/chmod +x "$FAKE/hzau-autologin"
DIAG="$(/bin/bash "$MACOS/diagnose.sh" --install-dir "$FAKE" --no-run < /dev/null 2>&1)"
DIAG_RC=$?
[ "$DIAG_RC" -eq 0 ] && ok 'diagnose.sh 退出码 0' || bad "diagnose.sh 退出码 $DIAG_RC"
printf '%s\n' "$DIAG" | /usr/bin/grep -q '2) 配置内容' && ok '诊断章节 2（配置）' || bad '缺少配置章节'
printf '%s\n' "$DIAG" | /usr/bin/grep -q '3) 密码' && ok '诊断章节 3（钥匙串）' || bad '缺少钥匙串章节'
printf '%s\n' "$DIAG" | /usr/bin/grep -q '1.5) LaunchAgent' && ok '诊断章节 1.5（自动化任务）' || bad '缺少任务章节'
printf '%s\n' "$DIAG" | /usr/bin/grep -q '7) 运行日志' && ok '诊断章节 7（日志尾部）' || bad '缺少日志章节'
/bin/rm -rf "$FAKE"

step '8) 改密脚本功能冒烟（一次性独立钥匙串项，用后即删）'
PWDIR="$(/usr/bin/mktemp -d /tmp/hzau-pw-smoke.XXXXXX)"
/bin/cp -f "$ROOT/config.example.json" "$PWDIR/config.json"
KCSVC="HZAU-AutoLogin-VERIFY-$$"
HZAU_KC_SERVICE="$KCSVC" HZAU_KC_ACCOUNT="$(id -un)" \
    /bin/bash "$MACOS/change_password.sh" --install-dir "$PWDIR" \
        --password 'new-test-password' --silent >/tmp/hzau-pw-test.log 2>&1
PW_RC=$?
[ "$PW_RC" -eq 0 ] && ok 'change_password.sh 退出码 0' || { bad "退出码 $PW_RC"; /usr/bin/cat /tmp/hzau-pw-test.log; }
[ -f "$PWDIR/password.bin" ] && ok '已重写 password.bin 句柄' || bad '句柄未生成'
GOT="$(/usr/bin/security find-generic-password -a "$(id -un)" -s "$KCSVC" -w 2>/dev/null | /usr/bin/base64 -D)"
[ "$GOT" = 'new-test-password' ] && ok '钥匙串内容与新密码一致' || bad "读回内容不符: [$GOT]"
/usr/bin/security delete-generic-password -a "$(id -un)" -s "$KCSVC" >/dev/null 2>&1 || true
/bin/rm -rf "$PWDIR"

step '9) 确认上游 Windows 文件未被修改'
if has git && [ -d "$ROOT/.git" ]; then
    CHANGED="$(cd "$ROOT" && git status --porcelain -- srun_login.py build.ps1 installer .github/workflows/release.yml config.example.json README.md TUTORIAL.md docs 2>/dev/null)"
    if [ -z "$CHANGED" ]; then ok 'srun_login.py / installer / release.yml / 配置样例 均未改动'; else bad "检测到改动: $CHANGED"; fi
else
    ok '跳过（非 git 工作副本）'
fi

printf '\n========================================\n'
printf '验证结果: %d 项通过, %d 项失败\n' "$PASS" "$FAIL"
printf '========================================\n'
[ "$FAIL" -eq 0 ] || exit 1
exit 0
