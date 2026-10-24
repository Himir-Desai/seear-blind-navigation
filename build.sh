#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --scratch-path .build
APP="build/Seear.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SeearDemo "$APP/Contents/MacOS/SeearDemo"
python3 - <<'PY'
from pathlib import Path
import plistlib
root = Path.cwd()
with (root / 'Resources/Info.plist').open('rb') as f:
    info = plistlib.load(f)
info['SeearProjectRoot'] = str(root)
with (root / 'build/Seear.app/Contents/Info.plist').open('wb') as f:
    plistlib.dump(info, f)
PY
codesign --force --options runtime --entitlements Resources/Seear.entitlements --identifier com.seear.demo1 --sign "${CODESIGN_ID:--}" "$APP"
echo "Built $APP"
