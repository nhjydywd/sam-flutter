#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${ROOT}/models/sam2"
mkdir -p "${OUT_DIR}"

echo "Downloading SAM2.1 tiny checkpoint + config into: ${OUT_DIR}"

curl -L --fail --retry 3 -C - \
  -o "${OUT_DIR}/sam2.1_hiera_tiny.pt" \
  "https://dl.fbaipublicfiles.com/segment_anything_2/092824/sam2.1_hiera_tiny.pt"

curl -L --fail --retry 3 \
  -o "${OUT_DIR}/sam2.1_hiera_t.yaml" \
  "https://raw.githubusercontent.com/facebookresearch/sam2/main/sam2/configs/sam2.1/sam2.1_hiera_t.yaml"

echo
ls -lh "${OUT_DIR}/sam2.1_hiera_tiny.pt" "${OUT_DIR}/sam2.1_hiera_t.yaml"
echo
shasum -a 256 "${OUT_DIR}/sam2.1_hiera_tiny.pt" "${OUT_DIR}/sam2.1_hiera_t.yaml" | cat

