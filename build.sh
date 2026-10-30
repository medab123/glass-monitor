#!/bin/zsh
# Builds Glass Monitor and installs it to ~/Applications, then (re)launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/Glass Monitor.app"
pkill -x GlassMonitor 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 Sources/*.swift -o "$APP/Contents/MacOS/GlassMonitor"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Glass Monitor</string>
    <key>CFBundleIdentifier</key><string>com.elabidi.glassmonitor</string>
    <key>CFBundleExecutable</key><string>GlassMonitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
# With "Open at Login" on, restart through the login agent so crash auto-restart stays active.
LOGIN="gui/$(id -u)/com.elabidi.glassmonitor.login"
if launchctl print "$LOGIN" >/dev/null 2>&1; then launchctl kickstart -k "$LOGIN"; else open "$APP"; fi
echo "Installed and launched: $APP"
