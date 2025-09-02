#!/usr/bin/env bash
set -euo pipefail

# Momento: package into a .app, install to /Applications only, and launch

APP_NAME="Momento"
BUNDLE_ID="com.pakenrol.momento"
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
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# Build AppIcon.icns from a source image
ICON_NAME="AppIcon.icns"
ICON_PATH="$APP_DIR/Contents/Resources/$ICON_NAME"
ICON_SRC_REPO="branding/AppIconSource.png"

# Prefer the latest PNG from Downloads; also snapshot it into the repo (branding/AppIconSource.png)
LATEST_PNG=$(find "$HOME/Downloads" -type f -iname "*.png" -print0 2>/dev/null | xargs -0 ls -t1 2>/dev/null | head -n 1 || true)
SRC_ICON=""
if [[ -n "$LATEST_PNG" && -f "$LATEST_PNG" ]]; then
  mkdir -p "branding"
  cp -f "$LATEST_PNG" "$ICON_SRC_REPO" || true
  SRC_ICON="$ICON_SRC_REPO"
elif [[ -f "$ICON_SRC_REPO" ]]; then
  SRC_ICON="$ICON_SRC_REPO"
fi

if [[ -n "$SRC_ICON" && -f "$SRC_ICON" ]]; then
  echo "Creating app icon from: $SRC_ICON"
  TMP_ICONSET="dist/icon.iconset"
  rm -rf "$TMP_ICONSET" && mkdir -p "$TMP_ICONSET"
  # Generate required sizes
  for size in 16 32 64 128 256 512; do
    sips -z $size $size "$SRC_ICON" --out "$TMP_ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1 || true
    dbl=$((size*2))
    sips -z $dbl $dbl "$SRC_ICON" --out "$TMP_ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || true
  done
  # Build icns
  if command -v iconutil >/dev/null 2>&1; then
    iconutil -c icns "$TMP_ICONSET" -o "$ICON_PATH" || true
  else
    echo "Warning: iconutil not found; skipping icns creation"
  fi
else
  echo "Warning: No icon source found; app will use default icon"
fi

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
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
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

# Build and copy CLI helper into the app bundle for headless pipeline
CLI_BIN=".build/release/coreml-vsr-cli"
if [[ -x "$CLI_BIN" ]]; then
  echo "Copying coreml-vsr-cli into app bundle..."
  cp -f "$CLI_BIN" "$APP_DIR/Contents/MacOS/coreml-vsr-cli"
  chmod +x "$APP_DIR/Contents/MacOS/coreml-vsr-cli"
else
  echo "Warning: coreml-vsr-cli not found at $CLI_BIN"
fi

# Copy SwiftPM resource bundle (models) if present
RES_BUNDLE=".build/release/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
  echo "Copying resources bundle..."
  rsync -a "$RES_BUNDLE" "$APP_DIR/Contents/Resources/"
else
  echo "Warning: resources bundle not found at $RES_BUNDLE"
fi

# Also place raw mlpackage folders at top-level Resources for direct lookup
# Prefer Tools/RealBasicVSR_x2.mlpackage if present (override broken root copies)
if [[ -d "Tools/RealBasicVSR_x2.mlpackage" ]]; then
  echo "Copying Tools/RealBasicVSR_x2.mlpackage into app Resources (preferred)..."
  rsync -a "Tools/RealBasicVSR_x2.mlpackage" "$APP_DIR/Contents/Resources/"
else
  if [[ -d "RealBasicVSR_x2.mlpackage" ]]; then
    echo "Copying RealBasicVSR_x2.mlpackage into app Resources..."
    rsync -a "RealBasicVSR_x2.mlpackage" "$APP_DIR/Contents/Resources/"
  fi
fi
if [[ -d "FastDVDnet.mlpackage" ]]; then
  echo "Copying FastDVDnet.mlpackage into app Resources..."
  rsync -a "FastDVDnet.mlpackage" "$APP_DIR/Contents/Resources/"
fi

if command -v codesign >/dev/null 2>&1; then
  echo "Signing (ad-hoc)..."
  codesign --force -s - "$APP_DIR" || true
fi

echo "[5/5] Installing to /Applications and launching..."
# Clean up any old copies in user folders
rm -rf "$HOME/Applications/$APP_NAME.app" || true
rm -rf "$HOME/Desktop/$APP_NAME.app" "$HOME/Downloads/$APP_NAME.app" "$HOME/Documents/$APP_NAME.app" || true

# Install to system Applications (requires privileges)
INSTALL_DIR="/Applications"
if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "Creating $INSTALL_DIR..."
  mkdir -p "$INSTALL_DIR"
fi
rm -rf "$INSTALL_DIR/$APP_NAME.app"
rsync -a "$APP_DIR" "$INSTALL_DIR/"

# Remove local dist copy to ensure the app exists only in /Applications
rm -rf "$APP_DIR"

open "$INSTALL_DIR/$APP_NAME.app"

echo "Done. Installed to $INSTALL_DIR/$APP_NAME.app"
