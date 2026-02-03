#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${ROOT}/models/sam2"
mkdir -p "${OUT_DIR}"

echo "Downloading SAM2.1 tiny checkpoint (smallest; for quick verification) into: ${OUT_DIR}"
echo "Note: SAM2 config YAMLs are bundled inside the installed 'sam2' Python package."

curl -L --fail --retry 3 -C - \
  -o "${OUT_DIR}/sam2.1_hiera_tiny.pt" \
  "https://dl.fbaipublicfiles.com/segment_anything_2/092824/sam2.1_hiera_tiny.pt"

echo
ls -lh "${OUT_DIR}/sam2.1_hiera_tiny.pt"
echo
shasum -a 256 "${OUT_DIR}/sam2.1_hiera_tiny.pt" | cat

