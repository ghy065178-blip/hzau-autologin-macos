#!/bin/bash
# HZAU-AutoLogin macOS —— 本地构建二进制与分发 zip
# 等价 Windows build.ps1；差异见 macos/README.md「打包差异」一节。
#
# 用法： bash macos/build.sh [--python <python3 路径>] [--version <标签>] [--arch <x86_64|arm64|universal2>]
# 产物： dist/hzau-autologin                       （无扩展名的 Unix 可执行）
#        dist/hzau-autologin-<version>-macos-<arch>.zip
#        dist/...zip.sha256

set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON=''
VERSION="$(cd "$ROOT" && git describe --tags --always 2>/dev/null || echo dev)"
ARCH="$(uname -m)"
TARGET_ARCH=''
CLEAN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --python|-Python) PYTHON="${2:-}"; shift 2 ;;
        --version)        VERSION="${2:-}"; shift 2 ;;
        --arch)           TARGET_ARCH="${2:-}"; shift 2 ;;
        --clean)          CLEAN=1; shift ;;
        --help|-h) echo '用法: build.sh [--python <path>] [--version <tag>] [--arch <arch>] [--clean]'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$PYTHON" ]; then
    for p in python3.13 python3.12 python3.11 python3.10 python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if command -v "$p" >/dev/null 2>&1; then PYTHON="$(command -v "$p")"; break; fi
    done
fi
[ -n "$PYTHON" ] || { echo '未找到 python3，请用 --python 指定' >&2; exit 1; }
"$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' \
    || { echo '需要 Python 3.8+' >&2; exit 1; }

VENV="$SCRIPT_DIR/.build-venv"
echo "==> 准备构建环境: $VENV (Python: $PYTHON)"
if [ ! -x "$VENV/bin/python" ]; then
    "$PYTHON" -m venv "$VENV"
fi
PY="$VENV/bin/python"
"$PY" -m pip install --quiet --upgrade pip pyinstaller

echo '==> 打包 hzau_autologin_macos.py（复用原版 srun_login.py，不改动它）'
cd "$ROOT"
# 把 PyInstaller 的二进制缓存（含 ad-hoc 重签名）留在项目 dist/ 内，
# 避免它去改写用户 ~/Library/Application Support/pyinstaller 下的缓存文件。
CONFIG_DIR="$ROOT/dist/.pyinstaller-config"
/bin/mkdir -p "$CONFIG_DIR"
export PYINSTALLER_CONFIG_DIR="$CONFIG_DIR"
# 说明：
#   * Windows 用 --noconsole 生成无窗口 GUI 子系统 exe；macOS 上 --noconsole 等价于
#     --windowed，会生成 .app bundle，不适合 launchd 直接调用。这里生成纯命令行二进制，
#     由 LaunchAgent 启动，天然无窗口、无 Dock 图标。
#   * --paths 让 PyInstaller 找到仓库根目录的 srun_login.py 与 macos/ 下的适配层。
build_pyinstaller() {
    "$PY" -m PyInstaller \
        --onefile --noupx \
        --name hzau-autologin \
        --exclude-module tkinter \
        --hidden-import srun_login \
        --paths "$ROOT" --paths "$SCRIPT_DIR" \
        "$@" "$SCRIPT_DIR/hzau_autologin_macos.py"
}
# bash 3.2 在 set -u 下不允许展开空数组，因此用函数 + "$@" 传可选参数。
# --clean 默认关闭：它会删除 ~/Library/Application Support/pyinstaller 下大量缓存文件，
# 在受管环境里可能触发批量删除保护；需要彻底重建时用 --clean 显式开启。
if [ "$CLEAN" -eq 1 ] && [ -n "$TARGET_ARCH" ]; then
    build_pyinstaller --clean --target-architecture "$TARGET_ARCH"
elif [ "$CLEAN" -eq 1 ]; then
    build_pyinstaller --clean
elif [ -n "$TARGET_ARCH" ]; then
    build_pyinstaller --target-architecture "$TARGET_ARCH"
else
    build_pyinstaller
fi

BIN="$ROOT/dist/hzau-autologin"
[ -f "$BIN" ] || { echo "打包失败：未找到 $BIN" >&2; exit 1; }
chmod 0755 "$BIN"
# Apple Silicon 要求可执行文件有签名；开发分发用 ad-hoc 签名即可，
# 同时清除隔离属性，避免 Gatekeeper 把未签名程序直接拦下。
/usr/bin/codesign --force --sign - "$BIN" 2>/dev/null || true
/usr/bin/xattr -cr "$BIN" 2>/dev/null || true
/usr/bin/codesign --verify "$BIN" 2>/dev/null && echo '  签名: ad-hoc OK' || echo '  签名: 未签（Intel Mac 可运行）'

echo '==> 组装发布包'
BUILD_ARCH="$TARGET_ARCH"
[ -n "$BUILD_ARCH" ] || BUILD_ARCH="$ARCH"
ZIPNAME="hzau-autologin-$VERSION-macos-$BUILD_ARCH.zip"
STAGING="$ROOT/dist/macos-staging"
/bin/rm -rf "$STAGING"
/bin/mkdir -p "$STAGING/launchd"

/bin/cp -f "$BIN" "$STAGING/hzau-autologin"
for f in install.sh install.command uninstall.command \
         change_password.sh change_password.command \
         diagnose.sh diagnose.command \
         keychain.sh network_repair_helper.sh install_privileged_helper.sh \
         hzau_autologin_macos.py; do
    if [ -f "$SCRIPT_DIR/$f" ]; then /bin/cp -f "$SCRIPT_DIR/$f" "$STAGING/$f"; fi
done
# 面向同学的使用说明作为分发包主 README；平台差异/验证文档另附
if [ -f "$ROOT/README.md" ]; then /bin/cp -f "$ROOT/README.md" "$STAGING/README.md"; fi
if [ -f "$SCRIPT_DIR/README.md" ]; then /bin/cp -f "$SCRIPT_DIR/README.md" "$STAGING/DEVELOPER.md"; fi
/bin/cp -f "$SCRIPT_DIR/launchd/"*.plist "$STAGING/launchd/"
/bin/cp -f "$ROOT/srun_login.py" "$STAGING/srun_login.py"
/bin/cp -f "$ROOT/config.example.json" "$STAGING/config.example.json"
if [ -f "$ROOT/TUTORIAL.md" ]; then /bin/cp -f "$ROOT/TUTORIAL.md" "$STAGING/TUTORIAL.md"; fi

/bin/chmod 0755 "$STAGING/hzau-autologin" "$STAGING/"*.command "$STAGING/"*.sh
/usr/bin/xattr -cr "$STAGING" 2>/dev/null || true

ZIP="$ROOT/dist/$ZIPNAME"
/bin/rm -f "$ZIP" "$ZIP.sha256"
( cd "$ROOT/dist/macos-staging" && /usr/bin/zip -q -r -X "$ZIP" . )
HASH="$(/usr/bin/shasum -a 256 "$ZIP" | /usr/bin/awk '{print $1}')"
printf '%s  %s\n' "$HASH" "$ZIPNAME" > "$ZIP.sha256"

cat <<DONE

打包完成：
  $BIN
  $ZIP
  SHA256: $HASH

把 zip 发给同学即可：解压 -> 双击 install.command -> 输入学号和密码。
架构: ${BUILD_ARCH}（在对应架构的 Mac 上构建，或用 --arch universal2 配合 universal2 Python）
DONE
