#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh
swift test --scratch-path .build
.venv/bin/python -m unittest discover -s vision/tests -v
build/Seear.app/Contents/MacOS/SeearDemo --audio-check
codesign --verify --deep --strict build/Seear.app
echo "Automated checks passed. Run the signed app for hardware acceptance."
