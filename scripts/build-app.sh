#!/bin/bash
# Builds MultiAudio.app into ./build. Usage: scripts/build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product MultiAudio
BIN="$(swift build -c release --show-bin-path)/MultiAudio"

APP=build/MultiAudio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MultiAudio"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.aychar.multiaudio</string>
    <key>CFBundleName</key><string>MultiAudio</string>
    <key>CFBundleDisplayName</key><string>MultiAudio</string>
    <key>CFBundleExecutable</key><string>MultiAudio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>MultiAudio captures system audio so it can play it on several speakers at once.</string>
    <key>NSLocalNetworkUsageDescription</key><string>MultiAudio finds and streams to AirPlay speakers on your network.</string>
    <key>NSBonjourServices</key><array><string>_airplay._tcp</string><string>_raop._tcp</string></array>
</dict>
</plist>
PLIST

# Sign with the stable local identity if present (keeps macOS permissions across rebuilds),
# otherwise ad-hoc. Create it with scripts/make-signing-identity.sh.
KC="$HOME/Library/Application Support/MultiAudioSigning/signing.keychain-db"
IDENTITY=""
if [[ -f "$KC" ]]; then
    security unlock-keychain -p multiaudio "$KC"
    IDENTITY=$(security find-identity -p codesigning "$KC" | awk '/MultiAudio Local Signing/ {print $2; exit}')
fi
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" --keychain "$KC" --timestamp=none "$APP"
else
    echo "warning: no local signing identity; using ad-hoc (permissions reset on each build)"
    codesign --force --sign - --timestamp=none "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x MultiAudio 2>/dev/null || true
    rm -rf /Applications/MultiAudio.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/MultiAudio.app"
fi
