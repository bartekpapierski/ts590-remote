#!/bin/zsh
# Bundle the swift build output into a proper .app so CoreAudio (HALOutput)
# registers its audio-unit factories. Running the bare binary crashes with -10877.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/.build/debug/RemoteRig"
APP="$ROOT/RemoteRig.app"
OPUS=/opt/homebrew/opt/opus/lib/libopus.0.dylib

if [ ! -x "$BIN" ]; then
  echo "build first: swift build" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/RemoteRig"
cp "$OPUS" "$APP/Contents/Frameworks/libopus.0.dylib"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key> <string>RemoteRig</string>
    <key>CFBundleDisplayName</key> <string>RemoteRig</string>
    <key>CFBundleIdentifier</key> <string>com.ts590.remote</string>
    <key>CFBundleVersion</key> <string>1</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleExecutable</key> <string>RemoteRig</string>
    <key>CFBundlePackageType</key> <string>APPL</string>
    <key>LSMinimumSystemVersion</key> <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
EOF

chmod +x "$APP/Contents/MacOS/RemoteRig"
echo "built $APP"
