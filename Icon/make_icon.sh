#!/bin/zsh
# Regenerates Resources/AppIcon.icns from Icon/make_icon.swift.
set -euo pipefail
cd "${0:A:h}/.."
TMP=$(mktemp -d)
swiftc -O -o "$TMP/make_icon" Icon/make_icon.swift
mkdir -p "$TMP/AppIcon.iconset" Resources
for s in 16 32 128 256 512; do
    "$TMP/make_icon" "$TMP/AppIcon.iconset/icon_${s}x${s}.png" $s
    "$TMP/make_icon" "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" $((s * 2))
done
iconutil -c icns -o Resources/AppIcon.icns "$TMP/AppIcon.iconset"
"$TMP/make_icon" Icon/AppIcon.png 1024
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns"
