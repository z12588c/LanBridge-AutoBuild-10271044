#!/data/data/com.termux/files/usr/bin/bash
set -e

echo "========================================================"
echo "🚀 [1/3] 检查 GitHub 登录状态..."
echo "========================================================"
if ! gh auth status >/dev/null 2>&1; then
    echo "👉 请按提示复制 8 位验证码，在浏览器中打开 https://github.com/login/device 完成授权："
    gh auth login -p https -w
fi

echo "========================================================"
echo "📦 [2/3] 初始化 Git 仓库并一键推送到 GitHub..."
echo "========================================================"
rm -rf .git
git init -b main
git config user.name "LanBridgeBuilder"
git config user.email "builder@users.noreply.github.com"
git add -A
git commit -m "chore: initial commit for LanBridge EXE & APK cloud build"

REPO_NAME="LanBridge-AutoBuild-$(date +%m%d%H%M)"
gh repo create "$REPO_NAME" --public --source=. --remote=origin --push

echo "========================================================"
echo "🎉 [3/3] 已成功推送至 GitHub 仓库：$REPO_NAME"
echo "⏳ GitHub Actions 正在云端并行编译 EXE 与 APK（约需 3~5 分钟）"
echo "========================================================"
echo "💡 编译完成后，执行以下命令即可把 APK 和 EXE 下载到手机 Download 目录："
echo "   gh run watch && gh run download -D /sdcard/Download/LanBridge_Release"
