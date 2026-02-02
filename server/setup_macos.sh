#!/usr/bin/env bash
set -euo pipefail

# Deprecated: use ./server/launch.sh (it creates venv, installs deps, downloads tiny model, then runs).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${ROOT}/launch.sh" "$@"
