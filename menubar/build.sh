#!/bin/bash
# Builds ClaudeSessions.app into ~/Applications and launches it.
#
# The app is signed ad-hoc (`--sign -`). That signature is only valid on the
# machine that produced it, which is exactly why this builds from source
# instead of shipping a binary: no Apple Developer account, no notarization,
# and Gatekeeper never blocks it.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/ClaudeSessions.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found." >&2
  echo "Install the Xcode command line tools first:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

# Quit a previous copy, otherwise the running binary is replaced underneath it.
pkill -x ClaudeSessions 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library -O \
  -o "$APP/Contents/MacOS/ClaudeSessions" \
  "$SRC/ClaudeSessions.swift"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClaudeSessions</string>
  <key>CFBundleIdentifier</key><string>com.ksv.claudesessions</string>
  <key>CFBundleName</key><string>ClaudeSessions</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built $APP"

if [ "${1:-}" = "--launch" ]; then
  open "$APP"
  echo "launched. Look for the indicator in your menu bar."
fi
