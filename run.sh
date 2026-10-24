#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -x build/Seear.app/Contents/MacOS/SeearDemo ]]; then bash build.sh; fi
open -n build/Seear.app
