#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <model.mlmodel> <out_dir.mlmodelc>" >&2
  exit 1
fi

in="$1"
out="$2"
mkdir -p "$(dirname "$out")"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "Error: xcrun not found. Install Xcode command line tools (xcode-select --install)." >&2
  exit 1
fi

echo "Compiling $in -> $out"
xcrun coremlc compile "$in" "$(dirname "$out")"
echo "Done."

