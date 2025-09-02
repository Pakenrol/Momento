#!/usr/bin/env bash
set -euo pipefail

# Generate a Sparkle appcast into docs/appcast.xml from dist/*.dmg or *.zip
# Tries to use Sparkle's generate_appcast if available, else falls back to a minimal unsigned feed.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOCS_DIR="$ROOT_DIR/docs"
DIST_DIR="$ROOT_DIR/dist"
OUT_FEED="$DOCS_DIR/appcast.xml"

mkdir -p "$DOCS_DIR"

# Find an archive
ARCHIVE="$(ls -1 "$DIST_DIR"/*.dmg 2>/dev/null | head -n1 || true)"
if [[ -z "$ARCHIVE" ]]; then
  ARCHIVE="$(ls -1 "$DIST_DIR"/*.zip 2>/dev/null | head -n1 || true)"
fi
if [[ -z "$ARCHIVE" ]]; then
  echo "Error: No archive found in dist/." >&2
  exit 1
fi

echo "Using archive: $ARCHIVE"

SPARKLE_BIN=""
for cand in \
  "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin" \
  "$ROOT_DIR/third_party/Sparkle/bin" \
  "$ROOT_DIR/Sparkle/bin"; do
  if [[ -d "$cand" ]]; then
    SPARKLE_BIN="$cand"; break
  fi
done

if [[ -n "$SPARKLE_BIN" && -x "$SPARKLE_BIN/generate_appcast" ]]; then
  echo "Generating appcast with Sparkle tools..."
  set +e
  if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    KEY_FILE="$(mktemp)"; printf "%s" "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
    if [[ -n "${APPCAST_DOWNLOAD_BASE:-}" ]]; then
      "$SPARKLE_BIN/generate_appcast" --download-url-prefix "$APPCAST_DOWNLOAD_BASE" -f "$KEY_FILE" "$DIST_DIR"
    else
      "$SPARKLE_BIN/generate_appcast" -f "$KEY_FILE" "$DIST_DIR"
    fi
    EXIT_CODE=$?
    rm -f "$KEY_FILE"
  else
    if [[ -n "${APPCAST_DOWNLOAD_BASE:-}" ]]; then
      "$SPARKLE_BIN/generate_appcast" --download-url-prefix "$APPCAST_DOWNLOAD_BASE" "$DIST_DIR"
    else
      "$SPARKLE_BIN/generate_appcast" "$DIST_DIR"
    fi
    EXIT_CODE=$?
  fi
  set -e
  FEED_FILE="$(ls -1 "$DIST_DIR"/*.xml 2>/dev/null | head -n1 || true)"
  if [[ $EXIT_CODE -eq 0 && -n "$FEED_FILE" ]]; then
    mv -f "$FEED_FILE" "$OUT_FEED"
    echo "Appcast written to $OUT_FEED"
    exit 0
  else
    echo "Sparkle tool failed (exit $EXIT_CODE); falling back to minimal unsigned appcast..."
  fi
fi

echo "Generating a minimal unsigned appcast..."
APP_NAME="${APP_NAME:-Momento}"
VERSION="${VERSION:-0.1.0}"
PUB_DATE="$(date -u "+%a, %d %b %Y %H:%M:%S GMT")"
ARCHIVE_NAME="$(basename "$ARCHIVE")"
ARCHIVE_URL="${APPCAST_DOWNLOAD_BASE:-https://github.com/Pakenrol/Momento/releases/latest/download}/$ARCHIVE_NAME"
ARCHIVE_LEN="$(stat -f%z "$ARCHIVE")"

cat > "$OUT_FEED" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>$APP_NAME Updates</title>
    <link>$ARCHIVE_URL</link>
    <description>Release updates for $APP_NAME</description>
    <language>en</language>
    <item>
      <title>$APP_NAME $VERSION</title>
      <sparkle:releaseNotesLink>https://github.com/Pakenrol/Momento/releases/latest</sparkle:releaseNotesLink>
      <pubDate>$PUB_DATE</pubDate>
      <enclosure url="$ARCHIVE_URL" length="$ARCHIVE_LEN" type="application/x-apple-diskimage" sparkle:version="$(date +%s)" sparkle:shortVersionString="$VERSION"/>
    </item>
  </channel>
  </rss>
XML

echo "Minimal appcast written to $OUT_FEED (unsigned)"
