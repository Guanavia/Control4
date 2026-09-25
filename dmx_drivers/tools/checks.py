#!/usr/bin/env python3
"""Static checks on a STAGED driver (driver.xml already expanded, driver.lua already bundled).

usage: checks.py <stage_dir> <source_dir>

Errors (exit 1):
  * driver.xml not well-formed, or "--" inside an XML comment (illegal; broke the YAS209 three times)
  * a property name the Lua reads/writes by literal string that driver.xml does not declare
    (Director hands back nil for an unknown property: the feature silently does nothing)
  * an Action whose <command> the Lua never mentions (the button would do nothing)
Warnings:
  * a property or Action missing from www/documentation.html
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

stage, source = sys.argv[1], sys.argv[2]
xml_path = os.path.join(stage, 'driver.xml')
src = open(xml_path, encoding='utf-8').read()
errors = []

bad = [c for c in re.findall(r'<!--.*?-->', src, re.S) if '--' in c[4:-3]]
if bad:
    errors.append('illegal "--" inside an XML comment: ' + ' '.join(bad[0][:100].split()))
try:
    root = ET.fromstring(src)
except ET.ParseError as e:
    print('ERROR: driver.xml is not well-formed:', e)
    sys.exit(1)

props = {p.findtext('name') for p in root.iter('property')}
actions = [(a.findtext('name'), a.findtext('command')) for a in root.iter('action')]
lua = open(os.path.join(stage, 'driver.lua'), encoding='utf-8').read()
code = re.sub(r'--\[\[.*?\]\]', '', lua, flags=re.S)
code = re.sub(r'--[^\n]*', '', code)

used = set(re.findall(r'Properties\["([^"]+)"\]', code))
used |= set(re.findall(r'(?:set_prop|show_prop)\("([^"]+)"\s*[,)]', code))
# Shared code may read properties only some drivers declare, if it says so explicitly:
#   -- @optional-properties: Name One, Name Two
optional = set()
for line in re.findall(r'--\s*@optional-properties:([^\n]*)', lua):
    optional |= {n.strip() for n in line.split(',') if n.strip()}
missing = sorted(n for n in used if n not in props and n not in optional)
if missing:
    errors.append('Lua uses properties driver.xml does not declare: ' + ', '.join(missing))

for name, command in actions:
    if not re.search(r'["\']%s["\']' % re.escape(command), code):
        errors.append('Action "%s" sends %s, which driver.lua never handles' % (name, command))

if errors:
    for e in errors:
        print('ERROR:', e)
    sys.exit(1)

doc = os.path.join(source, 'www', 'documentation.html')
if os.path.exists(doc):
    text = open(doc, encoding='utf-8').read()
    names = [p.findtext('name') for p in root.iter('property')
             if p.findtext('type') != 'LABEL' and not re.match(r'Channel \d+ ', p.findtext('name'))]
    names += [n for n, _ in actions]
    names += [c.findtext('name') for c in root.iter('command')]
    undocumented = [n for n in names if n and n not in text]
    if undocumented:
        print('WARNING: not in www/documentation.html: ' + ', '.join(undocumented))
    else:
        print('documentation covers every property, action and command')
else:
    print('WARNING: no www/documentation.html')
print('checks passed: %d properties, %d actions' % (len(props), len(actions)))
