#!/bin/bash
# Builds dist/lamp-painter_<version>.zip ready for the mod portal.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
V=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$ROOT/lamp-painter/info.json")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp -R "$ROOT/lamp-painter" "$T/lamp-painter_$V"
mkdir -p "$ROOT/dist"
(cd "$T" && zip -qrX "$ROOT/dist/lamp-painter_$V.zip" "lamp-painter_$V" -x '*.DS_Store')
echo "$ROOT/dist/lamp-painter_$V.zip"
