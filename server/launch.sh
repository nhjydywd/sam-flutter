#!/usr/bin/env bash
set -euo pipefail

# True one-click launcher:
#   - (if needed) create venv under server/.venv
#   - (if needed) install Python deps from server/requirements.txt (including SAM2 code)
#   - (if needed) download the smallest SAM2.1 checkpoint + cfg for quick verification
#   - run server/main.py
#
# Usage:
#   ./server/launch.sh [args passed to main.py]
#
# Examples:
#   ./server/launch.sh --image /path/to/image.jpg --point 320 240
#   ./server/launch.sh   # uses synthetic image; prompts to select a local SAM2 model

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${ROOT}/.venv"
REQ_FILE="${ROOT}/requirements.txt"

pick_python() {
  if command -v python3.11 >/dev/null 2>&1; then
    echo "python3.11"
    return
  fi
  if command -v python3.12 >/dev/null 2>&1; then
    echo "python3.12"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    echo "python3"
    return
  fi
  echo "Error: python3 not found. Install Python 3.11+ first." >&2
  exit 1
}

ensure_venv() {
  if [[ -d "${VENV_DIR}" ]]; then
    return
  fi
  local pybin
  pybin="$(pick_python)"
  echo "Creating venv at ${VENV_DIR} (using ${pybin}) ..."
  "${pybin}" -m venv "${VENV_DIR}"
}

ensure_deps() {
  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"

  # Upgrade pip tooling (quietly but not totally silent).
  python -m pip install -U pip setuptools wheel >/dev/null

  # Fast check: if imports work, skip pip install (important for VCS deps).
  if python - <<'PY' >/dev/null 2>&1; then
import numpy  # noqa: F401
import PIL  # noqa: F401
import torch  # noqa: F401
import sam2  # noqa: F401
PY
    return
  fi

  echo "Installing Python dependencies from ${REQ_FILE} ..."
  # For CPU/MPS installs, avoid CUDA build attempts during SAM2 install.
  SAM2_BUILD_CUDA=0 SAM2_BUILD_ALLOW_ERRORS=1 \
    python -m pip install -r "${REQ_FILE}"
}

ensure_sam2_tiny_model() {
  local out_dir="${ROOT}/models/sam2"
  local ckpt="${out_dir}/sam2.1_hiera_tiny.pt"
  local cfg="${out_dir}/sam2.1_hiera_t.yaml"

  if [[ -f "${ckpt}" && -s "${ckpt}" && -f "${cfg}" && -s "${cfg}" ]]; then
    return
  fi

  echo "Downloading SAM2.1 tiny model (smallest; for quick verification) ..."
  echo "Tip: later you can run 'python3 server/manage_model.py' to download larger models."
  "${ROOT}/download_sam2_tiny.sh"
}

ensure_venv
ensure_deps
ensure_sam2_tiny_model

# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
exec python "${ROOT}/main.py" "$@"
