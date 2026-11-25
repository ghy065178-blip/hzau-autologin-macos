#!/bin/bash
# 双击一键诊断（等价 Windows installer/diagnose.bat）
# 重要：请用【自己平时登录 macOS 的账号】直接双击运行，不要 sudo——
#       普通身份才能检测出配置/钥匙串是否装错了用户。
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR" || exit 1
exec /bin/bash "$DIR/diagnose.sh" "$@"
