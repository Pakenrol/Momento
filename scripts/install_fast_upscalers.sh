#!/usr/bin/env bash
set -euo pipefail

# Downloads macOS arm64 builds of waifu2x-ncnn-vulkan and realcugan-ncnn-vulkan
# into the project's bin/ folder and marks them executable.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/bin"
mkdir -p "$BIN_DIR"

echo "Installing fast upscalers into $BIN_DIR"

tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# Try waifu2x-ncnn-vulkan (known good release 20220728)
if [ ! -x "$BIN_DIR/waifu2x-ncnn-vulkan" ]; then
  echo "Downloading waifu2x-ncnn-vulkan..."
  URL_W2X="https://github.com/nihui/waifu2x-ncnn-vulkan/releases/download/20220728/waifu2x-ncnn-vulkan-20220728-macos.zip"
  if curl -L --fail -o "$tmp/w2x.zip" "$URL_W2X"; then
    unzip -q "$tmp/w2x.zip" -d "$tmp/w2x"
    SRC_BIN=$(find "$tmp/w2x" -type f -name waifu2x-ncnn-vulkan | head -n1 || true)
    if [ -n "$SRC_BIN" ]; then
      cp -f "$SRC_BIN" "$BIN_DIR/waifu2x-ncnn-vulkan"
      chmod +x "$BIN_DIR/waifu2x-ncnn-vulkan"
      echo "waifu2x installed: $BIN_DIR/waifu2x-ncnn-vulkan"
    else
      echo "Could not find waifu2x binary in archive"
    fi
  else
    echo "Failed to download waifu2x archive from $URL_W2X"
  fi
fi

# Try realcugan-ncnn-vulkan (known macOS package)
if [ ! -x "$BIN_DIR/realcugan-ncnn-vulkan" ]; then
  echo "Downloading realcugan-ncnn-vulkan..."
  URL_CUGAN="https://github.com/bilibili/Real-CUGAN/releases/download/v0.2.0/realcugan-ncnn-vulkan-20220424-macos.zip"
  if curl -L --fail -o "$tmp/cugan.zip" "$URL_CUGAN"; then
    unzip -q "$tmp/cugan.zip" -d "$tmp/cugan"
    SRC_BIN=$(find "$tmp/cugan" -type f -name realcugan-ncnn-vulkan | head -n1 || true)
    if [ -n "$SRC_BIN" ]; then
      cp -f "$SRC_BIN" "$BIN_DIR/realcugan-ncnn-vulkan"
      chmod +x "$BIN_DIR/realcugan-ncnn-vulkan"
      echo "realcugan installed: $BIN_DIR/realcugan-ncnn-vulkan"
    else
      echo "Could not find realcugan binary in archive"
    fi
  else
    echo "Failed to download realcugan archive from $URL_CUGAN"
  fi
fi

echo "Done. If any binary is missing, download manually and place into $BIN_DIR"

