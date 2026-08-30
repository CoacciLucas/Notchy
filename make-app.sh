#!/bin/zsh
# Builds Notchy and wraps the release binary into Notchy.app.
# Usage: ./make-app.sh && open build/Notchy.app   (or NOTCHY_MOCK=1 open ...)
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release

APP=build/Notchy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Notchy "$APP/Contents/MacOS/Notchy"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Notchy</string>
    <key>CFBundleIdentifier</key><string>dev.coacci.Notchy</string>
    <key>CFBundleName</key><string>Notchy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSUIElement</key><true/>   <!-- no Dock icon, no Cmd-Tab -->
</dict>
</plist>
EOF
echo "Built $APP"
