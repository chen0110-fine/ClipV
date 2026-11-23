#!/bin/zsh
set -euo pipefail

REPO="chen0110-fine/ClipV"
APP_PATH="/Applications/ClipV.app"
PLIST_PATH="$HOME/Library/LaunchAgents/io.github.chen0110.clipv.plist"

echo "正在下载最新版 ClipV..."
ZIP_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | python3 -c "import sys, json; assets = json.load(sys.stdin)['assets']; print(next(a['browser_download_url'] for a in assets if a['name'].endswith('.zip')))")

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fL "$ZIP_URL" -o "$TMP_DIR/ClipV.zip"
ditto -x -k "$TMP_DIR/ClipV.zip" "$TMP_DIR"

echo "正在安装到 /Applications/ClipV.app..."
launchctl unload "$PLIST_PATH" 2>/dev/null || true
pkill -x ClipV 2>/dev/null || true
rm -rf "$APP_PATH"
cp -R "$TMP_DIR/ClipV.app" "$APP_PATH"
xattr -cr "$APP_PATH"

echo "正在配置开机自动启动..."
mkdir -p "$HOME/Library/LaunchAgents"
cat <<EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.chen0110.clipv</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/ClipV.app/Contents/MacOS/ClipV</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

launchctl load -w "$PLIST_PATH"
echo "✅ ClipV 安装并启动成功！按 Option + V (⌥V) 即可呼出面板。"
echo "提示：首次使用请按 ⌥V 后点击左下角「开启辅助功能以自动粘贴」授予权限。"
