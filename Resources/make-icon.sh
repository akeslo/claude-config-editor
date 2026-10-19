#!/bin/sh
# Renders Resources/AppIcon.svg (1024px master on Apple's macOS grid) into Resources/AppIcon.icns.
set -eu
cd "$(dirname "$0")"
tmp=$(mktemp -d); set=$tmp/AppIcon.iconset; mkdir "$set"
qlmanage -t -s 1024 -o "$tmp" AppIcon.svg >/dev/null
for px in 16 32 128 256 512; do
  sips -z $px $px "$tmp/AppIcon.svg.png" --out "$set/icon_${px}x${px}.png" >/dev/null
  sips -z $((px*2)) $((px*2)) "$tmp/AppIcon.svg.png" --out "$set/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o AppIcon.icns
rm -r "$tmp"
