#!/usr/bin/env bash
set -euo pipefail

# One-shot macOS setup for the server Python environment.
# Creates a venv under server/.venv and installs runtime dependencies.
#
# Optional:
#   SAM1_REPO=/abs/path/to/segment-anything        (editable install)
#   SAM2_REPO=/abs/path/to/segment-anything-2      (editable install)
#   DOWNLOAD_SAM2_TINY=1                           (download tiny ckpt+yaml into server/models/sam2)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${ROOT}/.venv"

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

PYBIN="$(pick_python)"
echo "Using Python: ${PYBIN}"

if [[ ! -d "${VENV_DIR}" ]]; then
  "${PYBIN}" -m venv "${VENV_DIR}"
fi

# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

python -V
python -m pip install -U pip setuptools wheel

echo "Installing PyTorch (torch + torchvision) ..."
python -m pip install -U torch torchvision

echo "Installing server requirements ..."
python -m pip install -r "${ROOT}/requirements.txt"

if [[ -n "${SAM1_REPO:-}" ]]; then
  echo "Installing SAM1 from: ${SAM1_REPO}"
  python -m pip install -e "${SAM1_REPO}"
else
  echo "SAM1 not installed (set SAM1_REPO to a local clone path to install)."
fi

if [[ -n "${SAM2_REPO:-}" ]]; then
  echo "Installing SAM2 from: ${SAM2_REPO}"
  python -m pip install -e "${SAM2_REPO}"
else
  echo "SAM2 not installed (set SAM2_REPO to a local clone path to install)."
fi

if [[ "${DOWNLOAD_SAM2_TINY:-0}" == "1" ]]; then
  echo "Downloading SAM2.1 tiny model files ..."
  "${ROOT}/download_sam2_tiny.sh"
fi

echo
echo "Done."
echo "Activate with:"
echo "  source ${VENV_DIR}/bin/activate"
echo
echo "Example smoke test (after you have SAM2 installed and model files present):"
echo "  python ${ROOT}/test_sam2_basic.py --image /path/to/image.jpg --point 320 240"

