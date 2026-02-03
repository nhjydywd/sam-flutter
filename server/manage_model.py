#!/usr/bin/env python3
"""
Model manager for this repo.

Supports downloading model weights for:
  - SAM2.1: 4 checkpoints (hiera_tiny/small/base_plus/large) + their config YAMLs

It prints which models are already present under server/models/, which are missing,
then prompts you to download by index (or 'a' to download all missing).
"""

from __future__ import annotations

import argparse
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Sequence


@dataclass(frozen=True)
class ModelSpec:
    key: str
    family: str
    filename: str
    url: str

    def local_path(self, repo_root: Path) -> Path:
        return repo_root / "server" / "models" / self.family / self.filename


def _repo_root() -> Path:
    # This file lives at <root>/server/manage_model.py
    return Path(__file__).resolve().parents[1]


def _catalog() -> List[ModelSpec]:
    # SAM2.1 official checkpoints (recommended)
    sam2_base = "https://dl.fbaipublicfiles.com/segment_anything_2/092824"
    sam2_1 = [
        ModelSpec(
            key="sam2.1_hiera_tiny",
            family="sam2",
            filename="sam2.1_hiera_tiny.pt",
            url=f"{sam2_base}/sam2.1_hiera_tiny.pt",
        ),
        ModelSpec(
            key="sam2.1_hiera_small",
            family="sam2",
            filename="sam2.1_hiera_small.pt",
            url=f"{sam2_base}/sam2.1_hiera_small.pt",
        ),
        ModelSpec(
            key="sam2.1_hiera_base_plus",
            family="sam2",
            filename="sam2.1_hiera_base_plus.pt",
            url=f"{sam2_base}/sam2.1_hiera_base_plus.pt",
        ),
        ModelSpec(
            key="sam2.1_hiera_large",
            family="sam2",
            filename="sam2.1_hiera_large.pt",
            url=f"{sam2_base}/sam2.1_hiera_large.pt",
        ),
    ]

    return sam2_1


def _is_present(path: Path) -> bool:
    try:
        return path.is_file() and path.stat().st_size > 0
    except FileNotFoundError:
        return False


def _model_present(m: ModelSpec, root: Path) -> bool:
    return _is_present(m.local_path(root))


def _fmt_size(num_bytes: int) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    n = float(num_bytes)
    for u in units:
        if n < 1024.0 or u == units[-1]:
            if u == "B":
                return f"{int(n)}{u}"
            return f"{n:.1f}{u}"
        n /= 1024.0
    return f"{num_bytes}B"


def _download(url: str, out_path: Path, timeout_s: int = 60) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = out_path.with_suffix(out_path.suffix + ".part")

    if tmp_path.exists():
        # Start fresh; .part might be from an interrupted run.
        try:
            tmp_path.unlink()
        except OSError:
            pass

    req = urllib.request.Request(url, headers={"User-Agent": "sam-flutter-model-manager/1.0"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            total = resp.headers.get("Content-Length")
            total_bytes = int(total) if total and total.isdigit() else None

            downloaded = 0
            last_print = 0.0
            with tmp_path.open("wb") as f:
                while True:
                    chunk = resp.read(1024 * 1024)  # 1MB
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)
                    now = time.time()
                    if now - last_print >= 0.5:
                        if total_bytes:
                            pct = (downloaded / total_bytes) * 100.0
                            print(
                                f"  {_fmt_size(downloaded)} / {_fmt_size(total_bytes)} ({pct:.1f}%)",
                                end="\r",
                                flush=True,
                            )
                        else:
                            print(f"  {_fmt_size(downloaded)}", end="\r", flush=True)
                        last_print = now
    except urllib.error.HTTPError as e:
        raise SystemExit(f"HTTP error downloading {url}: {e.code} {e.reason}") from e
    except urllib.error.URLError as e:
        raise SystemExit(f"Network error downloading {url}: {e}") from e

    tmp_path.replace(out_path)
    dt = time.time() - t0
    print(" " * 80, end="\r")  # clear progress line
    print(f"  done in {dt:.1f}s -> {out_path}")


def _print_inventory(models: Sequence[ModelSpec], root: Path) -> None:
    sam2_count = sum(1 for m in models if m.family == "sam2")
    print(f"SAM2.1 models: {sam2_count}")
    print()
    existing: List[ModelSpec] = []
    missing: List[ModelSpec] = []
    for m in models:
        (existing if _model_present(m, root) else missing).append(m)

    if existing:
        print("Already present:")
        for m in existing:
            ckpt_path = m.local_path(root)
            ckpt_size = _fmt_size(ckpt_path.stat().st_size)
            print(f"  - {m.key:22s} {ckpt_size:>8s}  ({ckpt_path})")
    else:
        print("Already present: (none)")

    print()
    if missing:
        print("Missing (select by index to download):")
        for idx, m in enumerate(missing, start=1):
            ckpt_path = m.local_path(root)
            print(f"  [{idx:2d}] {m.key:22s} -> {ckpt_path}")
    else:
        print("Missing: (none)")
    print()


def _parse_selection(sel: str, max_index: int) -> List[int]:
    parts = [p for p in sel.replace(",", " ").split(" ") if p.strip()]
    out: List[int] = []
    for p in parts:
        if p.isdigit():
            i = int(p)
            if not (1 <= i <= max_index):
                raise ValueError(f"Index out of range: {i}")
            out.append(i)
        else:
            raise ValueError(f"Invalid token: {p!r}")
    # Deduplicate but preserve order
    seen = set()
    dedup: List[int] = []
    for i in out:
        if i not in seen:
            seen.add(i)
            dedup.append(i)
    return dedup


def _missing_models(models: Sequence[ModelSpec], root: Path) -> List[ModelSpec]:
    return [m for m in models if not _model_present(m, root)]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--root",
        default=None,
        help="Repo root (default: auto-detect from this file location).",
    )
    ap.add_argument(
        "--non-interactive",
        action="store_true",
        help="Just print inventory and exit (no downloads).",
    )
    args = ap.parse_args()

    root = Path(args.root).resolve() if args.root else _repo_root()
    models = _catalog()

    _print_inventory(models, root)
    if args.non_interactive:
        return 0

    missing = _missing_models(models, root)
    if not missing:
        print("Nothing to download.")
        return 0

    while True:
        sel = input(
            "Select models to download by index (e.g. '1 3 5'), 'a' for all missing, or 'q' to quit: "
        ).strip()
        if not sel:
            continue
        if sel.lower() == "q":
            return 0
        if sel.lower() == "a":
            chosen = list(range(1, len(missing) + 1))
            break
        try:
            chosen = _parse_selection(sel, max_index=len(missing))
        except ValueError as e:
            print(f"Invalid selection: {e}")
            continue
        break

    # Download selected
    for idx in chosen:
        m = missing[idx - 1]
        if _model_present(m, root):
            print(f"Skip (already present): {m.key}")
            continue

        print(f"Downloading [{idx}] {m.key}")
        out_path = m.local_path(root)
        if not _is_present(out_path):
            print(f"  url:  {m.url}")
            print(f"  to:   {out_path}")
            _download(m.url, out_path)

    print()
    print("Done.")
    _print_inventory(models, root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
