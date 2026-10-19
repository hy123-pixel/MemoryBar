#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_NAME="MemoryBar"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
VERSION="$(tr -d '\r\n' < "$ROOT_DIR/VERSION")"
ARM64_BINARY="$ROOT_DIR/.build/arm64-apple-macosx/release/$APP_NAME"
X86_64_BINARY="$ROOT_DIR/.build/x86_64-apple-macosx/release/$APP_NAME"
UNIVERSAL_BINARY="$ROOT_DIR/.build/universal/release/$APP_NAME"

cd "$ROOT_DIR"
if [ -z "$VERSION" ]; then
    echo "VERSION is empty" >&2
    exit 1
fi

swift build -c release --triple arm64-apple-macosx13.0
swift build -c release --triple x86_64-apple-macosx13.0
mkdir -p "$(dirname "$UNIVERSAL_BINARY")"
lipo -create "$ARM64_BINARY" "$X86_64_BINARY" -output "$UNIVERSAL_BINARY"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$ROOT_DIR/build/AppIcon.iconset"
cp "$UNIVERSAL_BINARY" "$APP_DIR/Contents/MacOS/MemoryBar"
swift "$ROOT_DIR/scripts/create-app-icon.swift" "$ROOT_DIR/build/AppIcon.png"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT_DIR/build/AppIcon.png" --out "$ROOT_DIR/build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$ROOT_DIR/build/AppIcon.png" --out "$ROOT_DIR/build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ROOT_DIR/build/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MemoryBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.memorybar.app</string>
    <key>CFBundleName</key>
    <string>内存栏</string>
    <key>CFBundleDisplayName</key>
    <string>内存栏</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
printf 'Built %s\n' "$APP_DIR"
