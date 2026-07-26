#!/usr/bin/env bash
# Build Yamaha-SoundBar-YAS209.c4z (zip of driver files at archive root).
# Bundles the Linkplay client cert (gray-area, local-only, gitignored) so the IP
# power/input path works when Owner Approved = Yes. Regenerate the cert per
# research/LINKPLAY_RE.md if missing.
set -euo pipefail
cd "$(dirname "$0")"
OUT="Yamaha-SoundBar-YAS209.c4z"
rm -f "$OUT"

CERT_SRC="research/linkplay_keys/linkplay_client.pem"
if [ -f "$CERT_SRC" ]; then
  cp "$CERT_SRC" ./linkplay_client.pem
  echo "bundled client cert (httpapi power/input enabled)"
else
  echo "NOTE: $CERT_SRC not found - building WITHOUT the client cert."
  echo "      Volume/mute/transport (UPnP) will work; power/input over IP will not."
fi

FILES="driver.xml driver.lua www"
[ -f ./linkplay_client.pem ] && FILES="$FILES linkplay_client.pem"

# shellcheck disable=SC2086
zip -r "$OUT" $FILES -x '*.DS_Store' -x '__MACOSX*'
echo "Built $OUT"
unzip -l "$OUT"
