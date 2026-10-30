#!/bin/zsh
# Builds Kuk.app next to this script. Usage: ./build.sh [--install]
set -euo pipefail
cd "${0:A:h}"

APP=build/Kuk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
    -o "$APP/Contents/MacOS/Kuk" Sources/*.swift
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/Kuk.app
    cp -R "$APP" ~/Applications/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Kuk.app
    echo "Installed ~/Applications/Kuk.app"
fi
