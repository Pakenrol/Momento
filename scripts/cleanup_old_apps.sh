#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MaccyScaler"

echo "Searching for old $APP_NAME.app bundles..."

declare -a CANDIDATES=(
  "$HOME/Applications/$APP_NAME.app"
  "$HOME/Desktop/$APP_NAME.app"
  "$HOME/Downloads/$APP_NAME.app"
  "$HOME/Documents/$APP_NAME.app"
  "$HOME/Documents/Coding/$APP_NAME/dist/$APP_NAME.app"
)

found=0
for p in "${CANDIDATES[@]}"; do
  if [[ -d "$p" ]]; then
    echo "Removing: $p"
    rm -rf "$p"
    found=$((found+1))
  fi
done

# Also remove any duplicate bundles with the same name within common folders (one level deep)
for base in "$HOME/Desktop" "$HOME/Downloads" "$HOME/Documents" "$HOME/Applications"; do
  [[ -d "$base" ]] || continue
  while IFS= read -r -d '' app; do
    echo "Removing duplicate: $app"
    rm -rf "$app"
    found=$((found+1))
  done < <(find "$base" -maxdepth 2 -type d -name "$APP_NAME.app" -print0)
done

# Remove any nested duplicates under /Applications except the canonical one
if [[ -d "/Applications" ]]; then
  while IFS= read -r -d '' app; do
    if [[ "$app" != "/Applications/$APP_NAME.app" ]]; then
      echo "Removing nested duplicate: $app"
      rm -rf "$app"
      found=$((found+1))
    fi
  done < <(find "/Applications" -mindepth 2 -type d -name "$APP_NAME.app" -print0)
fi

echo "Cleanup finished. Removed $found bundle(s)."
