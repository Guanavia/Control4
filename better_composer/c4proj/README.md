# c4proj — Control4 project (.c4p) read/edit/repackage scaffold

Proof-of-concept core for a modern Composer replacement. Reads a Composer `.c4p`, exposes the
project as a navigable model, and writes a valid `.c4p` back — the round-trip a standalone
authoring app needs.

## What a .c4p is
A zip of:
- `project.xml` — the entire authorable project (devices, bindings, programming, variables)
- `meta/manifest.json` — per-file **md5 + size** + restore paths (integrity, **not** a signature)
- `identity.db`, `mm.db` — users/permissions and media metadata (SQLite)
- `drivers/*.c4z|.c4i` — the driver files the project references

Editing is viable because integrity is a plain MD5 (verified against a real backup). Change
`project.xml`, recompute its md5+size in the manifest, rezip. `save()` does this automatically.

## Restore mechanics (from manifest restore-paths)
On Restore, Director writes `project.xml` → `/opt/control4/var/director/project.xml.imported` and
imports it into the runtime `project.db`. `project.xml` is the canonical authoring format; the
controller's `project.db` is the runtime encoding of the same model.

## CLI
```
python3 -m c4proj info      "<file.c4p>"              # summary + integrity check
python3 -m c4proj tree      "<file.c4p>" [--depth N]  # device/room tree
python3 -m c4proj bindings  "<file.c4p>"              # binding graph (provider -> consumers)
python3 -m c4proj program   "<file.c4p>"              # programming (raw events -> codeitems)
python3 -m c4proj rules     "<file.c4p>"              # programming as readable "WHEN X: -> do Y"
python3 -m c4proj drivers   "<file.c4p>"              # driver files + command/event/proxy counts
python3 -m c4proj device    "<file.c4p>" <deviceid>   # a device's resolved events/commands/conditions
python3 -m c4proj roundtrip "<file.c4p>"              # unpack->repack unchanged; verify integrity
python3 -m c4proj identify  "<file.c4p>"              # project/version confirmation card
python3 -m c4proj rename    "<file.c4p>" OLD NEW -o out.c4p [--yes]   # demo edit
```

**Version-confirmation gate:** every editing command first prints an identity card
(project name, project version, director version, backup date, device/binding counts) and asks
"Is this the current/desired project version? [y/N]" before writing — so a stale backup can't be
edited by mistake (this exact mix-up happened once: a 2025 director-4.0.0 file vs the live 4.1.0).
Pass `--yes` to bypass for scripting.

## Library
```python
from c4proj import C4Package, ProjectModel
with C4Package.open("Russell House.c4p") as pkg:
    assert not pkg.verify()                 # integrity clean
    pm = ProjectModel(pkg.project_xml)
    print(pm.summary())                     # devices/bindings/programming counts
    pm.find_device("262").rename("Macros X")
    pm.save()                               # write project.xml
    pkg.save("out.c4p")                     # refresh manifest md5s + rezip
```

## Status (2026-07-12)
- Verified against the **current** `Russell House.c4p` — director **4.1.0.743847**, project
  version **133**, **417 devices**, 330 bindings, 98 programming events, integrity clean, ~0.3s to
  parse a 125 MB archive. (Also worked on an older 4.0.0 backup — parser is version-tolerant.)
- **Lossless round-trip proven** (repack unchanged → integrity clean).
- **Edit + repackage proven** (rename → project.xml md5 updated → manifest refreshed → clean).
- **Composer ACCEPTS generated files** — confirmed by opening a c4proj-generated `.c4p` against a
  **virtual director** in Composer (parses + imports). The virtual director is the safe test loop.
- Testing progression: virtual director → spare **Core Lite** controller → live system.

Generated/test `.c4p` files live in `better_composer/test projects/` (repo convention).

## Model (project.xml)
Root `<currentstate>`: `properties`, `systemitems` (nested `item` tree; a device's driver is the
`<c4i>` child of `<item>`, sibling of `<itemdata>`), `bindings`
(`boundbinding`→`boundconsumers/bound`), `networkbindings`, `variables`, `event_mgr`
(`event`→`codeitem`, `cmdcond` = `devicecommand`/`deviceconditional`), `plugins`.

## Driver metadata (drivers.py)
Answers "what can this device do" — the half the programming UI needs. A device driver declares
`<proxy>NAME</proxy>`; the proxy driver (e.g. `light_v2.c4i`) declares the real `<commands>`,
`<conditions>`, `<events>`. Both are bundled in `drivers/`, so `DriverLibrary.resolve(c4i)` walks
device→proxy and returns the effective API. Commands are `id`/`name`/`description`; params are the
UPPERCASE placeholder tokens in the description (`"Ramp to Level INTEGER ... over TIME"`).

Coverage on the current project (417 devices): **186 programmable devices resolved**; 171 empty
(rooms/containers/agents w/o proxy); 51 driver files not bundled — these are **built-in agents
(`control4_agent_*.c4i`) and `roomdevice.c4i`**, which live in Director/Composer, not the archive.
**Known gap:** programming against agents/rooms needs their command defs sourced from Director.
