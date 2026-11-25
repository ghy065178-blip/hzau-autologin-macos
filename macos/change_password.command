#!/bin/bash
# 双击修改校园网密码（等价 Windows installer/change_password.bat）
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR" || exit 1
exec /bin/bash "$DIR/change_password.sh" "$@"
