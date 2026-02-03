#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import uvicorn


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=os.environ.get("SAM2_SERVER_HOST", "0.0.0.0"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("SAM2_SERVER_PORT", "8000")))
    ap.add_argument("--log-level", default=os.environ.get("SAM2_SERVER_LOG_LEVEL", "info"))
    ap.add_argument("--reload", action="store_true", help="Dev mode auto-reload (not recommended with MPS).")
    args = ap.parse_args()

    # Make `import server.*` work even if the user runs from inside `server/`.
    repo_root = Path(__file__).resolve().parents[1]
    if str(repo_root) not in sys.path:
        sys.path.insert(0, str(repo_root))

    uvicorn.run(
        "server.app:app",
        host=args.host,
        port=args.port,
        log_level=args.log_level,
        reload=bool(args.reload),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
