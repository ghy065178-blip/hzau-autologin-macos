#!/bin/bash
# 双击卸载（等价 Windows installer/uninstall.bat）
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR" || exit 1
exec /bin/bash "$DIR/install.sh" --uninstall "$@"
