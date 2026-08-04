#!/usr/bin/env bash
# Build Yamaha-YAS209.c4z (zip of driver files at archive root).
#
# Bundles the Linkplay client cert (gray-area, local-only, gitignored) so the IP
# power/input path works when Control Method = IP. Regenerate the cert per
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

OUT="Yamaha-YAS209.c4z"
CERT_SRC="research/linkplay_keys/linkplay_client.pem"
ENCRYPT_KEY="${ENCRYPT_KEY:-0}"
# MUST match HTTPAPI_KEY_PASSWORD in driver.lua.
KEY_PASSWORD="yas209-linkplay"

# Validate before packaging.  Both of these have shipped broken at least once:
#   * driver.lua failing to compile,
#   * driver.xml containing "--" INSIDE an XML comment, which is illegal and makes Director
#     reject the whole file.  Easy to write by accident when using -- as a dash in prose.
command -v luac >/dev/null && { luac -p driver.lua || { echo "ERROR: driver.lua does not compile"; exit 1; }; }
# luac -p does NOT catch a local used before its declaration: Lua compiles that to a global
# lookup, which is nil at runtime and blows up only when the code path runs. This project has
# been bitten by it three times (C4:Log, C4:ReadFile, and jsonstr silently killing the input
# verification), so it is checked statically.
python3 scopecheck.py driver.lua || exit 1
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

# Composer caches drivers BY VERSION: install a .c4z whose <version> matches the one already in
# the project and it refuses with "versions are equal" -- the new code never loads. Bumping by
# hand is the step that gets forgotten, so the build does it: if the driver content changed but
# the version did not, increment it. An unchanged rebuild keeps its version, so this does not
# churn the number while iterating.
python3 - <<'PYEOF' || exit 1
import re, sys, zipfile, os
OUT = "Yamaha-YAS209.c4z"
src = open('driver.xml').read()
cur = int(re.search(r'<version>(\d+)</version>', src).group(1))
if not os.path.exists(OUT):
    print("version %d (no previous build to compare)" % cur); sys.exit(0)
try:
    with zipfile.ZipFile(OUT) as z:
        old_xml = z.read('driver.xml').decode()
        old_lua = z.read('driver.lua').decode()
except Exception as e:
    print("could not read previous %s (%s) - leaving version %d" % (OUT, e, cur)); sys.exit(0)
old = int(re.search(r'<version>(\d+)</version>', old_xml).group(1))
# Compare like for like. The PACKAGED copies have @BUILD@ already replaced by the stamp, so a raw
# comparison against the tokenised source always differs and the counter would climb on every
# build -- including builds where only a README changed. Un-stamp the packaged copies first.
UNSTAMP = re.compile(r'v[\d.]+ \(build \d+, [0-9a-f]{8}\)')
norm = lambda s: UNSTAMP.sub('@BUILD@', re.sub(r'<version>\d+</version>', '', s))
changed = (norm(old_xml) != norm(src)) or (norm(old_lua) != norm(open('driver.lua').read()))
# Also compare the packaged www/ content. A documentation-only edit is still a change Composer
# has to be told about: without a version bump it refuses the update as "versions are equal" and
# the dealer keeps reading the old docs. Caught when the rewritten documentation.rtf shipped
# without bumping.
if not changed:
    with zipfile.ZipFile(OUT) as z:
        packaged = {n: z.read(n) for n in z.namelist() if n.startswith('www/') and not n.endswith('/')}
    current = {}
    for root, _, files in os.walk('www'):
        for f in files:
            path = os.path.join(root, f)
            current[path.replace(os.sep, '/')] = open(path, 'rb').read()
    changed = packaged != current
# The PRODUCT version is stamped into the package, so changing ./VERSION changes what ships even
# when driver.lua and driver.xml are untouched. The comparison above un-stamps both sides, which
# makes a version-only change invisible to it - and Composer would then refuse the update as
# "versions are equal". Caught going 0.9.0 -> 1.0.0.
if not changed:
    m_old = re.search(r'v([\d.]+) \(build \d+, [0-9a-f]{8}\)', old_xml)
    cur_product = open('VERSION').read().strip() if os.path.exists('VERSION') else None
    if m_old and cur_product and m_old.group(1) != cur_product:
        print("product version changed %s -> %s" % (m_old.group(1), cur_product))
        changed = True

if changed and cur <= old:
    new = old + 1
    open('driver.xml', 'w').write(
        re.sub(r'<version>\d+</version>', '<version>%d</version>' % new, src, count=1))
    print("driver changed but version was %d (same as the last build) - BUMPED to %d" % (cur, new))
elif changed:
    print("version %d (previous build was %d)" % (cur, old))
else:
    print("version %d (content identical to the last build)" % cur)
PYEOF

# Documentation drift check (WARNING, not fatal). www/documentation.rtf is the reference an
# installer relies on, and a reference that silently omits a property is worse than none because
# the reader trusts it to be complete. Every property and Action must appear by name. This is a
# warning rather than an error so a work-in-progress build is never blocked.
python3 - <<'PYEOF'
import xml.etree.ElementTree as ET, sys, os
doc = 'www/documentation.rtf'
if not os.path.exists(doc):
    print('NOTE: no documentation.rtf to check'); sys.exit(0)
text = open(doc, encoding='utf-8', errors='replace').read()
r = ET.parse('driver.xml').getroot()
names  = [p.findtext('name') for p in r.find('config/properties')]
# Action names carry parenthetical hints; match on the part before the bracket.
names += [a.findtext('name').split(' (')[0] for a in r.find('config/actions')]
missing = [n for n in names if n and n not in text]
if missing:
    print('WARNING: not documented in www/documentation.rtf: ' + ', '.join(missing))
else:
    print('documentation covers all %d properties and actions' % len(names))
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
  echo "      Volume/mute (UPnP) will work; power/input over IP will not."
fi

# Stamp the packaged version and a content fingerprint into the driver's load line, which logs
# through the unsilenceable path. That line is the ONLY way to confirm which build a controller
# is actually running -- "I updated the driver" and "Composer kept the old one" look identical
# from Composer, and this project has already lost a session to that.
# TWO different versions, deliberately kept apart:
#   * PRODUCT version (./VERSION) - semantic, human-facing, what we call the driver. Pre-release
#     is 0.x; the FIRST RELEASE is 1.0.0. Edit ./VERSION by hand when the product moves.
#   * <version> in driver.xml - a plain INTEGER build counter, auto-bumped above. It exists only
#     so Composer can tell one package from the next; the catalog confirms nobody puts a semantic
#     version here (Pioneer VSX-LX503 = 117, Onkyo TX-NR747 = 104). Not human-facing.
PRODUCT_VERSION="$(tr -d '[:space:]' < VERSION)"
BUILDNO="$(grep -o '<version>[0-9]*</version>' "$STAGE/driver.xml" | head -1 | tr -cd '0-9')"
FINGERPRINT="$(cat driver.lua driver.xml | shasum -a 256 | cut -c1-8)"
python3 - "$STAGE" "$PRODUCT_VERSION" "$BUILDNO" "$FINGERPRINT" <<'PYEOF'
import sys, os
stage, product, buildno, fp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
stamp = 'v%s (build %s, %s)' % (product, buildno, fp)
total = 0
for name in ('driver.lua', 'driver.xml'):
    path = os.path.join(stage, name)
    s = open(path).read()
    n = s.count('@BUILD@')
    if n:
        open(path, 'w').write(s.replace('@BUILD@', stamp))
    total += n
if total == 0:
    print('ERROR: no @BUILD@ token found to stamp - the version display would be a lie')
    sys.exit(1)
print('stamped "%s" into %d place(s)' % (stamp, total))
PYEOF

rm -f "$OUT"
( cd "$STAGE" && zip -r "$OLDPWD/$OUT" . -x '*.DS_Store' -x '__MACOSX*' >/dev/null )
unzip -l "$OUT"
echo
echo "================================================================"
echo "  Built $OUT"
echo "  product version  : $PRODUCT_VERSION   <- what we call it (./VERSION; 1.0.0 = first release)"
echo "  driver <version> : $BUILDNO          <- integer build counter; Composer compares THIS"
echo "  fingerprint      : $FINGERPRINT"
echo "  package sha256   : $(shasum -a 256 "$OUT" | cut -c1-16)"
echo
echo "  On load the driver logs: \"v$PRODUCT_VERSION (build $BUILDNO, $FINGERPRINT)\""
echo "  If the controller logs a different build, Composer did not take this file."
echo "================================================================"
