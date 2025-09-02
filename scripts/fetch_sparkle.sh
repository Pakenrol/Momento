#!/usr/bin/env bash
set -euo pipefail

# Fetch the latest Sparkle release and unpack to third_party/Sparkle

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT_DIR/third_party/Sparkle"
mkdir -p "$DEST_DIR"

VER="${SPARKLE_VERSION:-}"
URL="${SPARKLE_TAR_URL:-}"

if [[ -z "$URL" ]]; then
  if [[ -n "$VER" ]]; then
    URL="https://github.com/sparkle-project/Sparkle/releases/download/$VER/Sparkle-$VER.tar.xz"
  else
    echo "Resolving latest Sparkle release URL..."
    JSON="$(curl -fsSL https://api.github.com/repos/sparkle-project/Sparkle/releases/latest)"
    URL="$(printf "%s" "$JSON" | grep -Eo '"browser_download_url"\s*:\s*"[^"]+Sparkle-[^"]+\.tar\.xz"' | head -n1 | sed -E 's/.*"(https:[^"]+)".*/\1/')"
    if [[ -z "$URL" ]]; then
      echo "Failed to resolve latest Sparkle tarball URL. Set SPARKLE_TAR_URL or SPARKLE_VERSION." >&2
      exit 1
    fi
  fi
fi

TMP_TAR="$(mktemp -t sparkle).tar.xz"
echo "Downloading: $URL"
curl -L "$URL" -o "$TMP_TAR"

echo "Unpacking to $DEST_DIR"
tar -xJf "$TMP_TAR" -C "$DEST_DIR" --strip-components=1 || tar -xJf "$TMP_TAR" -C "$DEST_DIR" || true
rm -f "$TMP_TAR"

echo "Done. Sparkle unpacked under $DEST_DIR"
echo "To embed in the app bundle: EMBED_SPARKLE=1 ./scripts/package_app.sh"

