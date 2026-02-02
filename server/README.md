# Server Utilities

## macOS setup (venv)

One-click launch (creates venv if needed, installs deps, downloads the smallest SAM2 model, then runs):

```bash
./server/launch.sh --image /path/to/image.jpg --point 320 240
```

(`./server/setup_macos.sh` is now just a wrapper around `./server/launch.sh`.)

## SAM2 basic smoke test

Script: `server/test_sam2_basic.py`

This verifies you can load a SAM2 model (config + checkpoint), run a prompt-based
segmentation on a single image, and save the resulting mask + overlay.

### Model downloads

Interactive model manager (prints present/missing; lets you download by index or 'a' for all):

```bash
python3 server/manage_model.py
```

### Install deps

Recommended: use `./server/launch.sh` (it installs deps automatically).

Manual alternative (create/activate a venv, then install):

```bash
python3 -m pip install -r server/requirements.txt
```

Install PyTorch (CPU/CUDA/MPS depends on your machine). Example (macOS MPS/CPU):

```bash
python3 -m pip install torch torchvision
```

Install SAM2 so `import sam2` works (typical approach: editable install from a local clone):

```bash
python3 -m pip install -e /abs/path/to/segment-anything-2
# or:
export PYTHONPATH=/abs/path/to/segment-anything-2:$PYTHONPATH
```

### Run

First, download the tiny model files into `server/models/sam2/`:

```bash
./server/download_sam2_tiny.sh
```

```bash
python3 server/test_sam2_basic.py \
  --model-cfg /abs/path/to/sam2_tiny_config.yaml \
  --checkpoint /abs/path/to/sam2_tiny.pt \
  --image /abs/path/to/image.jpg \
  --point 320 240
```

If you use `./server/download_sam2_tiny.sh`, you can omit `--model-cfg/--checkpoint`
and the script will default to:
`server/models/sam2/sam2.1_hiera_t.yaml` + `server/models/sam2/sam2.1_hiera_tiny.pt`.

Outputs go to `server/sam2_smoke_out/` by default.
