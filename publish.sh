#!/bin/bash
# HZAU 校园网自动认证 macOS 版 —— 一键发布到自己的 GitHub
#
# 用法： ./publish.sh <GitHub用户名> [仓库名] [版本号]
# 示例： ./publish.sh ghy065178-blip hzau-autologin-macos v1.2.0
#
# 前置条件（必须先在自己的终端完成，Agent 无法代做交互式登录）：
#   gh auth login            # 按提示选择 GitHub.com / HTTPS / 浏览器登录
#   gh auth status           # 确认显示 Logged in to github.com account <用户名>
#
# 本脚本只做：创建公开仓库 -> 推送 main -> 创建 Release 并上传 arm64 包与 SHA256。
# 不会修改任何本地源码，也不会上传 config.json / password.bin / 日志。

set -euo pipefail
cd "$(dirname "$0")"

OWNER="${1:-}"
REPO="${2:-hzau-autologin-macos}"
VERSION="${3:-v1.2.0}"

if [ -z "$OWNER" ]; then
    echo '用法: ./publish.sh <GitHub用户名> [仓库名] [版本号]' >&2
    exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
    echo '未安装 GitHub CLI，请先 brew install gh' >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo 'GitHub 未登录或凭据失效，请先在终端执行: gh auth login' >&2
    exit 1
fi
# 防止误用旧账号（例如账号被暂停、或 keyring 里残留其他账号的 token）
CURRENT="$(gh api user --jq '.login' 2>/dev/null || true)"
if [ -z "$CURRENT" ]; then
    echo '无法读取当前登录账号（可能账号被暂停或 token 失效），请先执行: gh auth login' >&2
    exit 1
fi
if [ "$CURRENT" != "$OWNER" ]; then
    echo "当前登录账号是 $CURRENT，但目标账号是 $OWNER。" >&2
    echo '请先执行: gh auth login（选择 GitHub.com / HTTPS / 浏览器登录，用新账号授权）' >&2
    exit 1
fi
echo "==> 已确认登录账号: $CURRENT"

ASSETS=(dist/hzau-autologin-"$VERSION"-macos-arm64.zip \
        dist/hzau-autologin-"$VERSION"-macos-arm64.zip.sha256)
for a in "${ASSETS[@]}"; do
    [ -f "$a" ] || { echo "缺少发布资产: $a（先运行 bash macos/build.sh --version $VERSION）" >&2; exit 1; }
done

echo "==> 目标: https://github.com/$OWNER/$REPO  ($VERSION, public)"

if gh repo view "$OWNER/$REPO" >/dev/null 2>&1; then
    echo '==> 仓库已存在，改用推送到现有仓库'
    if git remote get-url origin >/dev/null 2>&1; then
        git remote set-url origin "https://github.com/$OWNER/$REPO.git"
    else
        git remote add origin "https://github.com/$OWNER/$REPO.git"
    fi
    git push -u origin main
else
    echo '==> 创建公开仓库并推送'
    gh repo create "$OWNER/$REPO" --public --source=. --remote=origin --push \
        --description '华中农业大学校园网自动认证 macOS 版 | 开机静默认证、断线重连、钥匙串加密'
fi

echo '==> 创建 Release 并上传资产'
NOTES="$(mktemp /tmp/hzau-release-notes.XXXXXX)"
cat > "$NOTES" <<EOF
## 安装（macOS）

1. 下载 \`hzau-autologin-$VERSION-macos-arm64.zip\` 并解压（Apple Silicon；Intel Mac 请看仓库 README）
2. 双击 \`install.command\`，按提示输入学号和校园网密码
3. 首次会弹出一次系统授权框（用于安装网络修复助手），输入本机密码即可
4. 完成。以后登录 macOS 自动认证，每 30 分钟巡检，网络变化时立即补认证

> 若提示「来自身份不明的开发者」，右键文件选「打开」，或执行 \`xattr -cr <解压目录>\`。

功能、配置项与交互流程详见仓库 README。
EOF

gh release create "$VERSION" "${ASSETS[@]}" \
    --repo "$OWNER/$REPO" --target main \
    --title "HZAU 校园网自动认证 macOS 版 $VERSION" \
    --notes-file "$NOTES"
rm -f "$NOTES"

echo ''
echo "完成: https://github.com/$OWNER/$REPO"
echo "Release: https://github.com/$OWNER/$REPO/releases/tag/$VERSION"
echo ''
echo '提示: 推送 v* tag 会触发 .github/workflows/release-macos.yml，'
echo '      CI 构建的包会追加到同一个 Release（可用于补齐 Intel 版）；'
echo '      如不需要，可在 GitHub 仓库的 Actions 页面禁用该工作流。'
