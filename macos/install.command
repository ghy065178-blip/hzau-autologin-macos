#!/bin/bash
# 双击安装（等价 Windows installer/install.bat）
# Finder 双击 .command 会自动打开「终端」并以当前用户执行；不需要管理员权限，
# 只有在安装「特权网络修复助手」时才会弹一次系统授权框（等价 UAC）。
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR" || exit 1
exec /bin/bash "$DIR/install.sh" "$@"
