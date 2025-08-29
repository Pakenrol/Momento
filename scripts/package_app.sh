#!/usr/bin/env bash
set -euo pipefail

# VidyScaler: package into a .app, install to ~/Applications, and launch

APP_NAME="VidyScaler"
BUNDLE_ID="com.pakenrol.vidyscaler"
VERSION="0.1.0"
OUT_DIR="dist"
APP_DIR="$OUT_DIR/$APP_NAME.app"

cd "$(dirname "$0")/.."

echo "[1/5] Building Release..."
swift build -c release

BIN_PATH=".build/release/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Error: Built binary not found at $BIN_PATH" >&2
  exit 1
fi
 
echo "Cleaning previous dist bundle..."
rm -rf "$APP_DIR"
echo "[2/5] Creating bundle structure..."
mkdir -p "$APP_DIR/Contents/MacOS"

echo "[3/5] Writing Info.plist..."
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "[4/5] Copying binary..."
cp -f "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
  echo "Signing (ad-hoc)..."
  codesign --force -s - "$APP_DIR" || true
fi

echo "[5/5] Installing to ~/Applications and launching..."
mkdir -p "$HOME/Applications"
# Remove previously installed app to ensure a clean install
rm -rf "$HOME/Applications/$APP_NAME.app"
rsync -a "$APP_DIR" "$HOME/Applications/"
open "$HOME/Applications/$APP_NAME.app"

echo "Done. Installed to $HOME/Applications/$APP_NAME.app"
