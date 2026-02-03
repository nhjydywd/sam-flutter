from __future__ import annotations

import os
import socket
from typing import Any, Dict, Optional

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware

from server.service_sam2 import (
    DEFAULT_MODEL_KEY,
    ModelManager,
    PredictRequest,
    PredictResponse,
    SessionCreatedResponse,
    SessionImageResponse,
    SessionManager,
)


app = FastAPI(title="sam-flutter", version="0.1.0")

# Dev-friendly CORS; tighten this when exposing beyond localhost/LAN.
_cors = os.environ.get("SAM2_CORS_ALLOW_ORIGINS", "*")
if _cors:
    allow_origins = ["*"] if _cors.strip() == "*" else [o.strip() for o in _cors.split(",") if o.strip()]
    app.add_middleware(
        CORSMiddleware,
        allow_origins=allow_origins,
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )


model_mgr = ModelManager()
session_mgr = SessionManager(model_mgr=model_mgr)


@app.on_event("startup")
def _startup() -> None:
    # Fail fast if the environment can't load the default model.
    eager = os.environ.get("SAM2_EAGER_LOAD", "1").strip() not in ("0", "false", "False")
    if eager:
        try:
            model_mgr.load(DEFAULT_MODEL_KEY)
        except Exception as e:
            # Re-raise as RuntimeError so Uvicorn shows it clearly.
            raise RuntimeError(f"Failed to load SAM2 model '{DEFAULT_MODEL_KEY}': {e}") from e

    # Print LAN IP hint for GUI connection from other devices
    port = os.environ.get("SAM2_SERVER_PORT", "8000")
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        lan_ip = s.getsockname()[0]
        s.close()
        print(f"\n  To connect from other devices on your network, use: http://{lan_ip}:{port}\n")
    except Exception:
        pass  # Network unavailable, skip hint


@app.get("/health")
def health() -> Dict[str, Any]:
    info = model_mgr.info()
    return {
        "ok": True,
        "model": info,
        "sessions": session_mgr.count(),
    }


@app.get("/models")
def models() -> Dict[str, Any]:
    return {
        "default": DEFAULT_MODEL_KEY,
        "available": model_mgr.list_models(),
        "current": model_mgr.info(),
    }


@app.post("/model/select")
def select_model(payload: Dict[str, Any]) -> Dict[str, Any]:
    key = payload.get("model_key")
    if not isinstance(key, str) or not key:
        raise HTTPException(status_code=400, detail="model_key is required")
    try:
        model_mgr.load(key)
        # Changing the global model invalidates any session predictors/features.
        session_mgr.clear()
    except FileNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    return {"ok": True, "model": model_mgr.info()}


@app.post("/sessions", response_model=SessionCreatedResponse)
def create_session(payload: Optional[Dict[str, Any]] = None) -> SessionCreatedResponse:
    # Optional: allow creating a session while selecting a model.
    model_key = None
    if payload and isinstance(payload, dict):
        mk = payload.get("model_key")
        if isinstance(mk, str) and mk:
            model_key = mk
    if model_key:
        try:
            model_mgr.load(model_key)
            session_mgr.clear()
        except FileNotFoundError as e:
            raise HTTPException(status_code=404, detail=str(e)) from e
    sid = session_mgr.create()
    return SessionCreatedResponse(session_id=sid, model=model_mgr.info())


@app.post("/sessions/{session_id}/image", response_model=SessionImageResponse)
async def set_image(session_id: str, file: UploadFile = File(...)) -> SessionImageResponse:
    if not file:
        raise HTTPException(status_code=400, detail="file is required")
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="empty upload")
    try:
        return session_mgr.set_image(session_id=session_id, image_bytes=data)
    except KeyError:
        raise HTTPException(status_code=404, detail="session not found")


@app.post("/sessions/{session_id}/predict", response_model=PredictResponse)
def predict(session_id: str, req: PredictRequest) -> PredictResponse:
    try:
        return session_mgr.predict(session_id=session_id, req=req)
    except KeyError:
        raise HTTPException(status_code=404, detail="session not found")
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.delete("/sessions/{session_id}")
def delete_session(session_id: str) -> Dict[str, Any]:
    try:
        session_mgr.delete(session_id)
        return {"ok": True}
    except KeyError:
        raise HTTPException(status_code=404, detail="session not found")
