#!/usr/bin/env bash
# Build Yamaha-SoundBar-YAS209.c4z — a zip of the driver files at the archive root.
# Excludes research/, the build script, README, VCS/OS cruft, and any prior .c4z.
set -euo pipefail

cd "$(dirname "$0")"
OUT="Yamaha-SoundBar-YAS209.c4z"

rm -f "$OUT"

# Files/dirs that ship inside the .c4z:
#   driver.xml, driver.lua, www/**
# Everything else in the folder is dev-only and excluded.
zip -r "$OUT" \
    driver.xml \
    driver.lua \
    www \
    -x '*.DS_Store' -x '__MACOSX*'

echo "Built $OUT"
unzip -l "$OUT"
