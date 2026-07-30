#!/usr/bin/env bash
# Build Yamaha-YAS108.c4z (zip of driver files at archive root).
#
# The YAS-108 is IR only - no certificate, no network, nothing to bundle beyond the driver
# files themselves. Everything is staged in a temp dir so a failed build cannot leave a
# half-made c4z behind.
set -euo pipefail
cd "$(dirname "$0")"

OUT="Yamaha-YAS108.c4z"
CERT_SRC=""   # none: the YAS-108 has no network interface

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

# Composer caches drivers BY VERSION: install a .c4z whose <version> matches the one already in
# the project and it refuses with "versions are equal" -- the new code never loads. Bumping by
# hand is the step that gets forgotten, so the build does it: if the driver content changed but
# the version did not, increment it. An unchanged rebuild keeps its version, so this does not
# churn the number while iterating.
python3 - <<'PYEOF' || exit 1
import re, sys, zipfile, os
OUT = "Yamaha-YAS108.c4z"
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
