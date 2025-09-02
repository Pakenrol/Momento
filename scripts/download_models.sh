#!/usr/bin/env bash
set -euo pipefail

# Download Core ML models into Application Support.

APP_NAME="${APP_NAME:-Momento}"
BASE_URL="${MODEL_BASE_URL:-https://github.com/Pakenrol/Momento/releases/latest/download}"

DEST="$HOME/Library/Application Support/$APP_NAME/Models"
mkdir -p "$DEST"

download() {
  local name="$1"
  local url="$BASE_URL/$name.zip"
  local tmp="$(mktemp -t momento_model).zip"
  echo "Downloading $name from $url"
  curl -L "$url" -o "$tmp"
  echo "Unpacking $name to $DEST"
  ditto -x -k "$tmp" "$DEST"
  rm -f "$tmp"
}

download FastDVDnet.mlpackage
download RealBasicVSR_x2.mlpackage

echo "Done. Models installed to: $DEST"

