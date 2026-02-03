# Server Utilities

## One-click HTTP server

One-click launch (creates venv if needed, installs deps, downloads the smallest SAM2.1 model, then starts HTTP):

```bash
./server/launch.sh
```

By default it listens on `0.0.0.0:8000`. Override with:

```bash
SAM2_SERVER_HOST=127.0.0.1 SAM2_SERVER_PORT=8000 ./server/launch.sh
```

Open endpoints:

- `GET /health`
- `GET /models`
- `POST /model/select`
- `POST /sessions`
- `POST /sessions/{session_id}/image` (multipart upload)
- `POST /sessions/{session_id}/predict` (JSON prompts)
- `DELETE /sessions/{session_id}`

FastAPI docs:

- `GET /docs`

### Model downloads

Interactive model manager (prints present/missing; lets you download by index or 'a' for all):

```bash
python3 server/manage_model.py
```

Note: `./server/launch.sh` downloads **the smallest checkpoint (sam2.1_hiera_tiny)** for fast verification.
If you need better quality, use `python3 server/manage_model.py` to download larger checkpoints and then
call `POST /model/select` with the desired `model_key`.
