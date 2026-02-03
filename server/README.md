# Server Utilities

## macOS setup (venv)

One-click launch (creates venv if needed, installs deps, downloads the smallest SAM2 model, then runs):

```bash
./server/launch.sh --image /path/to/image.jpg --point 320 240
```

## SAM2 basic smoke test

Script: `server/test_sam2_basic.py`

This verifies you can load a SAM2 model (config name + checkpoint), run a prompt-based
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

### Run

First, download the tiny model files into `server/models/sam2/`:

```bash
./server/download_sam2_tiny.sh
```

```bash
python3 server/test_sam2_basic.py \
  --model-cfg configs/sam2.1/sam2.1_hiera_t.yaml \
  --checkpoint server/models/sam2/sam2.1_hiera_tiny.pt \
  --image /abs/path/to/image.jpg \
  --point 320 240
```

If you use `./server/download_sam2_tiny.sh`, you can omit `--model-cfg/--checkpoint`;
the script will prompt to pick a locally downloaded checkpoint (or auto-select if only one).

Outputs go to `server/sam2_smoke_out/` by default.
