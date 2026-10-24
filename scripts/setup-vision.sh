#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r vision/requirements.txt
HF_HUB_DISABLE_TELEMETRY=1 .venv/bin/python -c 'import sys; sys.path.insert(0,"vision"); from backend import download_models; download_models()'
echo "Local models ready. Runtime inference uses cached files only."
