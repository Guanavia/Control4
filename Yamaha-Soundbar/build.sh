#!/usr/bin/env bash
# Build Yamaha-Soundbar.c4z (zip of driver files at archive root).
#
# Bundles the Linkplay client cert (gray-area, local-only, gitignored) so the IP
# power/input path works when Owner Approved = Yes. Regenerate the cert per
# research/LINKPLAY_RE.md if missing.
#
# The bundled PEM is referenced by driver.xml's SSL connection (binding 6002 / port 443)
# as <certificate>, <private_key> AND <cacert> at once -- Control4 explicitly allows one
# file to serve all three.
#
#   ./build.sh                 -> plain private key, <private_key> with no attribute.
#   ENCRYPT_KEY=1 ./build.sh   -> re-encrypts the key with the driver's passphrase and
#                                 stamps protected="True" onto <private_key>, which makes
#                                 Director call GetPrivateKeyPassword() in driver.lua.
#                                 Use this if the plain key is rejected on hardware.
#
# Everything is staged in a temp dir, so the project folder is never polluted and a
# failed build cannot leave a half-made c4z behind.
set -euo pipefail
cd "$(dirname "$0")"

OUT="Yamaha-Soundbar.c4z"
CERT_SRC="research/linkplay_keys/linkplay_client.pem"
ENCRYPT_KEY="${ENCRYPT_KEY:-0}"
# MUST match HTTPAPI_KEY_PASSWORD in driver.lua.
KEY_PASSWORD="yas209-linkplay"

# Validate before packaging.  Both of these have shipped broken at least once:
#   * driver.lua failing to compile,
#   * driver.xml containing "--" INSIDE an XML comment, which is illegal and makes Director
#     reject the whole file.  Easy to write by accident when using -- as a dash in prose.
command -v luac >/dev/null && { luac -p driver.lua || { echo "ERROR: driver.lua does not compile"; exit 1; }; }
python3 - <<'PYEOF' || exit 1
import re, sys, xml.dom.minidom as dom
src = open('driver.xml').read()
bad = [c for c in re.findall(r'<!--.*?-->', src, re.S) if '--' in c[4:-3]]
if bad:
    print('ERROR: illegal "--" inside an XML comment (%d):' % len(bad))
    for c in bad[:5]:
        print('   ', ' '.join(c[:120].split()))
    sys.exit(1)
try:
    dom.parseString(src)
except Exception as e:
    print('ERROR: driver.xml is not well-formed:', e); sys.exit(1)
print('driver.xml OK')
PYEOF

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp driver.xml driver.lua "$STAGE/"
cp -R www "$STAGE/"

if [ -f "$CERT_SRC" ]; then
  if [ "$ENCRYPT_KEY" = "1" ]; then
    echo "re-encrypting the private key (protected=\"True\" mode)"
    # certificates verbatim, private key re-encrypted under KEY_PASSWORD
    awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$CERT_SRC" > "$STAGE/linkplay_client.pem"
    openssl pkcs8 -topk8 -v2 aes-256-cbc \
      -in "$CERT_SRC" -passout "pass:$KEY_PASSWORD" >> "$STAGE/linkplay_client.pem"
    sed -i '' 's|<private_key>\./linkplay_client\.pem</private_key>|<private_key protected="True">./linkplay_client.pem</private_key>|' \
      "$STAGE/driver.xml"
    grep -q 'protected="True"' "$STAGE/driver.xml" \
      || { echo "ERROR: could not stamp protected=\"True\" onto driver.xml"; exit 1; }
    echo "bundled client cert with an ENCRYPTED key (driver.lua supplies the passphrase)"
  else
    cp "$CERT_SRC" "$STAGE/linkplay_client.pem"
    echo "bundled client cert with a plain key (httpapi power/input enabled)"
  fi
  # Sanity-check what actually went in the bundle.
  echo "  contents: $(grep -c 'BEGIN CERTIFICATE' "$STAGE/linkplay_client.pem") certificate(s), key = $(
    grep -q 'BEGIN ENCRYPTED PRIVATE KEY' "$STAGE/linkplay_client.pem" && echo ENCRYPTED \
      || { grep -q 'PRIVATE KEY' "$STAGE/linkplay_client.pem" && echo plain || echo MISSING; })"
else
  echo "NOTE: $CERT_SRC not found - building WITHOUT the client cert."
  echo "      Volume/mute/transport (UPnP) will work; power/input over IP will not."
fi

rm -f "$OUT"
( cd "$STAGE" && zip -r "$OLDPWD/$OUT" . -x '*.DS_Store' -x '__MACOSX*' >/dev/null )
echo "Built $OUT"
unzip -l "$OUT"
