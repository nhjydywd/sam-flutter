from __future__ import annotations

import base64
import os
import threading
import time
import uuid
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
from typing import Any, Dict, List, Literal, Optional, Tuple

import numpy as np
from PIL import Image
from pydantic import BaseModel, Field


DEFAULT_MODEL_KEY = "sam2.1_hiera_tiny"


def _server_dir() -> Path:
    return Path(__file__).resolve().parent


def _best_device() -> str:
    # Env override.
    requested = os.environ.get("SAM2_DEVICE", "auto").strip().lower()
    if requested and requested != "auto":
        return requested

    import torch

    if torch.cuda.is_available():
        return "cuda"
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def _catalog() -> Dict[str, Dict[str, str]]:
    # Configs live inside the installed `sam2` Python package. We only need local checkpoints.
    base = _server_dir() / "models" / "sam2"
    return {
        "sam2.1_hiera_tiny": {
            "config": "configs/sam2.1/sam2.1_hiera_t.yaml",
            "checkpoint": str(base / "sam2.1_hiera_tiny.pt"),
        },
        "sam2.1_hiera_small": {
            "config": "configs/sam2.1/sam2.1_hiera_s.yaml",
            "checkpoint": str(base / "sam2.1_hiera_small.pt"),
        },
        "sam2.1_hiera_base_plus": {
            "config": "configs/sam2.1/sam2.1_hiera_b+.yaml",
            "checkpoint": str(base / "sam2.1_hiera_base_plus.pt"),
        },
        "sam2.1_hiera_large": {
            "config": "configs/sam2.1/sam2.1_hiera_l.yaml",
            "checkpoint": str(base / "sam2.1_hiera_large.pt"),
        },
    }


class ModelInfo(BaseModel):
    model_key: str
    device: str
    config: str
    checkpoint: str


class PredictRequest(BaseModel):
    # Coordinates are in pixel space (X, Y).
    points: Optional[List[List[float]]] = None
    labels: Optional[List[int]] = None  # 1=fg, 0=bg
    box: Optional[List[float]] = None  # [x0, y0, x1, y1]
    multimask: bool = False
    return_format: Literal["png_base64"] = "png_base64"


class PredictResponse(BaseModel):
    model: ModelInfo
    session_id: str
    score: float
    mask_area: int
    mask_png_base64: str = Field(..., description="PNG-encoded 8-bit mask (0/255) in base64")
    elapsed_ms: float


class SessionCreatedResponse(BaseModel):
    session_id: str
    model: ModelInfo


class SessionImageResponse(BaseModel):
    session_id: str
    width: int
    height: int
    elapsed_ms: float


class ModelManager:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._model_key: Optional[str] = None
        self._device: Optional[str] = None
        self._model = None

    def list_models(self) -> List[Dict[str, Any]]:
        out: List[Dict[str, Any]] = []
        for key, v in _catalog().items():
            ckpt = Path(v["checkpoint"])
            out.append(
                {
                    "model_key": key,
                    "config": v["config"],
                    "checkpoint": v["checkpoint"],
                    "downloaded": ckpt.is_file() and ckpt.stat().st_size > 0,
                    "checkpoint_size_bytes": int(ckpt.stat().st_size) if ckpt.is_file() else 0,
                }
            )
        return out

    def info(self) -> ModelInfo:
        key = self._model_key or DEFAULT_MODEL_KEY
        v = _catalog().get(key)
        if not v:
            # Shouldn't happen.
            v = _catalog()[DEFAULT_MODEL_KEY]
            key = DEFAULT_MODEL_KEY
        return ModelInfo(
            model_key=key,
            device=self._device or _best_device(),
            config=v["config"],
            checkpoint=v["checkpoint"],
        )

    def load(self, model_key: str) -> None:
        cfg = _catalog().get(model_key)
        if not cfg:
            raise ValueError(f"Unknown model_key: {model_key}")
        ckpt_path = Path(cfg["checkpoint"])
        if not (ckpt_path.is_file() and ckpt_path.stat().st_size > 0):
            raise FileNotFoundError(
                f"Checkpoint not found for '{model_key}': {ckpt_path}. "
                "Run './server/launch.sh' (downloads tiny) or 'python3 server/manage_model.py' (download others)."
            )

        with self._lock:
            if self._model_key == model_key and self._model is not None:
                return

            device = _best_device()
            from sam2.build_sam import build_sam2

            self._model = build_sam2(cfg["config"], str(ckpt_path), device=device)
            self._model_key = model_key
            self._device = device

    def predictor(self):
        # Ensure model loaded.
        self.load(self._model_key or DEFAULT_MODEL_KEY)
        with self._lock:
            from sam2.sam2_image_predictor import SAM2ImagePredictor

            return SAM2ImagePredictor(self._model)


@dataclass
class _Session:
    session_id: str
    predictor: Any
    lock: threading.Lock
    last_used: float
    width: int = 0
    height: int = 0


class SessionManager:
    def __init__(self, model_mgr: ModelManager) -> None:
        self._model_mgr = model_mgr
        self._lock = threading.Lock()
        self._sessions: Dict[str, _Session] = {}
        self._ttl_s = int(os.environ.get("SAM2_SESSION_TTL_S", "1800"))  # 30 min
        self._max_sessions = int(os.environ.get("SAM2_MAX_SESSIONS", "8"))

    def _gc(self) -> None:
        now = time.time()
        expired = [sid for sid, s in self._sessions.items() if now - s.last_used > self._ttl_s]
        for sid in expired:
            self._sessions.pop(sid, None)

        # Enforce max sessions (LRU-ish).
        if len(self._sessions) > self._max_sessions:
            by_old = sorted(self._sessions.values(), key=lambda s: s.last_used)
            for s in by_old[: max(0, len(self._sessions) - self._max_sessions)]:
                self._sessions.pop(s.session_id, None)

    def clear(self) -> None:
        with self._lock:
            self._sessions.clear()

    def count(self) -> int:
        with self._lock:
            self._gc()
            return len(self._sessions)

    def create(self) -> str:
        with self._lock:
            self._gc()
            if len(self._sessions) >= self._max_sessions:
                # After GC, still full.
                raise RuntimeError("too many sessions")
            sid = uuid.uuid4().hex
            predictor = self._model_mgr.predictor()
            self._sessions[sid] = _Session(
                session_id=sid,
                predictor=predictor,
                lock=threading.Lock(),
                last_used=time.time(),
            )
            return sid

    def delete(self, session_id: str) -> None:
        with self._lock:
            self._sessions.pop(session_id)

    def _get(self, session_id: str) -> _Session:
        with self._lock:
            self._gc()
            s = self._sessions.get(session_id)
            if not s:
                raise KeyError(session_id)
            s.last_used = time.time()
            return s

    def set_image(self, session_id: str, image_bytes: bytes) -> SessionImageResponse:
        s = self._get(session_id)
        t0 = time.time()
        img = Image.open(BytesIO(image_bytes)).convert("RGB")
        arr = np.asarray(img, dtype=np.uint8)
        with s.lock:
            s.predictor.set_image(arr)
            s.width, s.height = img.width, img.height
        dt = (time.time() - t0) * 1000.0
        return SessionImageResponse(session_id=session_id, width=img.width, height=img.height, elapsed_ms=dt)

    def predict(self, session_id: str, req: PredictRequest) -> PredictResponse:
        s = self._get(session_id)
        if req.points is None and req.box is None:
            raise ValueError("Either points or box must be provided.")
        if req.points is not None:
            if req.labels is None or len(req.labels) != len(req.points):
                raise ValueError("labels must be provided and have the same length as points.")
            pts = np.asarray(req.points, dtype=np.float32)
            lbs = np.asarray(req.labels, dtype=np.int32)
        else:
            pts = None
            lbs = None

        box = np.asarray(req.box, dtype=np.float32) if req.box is not None else None

        t0 = time.time()
        with s.lock:
            try:
                masks, scores, _low_res = s.predictor.predict(
                    point_coords=pts,
                    point_labels=lbs,
                    box=box,
                    multimask_output=bool(req.multimask),
                )
            except RuntimeError as e:
                # Most common: predict called before set_image.
                raise ValueError(str(e)) from e
        dt = (time.time() - t0) * 1000.0

        if masks is None or len(masks) == 0:
            raise ValueError("model returned no masks")

        scores_np = np.asarray(scores, dtype=np.float32)
        best = int(np.argmax(scores_np))
        best_mask = masks[best]
        if best_mask.ndim == 3 and best_mask.shape[0] == 1:
            best_mask = best_mask[0]

        mask_area = int(np.sum(best_mask > 0))

        # PNG encode mask (0/255).
        m8 = (best_mask.astype(np.uint8) * 255) if best_mask.dtype != np.uint8 else best_mask
        out = BytesIO()
        Image.fromarray(m8).save(out, format="PNG")
        b64 = base64.b64encode(out.getvalue()).decode("ascii")

        return PredictResponse(
            model=self._model_mgr.info(),
            session_id=session_id,
            score=float(scores_np[best]),
            mask_area=mask_area,
            mask_png_base64=b64,
            elapsed_ms=dt,
        )
