#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/claude-usage"
PLIST="$HOME/Library/LaunchAgents/com.claude-usage-bar.plist"

if [ ! -f "$BINARY" ]; then
    echo "Building..."
    swiftc "$SCRIPT_DIR/app.swift" -o "$BINARY"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude-usage-bar</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/claude-usage-bar.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-usage-bar.log</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "Installed and started. Check your menu bar."
