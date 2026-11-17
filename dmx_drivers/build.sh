#!/usr/bin/env bash
# Build the Art-Net DMX driver set: artnet_node.c4z, dmx_light.c4z, dmx_mover.c4z -> dist/
#
#   ./build.sh            build all three, then run the unit tests and the harness scenarios
#   ./build.sh dmx_light  build one driver (tests still run against whatever is staged)
#
# Per driver: compile + scope-check every source, bundle main.lua + modules into one driver.lua,
# expand driver.xml, cross-check properties/actions, bump the integer <version> if the package
# changed, stamp @BUILD@, zip. The c4z NAMES are load-bearing (the node finds its peers with
# GetDevicesByC4iName("artnet_node.c4z")), so they are never suffixed.
set -euo pipefail
cd "$(dirname "$0")"

DRIVERS=("${@:-artnet_node dmx_light dmx_mover}")
# shellcheck disable=SC2206
DRIVERS=(${DRIVERS[@]})
PRODUCT_VERSION="$(tr -d '[:space:]' < VERSION)"
command -v luajit >/dev/null || { echo "ERROR: luajit is required (brew install luajit): Director runs drivers under LuaJIT"; exit 1; }
mkdir -p dist build

for NAME in "${DRIVERS[@]}"; do
  echo "=== $NAME"
  STAGE="build/$NAME"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"

  # 1. Every source compiles under LuaJIT (5.1 syntax: catches 5.3+ operators luac 5.5 accepts).
  for f in common/*.lua "$NAME"/*.lua; do
    luajit -bl "$f" >/dev/null || { echo "ERROR: $f does not compile"; exit 1; }
    # luac/luajit do NOT catch a local used before its declaration (compiles to a nil global).
    python3 tools/scopecheck.py "$f" >/dev/null || { python3 tools/scopecheck.py "$f"; exit 1; }
  done

  # 2. Bundle.
  python3 tools/bundle.py "$NAME" "$STAGE/driver.lua"
  luajit -bl "$STAGE/driver.lua" >/dev/null || { echo "ERROR: bundled driver.lua does not compile"; exit 1; }

  # 3. driver.xml with the 32 Custom channel property pairs expanded.
  python3 - "$NAME/driver.xml" "$STAGE/driver.xml" <<'PYEOF'
import sys
src, out = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8').read()
marker = '<!-- @CUSTOM_CHANNELS@ -->'
if marker in s:
    block = []
    for i in range(1, 33):
        block.append('''<property>
        <name>Channel %d Function</name>
        <type>DYNAMIC_LIST</type>
        <default>Unused</default>
      </property>
      <property>
        <name>Channel %d Default</name>
        <type>RANGED_INTEGER</type>
        <minimum>0</minimum>
        <maximum>255</maximum>
        <default>0</default>
      </property>''' % (i, i))
    s = s.replace(marker, '\n      '.join(block))
# dmx_light only: the 12 rows of one pixel's channel group.
marker = '<!-- @PIXEL_CHANNELS@ -->'
if marker in s:
    block = []
    for i in range(1, 13):
        block.append('''<property>
        <name>Pixel Channel %d Function</name>
        <type>DYNAMIC_LIST</type>
        <default>Unused</default>
        <tooltip>What channel %d of every pixel does. Every pixel repeats the same functions in the same order.</tooltip>
      </property>
      <property>
        <name>Pixel Channel %d Default</name>
        <type>RANGED_INTEGER</type>
        <minimum>0</minimum>
        <maximum>255</maximum>
        <default>0</default>
        <tooltip>Value sent when nothing else sets this channel. Only matters for Fixed Value and Unused, and for controls set from programming.</tooltip>
      </property>''' % (i, i, i))
    s = s.replace(marker, '\n      '.join(block))
open(out, 'w', encoding='utf-8').write(s)
PYEOF
  cp -R "$NAME/www" "$STAGE/"

  # 4. Static cross-checks on what will actually ship.
  python3 tools/checks.py "$STAGE" "$NAME"

  # 5. Version: bump the integer <version> in the SOURCE driver.xml if the package content changed
  #    since the last build (Composer refuses an update whose version is unchanged).
  python3 - "$NAME" "$STAGE" "$PRODUCT_VERSION" <<'PYEOF'
import sys, os, re, zipfile, hashlib
name, stage, product = sys.argv[1], sys.argv[2], sys.argv[3]
out = os.path.join('dist', name + '.c4z')
def digest(files):
    h = hashlib.sha256()
    for k in sorted(files):
        h.update(k.encode()); h.update(re.sub(rb'<version>\d+</version>', b'', files[k]))
    return h.hexdigest()
current = {}
for root, _, fs in os.walk(stage):
    for f in fs:
        p = os.path.join(root, f)
        current[os.path.relpath(p, stage).replace(os.sep, '/')] = open(p, 'rb').read()
current['VERSION'] = product.encode()
src_xml = os.path.join(name, 'driver.xml')
src = open(src_xml, encoding='utf-8').read()
cur = int(re.search(r'<version>(\d+)</version>', src).group(1))
if os.path.exists(out):
    with zipfile.ZipFile(out) as z:
        old = {n: z.read(n) for n in z.namelist() if not n.endswith('/')}
    stamp = re.compile(rb'v[\d.]+ \(build \d+, [0-9a-f]{8}\)')
    old = {k: stamp.sub(b'@BUILD@', v) for k, v in old.items()}
    m = re.search(rb'v([\d.]+) \(build', old.get('driver.lua', b'') or b'')
    old_product = None
    zold = zipfile.ZipFile(out)
    for n in zold.namelist():
        mm = re.search(rb'v([\d.]+) \(build \d+', zold.read(n))
        if mm: old_product = mm.group(1).decode(); break
    old['VERSION'] = (old_product or '').encode()
    old_ver = int(re.search(rb'<version>(\d+)</version>', old['driver.xml']).group(1))
    if digest(old) != digest(current) and cur <= old_ver:
        cur = old_ver + 1
        open(src_xml, 'w', encoding='utf-8').write(re.sub(r'<version>\d+</version>', '<version>%d</version>' % cur, src, count=1))
        print('content changed: <version> bumped to %d' % cur)
    else:
        print('<version> %d (%s)' % (cur, 'unchanged content' if digest(old) == digest(current) else 'already ahead'))
else:
    print('<version> %d (first build)' % cur)
staged = os.path.join(stage, 'driver.xml')
s = open(staged, encoding='utf-8').read()
open(staged, 'w', encoding='utf-8').write(re.sub(r'<version>\d+</version>', '<version>%d</version>' % cur, s, count=1))
PYEOF

  # 6. Stamp the product version, build number and a content fingerprint into every @BUILD@.
  BUILDNO="$(grep -o '<version>[0-9]*</version>' "$STAGE/driver.xml" | head -1 | tr -cd '0-9')"
  FINGERPRINT="$(cat "$STAGE/driver.lua" "$NAME/driver.xml" | shasum -a 256 | cut -c1-8)"
  python3 - "$STAGE" "v$PRODUCT_VERSION (build $BUILDNO, $FINGERPRINT)" <<'PYEOF'
import sys, os
stage, stamp = sys.argv[1], sys.argv[2]
total = 0
for name in ('driver.lua', 'driver.xml'):
    p = os.path.join(stage, name)
    s = open(p, encoding='utf-8').read()
    total += s.count('@BUILD@')
    open(p, 'w', encoding='utf-8').write(s.replace('@BUILD@', stamp))
if total < 2:
    print('ERROR: expected @BUILD@ in both driver.lua and driver.xml, found %d' % total); sys.exit(1)
print('stamped "%s"' % stamp)
PYEOF

  # 7. Package: files at the zip root.
  rm -f "dist/$NAME.c4z"
  ( cd "$STAGE" && zip -qr "../../dist/$NAME.c4z" . -x '*.DS_Store' )
  echo "dist/$NAME.c4z ($(wc -c < "dist/$NAME.c4z" | tr -d ' ') bytes)"
done

echo "=== tests"
luajit test/unit.lua | tail -1
luajit test/scenarios.lua | tail -1
