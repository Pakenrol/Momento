#!/usr/bin/env bash
set -euo pipefail

# Create a DMG from an existing .app bundle in dist/

APP_NAME="${APP_NAME:-Momento}"
VERSION="${VERSION:-0.1.0}"
OUT_DIR="${OUT_DIR:-dist}"
APP_DIR="$OUT_DIR/$APP_NAME.app"

cd "$(dirname "$0")/.."

if [[ ! -d "$APP_DIR" ]]; then
  echo "Error: $APP_DIR not found. Build the app first (scripts/package_app.sh with PACKAGE_ONLY=1)." >&2
  exit 1
fi

DMG_PATH="$OUT_DIR/$APP_NAME-$VERSION.dmg"
STAGE_DIR="$OUT_DIR/dmg_stage"

rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"
ln -s /Applications "$STAGE_DIR/Applications"
cp -R "$APP_DIR" "$STAGE_DIR/$APP_NAME.app"

echo "Creating DMG at $DMG_PATH"
hdiutil create -volname "$APP_NAME" -fs HFS+ -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGE_DIR"

echo "DMG created: $DMG_PATH"

