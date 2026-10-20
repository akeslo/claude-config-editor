#!/bin/sh
# Build Claude Config.app and install it in /Applications.
set -eu
cd "$(dirname "$0")"
swift build -c release
APP="build/Claude Config.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp .build/release/ClaudeConfig "$APP/Contents/MacOS/ClaudeConfig"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Config</string>
  <key>CFBundleDisplayName</key><string>Claude Config</string>
  <key>CFBundleIdentifier</key><string>com.akeslo.claude-config</string>
  <key>CFBundleExecutable</key><string>ClaudeConfig</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD)</string>
  <key>ClaudeConfigCommit</key><string>$(git rev-parse HEAD)</string>
  <!-- the fork publishes only mac-app; the update check compares against it -->
  <key>ClaudeConfigBranch</key><string>mac-app</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
rm -rf "/Applications/Claude Config.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/Claude Config.app"
# CLI: first PATH dir of these that is writable without sudo.
for d in "$HOME/.local/bin" /usr/local/bin; do
  case ":$PATH:" in *":$d:"*) if [ -w "$d" ]; then cp .build/release/claude-config "$d/claude-config"; echo "Installed $d/claude-config"; break; fi;; esac
done
