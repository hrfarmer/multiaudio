#!/bin/bash
# Builds build/MultiAudioDevice.driver. Add --install to copy it into the system plug-in
# folder and restart coreaudiod: needs an admin password and briefly cuts all audio.
set -euo pipefail
cd "$(dirname "$0")/.."

DRIVER=build/MultiAudioDevice.driver
rm -rf "$DRIVER"
mkdir -p "$DRIVER/Contents/MacOS"
clang -O2 -Wall -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=27.0 -fvisibility=hidden \
    -framework CoreAudio -framework CoreFoundation \
    -o "$DRIVER/Contents/MacOS/MultiAudioDevice" Driver/MultiAudioDevice.c

cat > "$DRIVER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>MultiAudioDevice</string>
    <key>CFBundleIdentifier</key><string>dev.aychar.multiaudio.device</string>
    <key>CFBundleName</key><string>MultiAudioDevice</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFPlugInFactories</key>
    <dict>
        <key>7C1F8E0A-3B52-4E6D-9A14-2D6F0B8C5E31</key><string>MultiAudioDevice_Create</string>
    </dict>
    <key>CFPlugInTypes</key>
    <dict>
        <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>
        <array><string>7C1F8E0A-3B52-4E6D-9A14-2D6F0B8C5E31</string></array>
    </dict>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$DRIVER"
echo "Built $DRIVER"

if [[ "${1:-}" == "--install" ]]; then
    HAL=/Library/Audio/Plug-Ins/HAL
    sudo rm -rf "$HAL/MultiAudioDevice.driver"
    sudo cp -R "$DRIVER" "$HAL/"
    sudo chown -R root:wheel "$HAL/MultiAudioDevice.driver"
    sudo killall coreaudiod
    echo "Installed. Choose MultiAudio in the Sound menu to use it."
elif [[ "${1:-}" == "--uninstall" ]]; then
    sudo rm -rf /Library/Audio/Plug-Ins/HAL/MultiAudioDevice.driver
    sudo killall coreaudiod
    echo "Removed."
fi
