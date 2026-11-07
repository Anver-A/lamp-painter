#!/bin/bash
# Runs the in-game automated test (phase 1) headless in a throwaway data folder.
# Usage: tools/run-tests.sh [path-to-factorio-binary]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FX=${1:-"$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio"}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/mods" "$W/data"
cp -R "$ROOT/lamp-painter" "$ROOT/lamp-painter-test" "$W/mods/"
cat > "$W/mods/mod-list.json" <<'JSON'
{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":true},{"name":"quality","enabled":true},
{"name":"space-age","enabled":true},{"name":"lamp-painter","enabled":true},{"name":"lamp-painter-test","enabled":true}]}
JSON
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$W/data" > "$W/config.ini"
"$FX" -c "$W/config.ini" --mod-directory "$W/mods" --test-scenario lamp-painter-test/lamp-test \
  --test-arg phase1 --test-ticks 6000 --disable-audio > "$W/out.txt" 2>&1 || true
LOG="$W/data/factorio-current.log"
grep -E 'LP-TEST|CHECK FAILED|Error' "$LOG" | sed 's/.*Script/Script/' || true
grep -q 'LP-TEST phase1 passed' "$LOG"
