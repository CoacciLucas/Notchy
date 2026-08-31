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
mkdir -p "$APP/Contents/Resources"
cp -R .build/release/Notchy_Notchy.bundle "$APP/Contents/Resources/"

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
# Sign with a stable identity. Ad-hoc signing (the SwiftPM default) puts a
# per-build cdhash in the Keychain item's ACL, so "Always Allow" is invalidated
# by every rebuild and macOS re-prompts for the login password.
IDENTITY="${NOTCHY_SIGN_IDENTITY:-Notchy Self-Signed}"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "WARN: no '$IDENTITY' signing identity — see README; the Keychain" >&2
    echo "      will re-prompt after every rebuild." >&2
fi

echo "Built $APP"
