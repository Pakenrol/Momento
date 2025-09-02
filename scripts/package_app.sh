#!/usr/bin/env bash
set -euo pipefail

# Momento: package into a .app; optionally install to /Applications and launch

APP_NAME="Momento"
BUNDLE_ID="com.pakenrol.momento"
# Semantic version shown to users (keep stable), build auto-increments to bust caches
# Can be overridden: VERSION=1.0.0 ./scripts/package_app.sh
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(date +%s)"
OUT_DIR="dist"
APP_DIR="$OUT_DIR/$APP_NAME.app"

cd "$(dirname "$0")/.."

echo "[1/6] Building Release..."
swift build -c release

BIN_PATH=".build/release/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Error: Built binary not found at $BIN_PATH" >&2
  exit 1
fi
 
echo "Cleaning previous dist bundle..."
rm -rf "$APP_DIR"
echo "[2/6] Creating bundle structure..."
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks" "$APP_DIR/Contents/XPCServices"

# Build AppIcon.icns from a source image
ICON_NAME="AppIcon.icns"
ICON_PATH="$APP_DIR/Contents/Resources/$ICON_NAME"
# Icon source is fixed to branding/AppIconSource.png unless overridden via ICON_SRC env var
ICON_SRC_REPO="branding/AppIconSource.png"
SRC_ICON="${ICON_SRC:-$ICON_SRC_REPO}"

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

echo "[3/6] Writing Info.plist..."
# Allow supplying Sparkle configuration via env vars
# SPARKLE_FEED_URL - appcast URL
# SPARKLE_PUBLIC_ED_KEY - ed25519 public key (base64)
SPARKLE_FEED_URL_PLIST="${SPARKLE_FEED_URL:-https://example.com/appcast.xml}"
SUPublicEDKey_PLIST="${SPARKLE_PUBLIC_ED_KEY:-}"
MODEL_BASE_URL_PLIST="${MODEL_BASE_URL:-https://github.com/Pakenrol/Momento/releases/latest/download}"
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
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <!-- Sparkle configuration -->
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL_PLIST</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <!-- Optional EdDSA public key; leave empty to set later -->
  <key>SUPublicEDKey</key>
  <string>$SUPublicEDKey_PLIST</string>
  <!-- Model downloads configuration -->
  <key>ModelDownloadBaseURL</key>
  <string>$MODEL_BASE_URL_PLIST</string>
</dict>
</plist>
PLIST

echo "[4/6] Copying binary..."
cp -f "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# Build and copy CLI helper into Resources (not MacOS to avoid second Dock icon)
CLI_BIN=".build/release/coreml-vsr-cli"
if [[ -x "$CLI_BIN" ]]; then
  echo "Copying coreml-vsr-cli into app Resources..."
  cp -f "$CLI_BIN" "$APP_DIR/Contents/Resources/coreml-vsr-cli"
  chmod +x "$APP_DIR/Contents/Resources/coreml-vsr-cli"
  # Clean any accidental old copy under MacOS
  rm -f "$APP_DIR/Contents/MacOS/coreml-vsr-cli" || true
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
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "Signing with identity: $CODESIGN_IDENTITY"
    codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$APP_DIR" || true
  else
    echo "Signing (ad-hoc)..."
    codesign --force -s - "$APP_DIR" || true
  fi
fi

# Optionally embed Sparkle (manual distribution without Xcode)
embed_sparkle() {
  local fw_src=""
  # Candidate locations: user-provided SPARKLE_DIST, third_party, SPM artifacts
  if [[ -n "${SPARKLE_DIST:-}" ]]; then
    fw_src="$(/usr/bin/find "$SPARKLE_DIST" -maxdepth 3 -name Sparkle.framework -type d 2>/dev/null || true | head -n1)"
  fi
  if [[ -z "$fw_src" ]]; then
    fw_src="$(/usr/bin/find third_party/Sparkle -maxdepth 3 -name Sparkle.framework -type d 2>/dev/null || true | head -n1)"
  fi
  if [[ -z "$fw_src" ]]; then
    fw_src="$(/usr/bin/find .build -maxdepth 5 -path "*/Sparkle.framework" -type d 2>/dev/null || true | head -n1)"
  fi
  if [[ -z "$fw_src" ]]; then
    echo "Sparkle.framework not found; skipping embed"
    return
  fi
  echo "Embedding Sparkle from: $fw_src"
  rsync -a "$fw_src" "$APP_DIR/Contents/Frameworks/"

  # Copy XPC services (Sparkle 2)
  local xpc_root1="$(dirname "$fw_src")/XPCServices"
  local xpc_root2="$fw_src/Versions/A/XPCServices"
  for root in "$xpc_root1" "$xpc_root2"; do
    if [[ -d "$root" ]]; then
      echo "Copying Sparkle XPCServices from $root"
      rsync -a "$root/" "$APP_DIR/Contents/XPCServices/"
    fi
  done

  # Sign the framework and XPCs if identity provided
  if command -v codesign >/dev/null 2>&1; then
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
      /usr/bin/find "$APP_DIR/Contents/XPCServices" -name "*.xpc" -type d -exec codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" {} \; || true
      codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$APP_DIR/Contents/Frameworks/Sparkle.framework" || true
      codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$APP_DIR" || true
    else
      /usr/bin/find "$APP_DIR/Contents/XPCServices" -name "*.xpc" -type d -exec codesign --force -s - {} \; || true
      codesign --force -s - "$APP_DIR/Contents/Frameworks/Sparkle.framework" || true
      codesign --force -s - "$APP_DIR" || true
    fi
  fi
}

if [[ "${EMBED_SPARKLE:-0}" == "1" ]]; then
  echo "[5/6] Embedding Sparkle framework..."
  embed_sparkle
fi

# Optionally build a DMG for distribution
make_dmg() {
  local dmg_name="$OUT_DIR/$APP_NAME-$VERSION.dmg"
  echo "Creating DMG: $dmg_name"
  # Create staging folder
  local stage="$OUT_DIR/dmg_stage"
  rm -rf "$stage" && mkdir -p "$stage"
  ln -s /Applications "$stage/Applications"
  cp -R "$APP_DIR" "$stage/$APP_NAME.app"
  hdiutil create -volname "$APP_NAME" -fs HFS+ -srcfolder "$stage" -ov -format UDZO "$dmg_name" >/dev/null
  rm -rf "$stage"
  echo "DMG written to $dmg_name"
  # Optionally sign the DMG with Developer ID
  if [[ -n "${CODESIGN_IDENTITY:-}" ]] && command -v codesign >/dev/null 2>&1; then
    echo "Signing DMG with identity: $CODESIGN_IDENTITY"
    codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$dmg_name" || true
  fi
}

if [[ "${MAKE_DMG:-0}" == "1" ]]; then
  echo "[5/6] Building DMG..."
  make_dmg
fi

# Install to /Applications unless disabled
if [[ "${PACKAGE_ONLY:-0}" == "1" ]]; then
  echo "[6/6] Package ready at $APP_DIR (skipping install/open)"
  exit 0
fi

echo "[6/6] Installing to /Applications and launching..."
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
