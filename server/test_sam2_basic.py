#!/usr/bin/env python3
"""
SAM2 basic smoke test (single-image segmentation).

This script verifies:
  1) SAM2 model can be constructed from a config + checkpoint
  2) A prompt (point or box) produces at least one mask
  3) Outputs (mask + overlay) can be saved to disk

Example (tiny model recommended):
  python server/test_sam2_basic.py \
    --model-cfg /path/to/sam2_hiera_tiny.yaml \
    --checkpoint /path/to/sam2_hiera_tiny.pt \
    --image /path/to/image.jpg \
    --point 320 240
"""

from __future__ import annotations

import argparse
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple

import numpy as np
from PIL import Image, ImageDraw

try:
    import torch  # type: ignore
except Exception as e:  # pragma: no cover
    torch = None  # type: ignore
    _TORCH_IMPORT_ERROR = e
else:  # pragma: no cover
    _TORCH_IMPORT_ERROR = None

try:
    from sam2.build_sam import build_sam2  # type: ignore
    from sam2.sam2_image_predictor import SAM2ImagePredictor  # type: ignore
except Exception as e:  # pragma: no cover
    build_sam2 = None  # type: ignore
    SAM2ImagePredictor = None  # type: ignore
    _SAM2_IMPORT_ERROR = e
else:  # pragma: no cover
    _SAM2_IMPORT_ERROR = None


def _discover_local_sam2_models(server_dir: Path) -> list[tuple[str, str, Path]]:
    """
    Returns a list of (key, config_name, checkpoint_path) for locally present checkpoints.

    NOTE: SAM2 uses Hydra and expects a *config name* (e.g. "configs/sam2.1/sam2.1_hiera_t.yaml")
    rather than an absolute filesystem path. The configs ship inside the installed `sam2` package.
    """
    base = server_dir / "models" / "sam2"
    candidates: list[tuple[str, str, Path]] = [
        ("sam2.1_hiera_tiny", "configs/sam2.1/sam2.1_hiera_t.yaml", base / "sam2.1_hiera_tiny.pt"),
        ("sam2.1_hiera_small", "configs/sam2.1/sam2.1_hiera_s.yaml", base / "sam2.1_hiera_small.pt"),
        ("sam2.1_hiera_base_plus", "configs/sam2.1/sam2.1_hiera_b+.yaml", base / "sam2.1_hiera_base_plus.pt"),
        ("sam2.1_hiera_large", "configs/sam2.1/sam2.1_hiera_l.yaml", base / "sam2.1_hiera_large.pt"),
    ]

    usable: list[tuple[str, str, Path]] = []
    for key, cfg_name, ckpt in candidates:
        if ckpt.is_file() and ckpt.stat().st_size > 0:
            usable.append((key, cfg_name, ckpt))
    return usable


def _prompt_select_model(models: list[tuple[str, str, Path]]) -> tuple[str, str, str]:
    """
    Returns (model_key, config_name, checkpoint_path).

    If exactly one model is available locally, auto-select it (no prompt).
    """
    if len(models) == 1:
        key, cfg_name, ckpt = models[0]
        print(f"Using the only available SAM2 model: {key} (cfg={cfg_name}, ckpt={ckpt.name})")
        return key, cfg_name, str(ckpt)

    print("Available SAM2 models:")
    for i, (key, cfg_name, ckpt) in enumerate(models, start=1):
        size_mb = ckpt.stat().st_size / (1024 * 1024)
        print(f"  [{i}] {key}  ({size_mb:.1f}MB)  cfg={cfg_name}  ckpt={ckpt.name}")

    while True:
        raw = input("Select a model index (default 1), or 'q' to quit: ").strip()
        if raw == "":
            idx = 1
            break
        if raw.lower() == "q":
            raise SystemExit(0)
        if raw.isdigit():
            idx = int(raw)
            if 1 <= idx <= len(models):
                break
        print("Invalid selection.")

    key, cfg_name, ckpt = models[idx - 1]
    print(f"Using SAM2 model: {key} (cfg={cfg_name}, ckpt={ckpt.name})")
    return key, cfg_name, str(ckpt)


def _infer_model_key(server_dir: Path, model_cfg: str, checkpoint: str) -> str:
    ckpt_p = Path(checkpoint).resolve()
    for key, cfg, ckpt in _discover_local_sam2_models(server_dir):
        if cfg == model_cfg and ckpt.resolve() == ckpt_p:
            return key
    return "custom"


def _best_device(requested: str) -> str:
    if requested != "auto":
        return requested

    if torch is None:
        return "cpu"

    if torch.cuda.is_available():
        return "cuda"
    # macOS Metal
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def _make_synthetic_image(size: int = 512) -> Tuple[Image.Image, Tuple[int, int]]:
    """
    Creates a simple synthetic image with a couple of shapes.
    Returns (image, default_point_xy).
    """
    img = Image.new("RGB", (size, size), (245, 245, 245))
    draw = ImageDraw.Draw(img)
    # Red circle
    cx, cy, r = int(size * 0.35), int(size * 0.45), int(size * 0.16)
    draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(220, 60, 60))
    # Blue rectangle
    x0, y0 = int(size * 0.60), int(size * 0.20)
    x1, y1 = int(size * 0.90), int(size * 0.55)
    draw.rectangle((x0, y0, x1, y1), fill=(60, 110, 230))
    return img, (cx, cy)


def _parse_point(arg: Optional[Tuple[int, int]]) -> Optional[np.ndarray]:
    if arg is None:
        return None
    x, y = arg
    return np.array([[float(x), float(y)]], dtype=np.float32)


def _parse_box(arg: Optional[Tuple[int, int, int, int]]) -> Optional[np.ndarray]:
    if arg is None:
        return None
    x0, y0, x1, y1 = arg
    return np.array([float(x0), float(y0), float(x1), float(y1)], dtype=np.float32)


def _save_mask(mask: np.ndarray, out_path: Path) -> None:
    # mask can be bool or 0/1 float; normalize to 0-255.
    m = (mask.astype(np.uint8) * 255) if mask.dtype != np.uint8 else mask
    Image.fromarray(m).save(out_path)


def _save_overlay(rgb: np.ndarray, mask: np.ndarray, out_path: Path) -> None:
    base = Image.fromarray(rgb)
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    ov = ImageDraw.Draw(overlay)

    # Create an alpha mask from the predicted mask.
    alpha = (mask.astype(np.uint8) * 140)  # 0..255
    # Pillow wants L-mode alpha; we paste a solid color with an alpha mask.
    color = Image.new("RGBA", base.size, (0, 200, 0, 0))
    color.putalpha(Image.fromarray(alpha, mode="L"))
    composed = Image.alpha_composite(base.convert("RGBA"), color)

    # Draw a thin border around the image to make it obvious it's an output.
    w, h = base.size
    ov.rectangle((0, 0, w - 1, h - 1), outline=(255, 0, 0, 255), width=2)
    composed = Image.alpha_composite(composed, overlay)
    composed.convert("RGB").save(out_path)


@dataclass(frozen=True)
class PredictResult:
    masks: np.ndarray
    scores: np.ndarray
    best_index: int


def _run_predict(
    *,
    model_cfg: str,
    checkpoint: str,
    image_rgb: np.ndarray,
    point_xy: Optional[np.ndarray],
    box_xyxy: Optional[np.ndarray],
    device: str,
    multimask: bool,
) -> PredictResult:
    if torch is None:
        raise SystemExit(
            "Missing dependency: torch. Install PyTorch first, then rerun.\n"
            f"Import error: {_TORCH_IMPORT_ERROR}"
        )
    if build_sam2 is None or SAM2ImagePredictor is None:
        raise SystemExit(
            "Cannot import SAM2. Make sure the SAM2 repo/package is installed and importable.\n"
            "Typical options:\n"
            "  - pip install -e /abs/path/to/segment-anything-2\n"
            "  - export PYTHONPATH=/abs/path/to/segment-anything-2:$PYTHONPATH\n"
            f"Import error: {_SAM2_IMPORT_ERROR}"
        )

    # Build model + predictor.
    model = build_sam2(model_cfg, checkpoint, device=device)
    predictor = SAM2ImagePredictor(model)

    # SAM2 expects uint8 RGB image.
    if image_rgb.dtype != np.uint8:
        image_rgb = image_rgb.astype(np.uint8)
    predictor.set_image(image_rgb)

    point_labels = None
    if point_xy is not None:
        # 1 = foreground point
        point_labels = np.array([1], dtype=np.int32)

    with torch.inference_mode():
        masks, scores, _logits = predictor.predict(
            point_coords=point_xy,
            point_labels=point_labels,
            box=box_xyxy,
            multimask_output=multimask,
        )

    if masks is None or len(masks) == 0:
        raise SystemExit("SAM2 returned no masks; try a different prompt or image.")

    scores_np = np.asarray(scores, dtype=np.float32)
    best = int(np.argmax(scores_np))
    return PredictResult(masks=np.asarray(masks), scores=scores_np, best_index=best)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--model-cfg",
        required=False,
        help="SAM2 Hydra config name (e.g. 'configs/sam2.1/sam2.1_hiera_t.yaml').",
    )
    p.add_argument("--checkpoint", required=False, help="Path to SAM2 checkpoint (.pt).")
    p.add_argument("--image", required=False, help="Path to an input image. If omitted, uses a synthetic image.")
    p.add_argument(
        "--output-dir",
        default=None,
        help="Output directory (default: <this_script_dir>/sam2_smoke_out).",
    )
    p.add_argument("--device", default="auto", choices=["auto", "cpu", "cuda", "mps"])
    p.add_argument("--multimask", action="store_true", help="Output multiple masks (default: false).")
    p.add_argument("--point", nargs=2, type=int, metavar=("X", "Y"), help="Foreground point prompt (x y).")
    p.add_argument("--box", nargs=4, type=int, metavar=("X0", "Y0", "X1", "Y1"), help="Box prompt (x0 y0 x1 y1).")

    args = p.parse_args()

    model_cfg = args.model_cfg or os.environ.get("SAM2_MODEL_CFG")
    checkpoint = args.checkpoint or os.environ.get("SAM2_CHECKPOINT")

    # Either provide both explicitly, or neither (then select from local models).
    if bool(model_cfg) ^ bool(checkpoint):
        raise SystemExit("Provide both --model-cfg and --checkpoint (or neither to select a local model).")

    if not model_cfg and not checkpoint:
        server_dir = Path(__file__).resolve().parent
        local_models = _discover_local_sam2_models(server_dir)
        if not local_models:
            raise SystemExit(
                "No usable SAM2 models found under server/models/sam2 (need the checkpoint .pt).\n"
                "Quick start:\n"
                "  ./server/download_sam2_tiny.sh\n"
                "Or manage downloads:\n"
                "  python3 server/manage_model.py\n"
                "Expected example paths:\n"
                "  server/models/sam2/sam2.1_hiera_tiny.pt"
            )
        model_key, model_cfg, checkpoint = _prompt_select_model(local_models)
    else:
        server_dir = Path(__file__).resolve().parent
        model_key = _infer_model_key(server_dir, model_cfg, checkpoint)
        print(f"Using SAM2 model: {model_key}")

    if not model_cfg or not checkpoint:
        raise SystemExit(
            "Missing --model-cfg/--checkpoint (or env SAM2_MODEL_CFG/SAM2_CHECKPOINT).\n"
            "Tip: for a small model, use config 'configs/sam2.1/sam2.1_hiera_t.yaml' + 'sam2.1_hiera_tiny.pt' checkpoint.\n"
            "If you downloaded them into this repo, put them at:\n"
            "  server/models/sam2/sam2.1_hiera_tiny.pt"
        )

    out_dir = Path(args.output_dir) if args.output_dir else (Path(__file__).resolve().parent / "sam2_smoke_out")
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.image:
        img = Image.open(args.image).convert("RGB")
        default_point = (img.width // 2, img.height // 2)
        in_name = Path(args.image).stem
    else:
        img, default_point = _make_synthetic_image()
        in_name = "synthetic"
        img.save(out_dir / f"{in_name}_input.png")

    point_arg = tuple(args.point) if args.point else default_point
    point_xy = _parse_point(point_arg)
    box_xyxy = _parse_box(tuple(args.box) if args.box else None)

    device = _best_device(args.device)
    image_rgb = np.array(img, dtype=np.uint8)

    t0 = time.time()
    result = _run_predict(
        model_cfg=model_cfg,
        checkpoint=checkpoint,
        image_rgb=image_rgb,
        point_xy=point_xy,
        box_xyxy=box_xyxy,
        device=device,
        multimask=bool(args.multimask),
    )
    dt = time.time() - t0

    best_mask = result.masks[result.best_index]
    # SAM2 returns HxW (or 1xHxW); normalize to HxW.
    if best_mask.ndim == 3 and best_mask.shape[0] == 1:
        best_mask = best_mask[0]

    mask_path = out_dir / f"{in_name}_mask.png"
    overlay_path = out_dir / f"{in_name}_overlay.jpg"
    _save_mask(best_mask, mask_path)
    _save_overlay(image_rgb, best_mask, overlay_path)

    area = float(np.sum(best_mask > 0))
    print("SAM2 smoke test OK")
    print(f"  model_key:   {model_key}")
    print(f"  device:      {device}")
    print(f"  model_cfg:   {model_cfg}")
    print(f"  checkpoint:  {checkpoint}")
    print(f"  image:       {args.image or str(out_dir / f'{in_name}_input.png')}")
    print(f"  scores:      {result.scores.tolist()}")
    print(f"  best_index:  {result.best_index}")
    print(f"  mask_area:   {area:.0f} pixels")
    print(f"  elapsed:     {dt:.3f}s")
    print(f"  wrote:       {mask_path}")
    print(f"  wrote:       {overlay_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
