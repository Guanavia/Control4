"""
CLI for c4proj.

  python -m c4proj info      <file.c4p>              summary + integrity check
  python -m c4proj tree      <file.c4p> [--depth N]  device/room tree
  python -m c4proj bindings  <file.c4p>              binding graph
  python -m c4proj program   <file.c4p>              programming (events -> codeitems)
  python -m c4proj drivers   <file.c4p>              driver files + command/event/proxy counts
  python -m c4proj device    <file.c4p> <deviceid>   a device's resolved events/commands/conditions
  python -m c4proj properties <file.c4p> <item_id>   dump an item's <state> config as path=value
  python -m c4proj roundtrip <file.c4p>              unpack -> repack unchanged; verify integrity
  python -m c4proj identify  <file.c4p>              show the project-version confirmation card
  python -m c4proj diff      <a.c4p> <b.c4p> [--detail]  oracle: what changed A->B; --detail shows
                                                         state-blob field deltas + added bindings
  python -m c4proj rename    <file.c4p> <old> <new> -o out.c4p [--yes]   demo edit: rename a device
  python -m c4proj set-property <file.c4p> <item_id> <state_path> <value> -o out.c4p [--yes]
                             edit one <state> config field (path like /MAX_ON_LEVEL or
                             /BUTTON_LIST_INFO/KEYPAD_BUTTON_INFO[1]/BUTTON_ID)
  python -m c4proj add-rule  <file.c4p> <trigger_dev> <trigger_event> <target_dev> <command>
                             -o out.c4p [--yes]   demo edit: single-command rule via programming.py
                             ("WHEN trigger_dev fires trigger_event: send command to target_dev")

Any editing command shows an identity card (project/version/director/date) and asks you to
confirm it's the intended project before writing. Pass --yes to bypass for scripting.
"""

from __future__ import annotations

import sys

from .c4p import C4Package
from .model import ProjectModel, Device, CodeItem
from .drivers import DriverLibrary


def _pm(pkg: C4Package) -> ProjectModel:
    return ProjectModel(pkg.project_xml)


def _identity_card(pkg: C4Package, pm: ProjectModel) -> str:
    idn = pkg.identity()
    s = pm.summary()
    lines = [
        "+---------------------------------------------------------------+",
        "|  CONFIRM PROJECT VERSION                                       |",
        "+---------------------------------------------------------------+",
        f"  Project          : {pm.project_name}",
        f"  Project version  : {pm.project_version}",
        f"  Director version : {idn['director_version']}",
        f"  Backup saved     : {idn['file_mtime']}   ({idn['file_size_mb']} MB)",
        f"  File             : {idn['file']}",
        f"  Contents         : {s['devices_total']} devices, "
        f"{s['bindings_provider']} bindings, {s['programming_events']} programming events",
    ]
    return "\n".join(lines)


def _confirm_project(pkg: C4Package, pm: ProjectModel, assume_yes: bool) -> bool:
    """Show the identity card and require confirmation before an edit. Guards against
    editing a stale/wrong backup. `--yes` bypasses for scripted/automated runs."""
    print(_identity_card(pkg, pm))
    if assume_yes:
        print("  (--yes) proceeding without prompt.")
        return True
    try:
        ans = input("\nIs this the current/desired project version? [y/N] ").strip().lower()
    except EOFError:
        ans = ""
    if ans in ("y", "yes"):
        return True
    print("Aborted — no changes made.")
    return False


def cmd_info(path: str) -> int:
    with C4Package.open(path) as pkg:
        issues = pkg.verify()
        pm = _pm(pkg)
        print(f"Project : {pm.project_name}")
        print(f"Version : {pm.project_version}")
        print(f"Workdir : {pkg.workdir}")
        print(f"Integrity: {'CLEAN (all md5 match manifest)' if not issues else str(len(issues)) + ' ISSUES'}")
        for i in issues[:10]:
            print(f"   - {i.archive_path}: {i.kind} {i.detail}")
        print("\nSummary:")
        for k, v in pm.summary().items():
            print(f"  {k:26} {v}")
    return 0


def _print_tree(d: Device, depth: int, maxd: int, indent: int = 0) -> None:
    drv = f"  [{d.driver}]" if d.driver else ""
    print(f"{'  ' * indent}- ({d.id}) {d.name}{drv}")
    if depth >= maxd:
        return
    for c in d.children:
        _print_tree(c, depth + 1, maxd, indent + 1)


def cmd_tree(path: str, maxd: int) -> int:
    with C4Package.open(path) as pkg:
        for r in _pm(pkg).device_tree():
            _print_tree(r, 0, maxd)
    return 0


def cmd_bindings(path: str) -> int:
    with C4Package.open(path) as pkg:
        pm = _pm(pkg)
        names = {d.id: d.name for d in pm.all_devices()}
        for b in pm.bindings():
            prov = names.get(b.provider_deviceid, "?")
            for c in b.consumers:
                cons = names.get(c["deviceid"], c["name"])
                cls = ",".join(x for x in c["classes"] if x)
                print(f"{prov} (#{b.provider_deviceid}/{b.provider_bindingid})"
                      f"  ->  {cons} (#{c['deviceid']}/{c['bindingid']})  [{cls}]")
    return 0


def _print_ci(ci: CodeItem, indent: int) -> None:
    cmd = ci.command or ""
    print(f"{'  ' * indent}. {ci.display}  {('<' + cmd + '>') if cmd else ''}")
    for c in ci.children:
        _print_ci(c, indent + 1)


def cmd_program(path: str) -> int:
    with C4Package.open(path) as pkg:
        pm = _pm(pkg)
        names = {d.id: d.name for d in pm.all_devices()}
        for e in pm.events():
            dev = names.get(e.deviceid, "?")
            print(f"\nEVENT on {dev} (#{e.deviceid}) event {e.eventid}:")
            for ci in e.codeitems:
                _print_ci(ci, 1)
    return 0


def cmd_drivers(path: str) -> int:
    with C4Package.open(path) as pkg:
        lib = DriverLibrary(pkg.path("drivers"))
        print(f"{len(lib.by_file)} driver files\n")
        print(f"{'driver':40}{'proxy':16}{'cmd':>4}{'cond':>5}{'evt':>4}{'conn':>5}")
        for f in sorted(lib.by_file):
            d = lib.by_file[f]
            flag = " *proxy" if d.is_proxy_like else ""
            print(f"{f[:39]:40}{d.proxy[:15]:16}{len(d.commands):>4}"
                  f"{len(d.conditions):>5}{len(d.events):>4}{len(d.connections):>5}{flag}")
    return 0


def cmd_device(path: str, dev_id: str) -> int:
    with C4Package.open(path) as pkg:
        pm = _pm(pkg)
        lib = DriverLibrary(pkg.path("drivers"))
        d = pm.find_device(dev_id)
        if d is None:
            print(f"no device with id {dev_id}")
            return 1
        print(f"Device ({d.id}) {d.name}   type={d.type}   driver={d.driver or '(none)'}")
        api = lib.resolve(d.driver) if d.driver else None
        if api is None:
            print("  no driver metadata resolved (structural item, or driver not bundled).")
            return 0
        print(f"  driver chain : {' -> '.join(api.driver_chain)}")
        if api.unresolved_proxy:
            print(f"  UNRESOLVED proxy: {api.unresolved_proxy}")
        print(f"\n  EVENTS this device can trigger on ({len(api.events)}):")
        for e in sorted(api.events, key=lambda x: x.name):
            print(f"    - {e.name:28} {e.description}")
        print(f"\n  COMMANDS you can send it ({len(api.commands)}):")
        for c in sorted(api.commands, key=lambda x: x.name):
            p = f"   params: {', '.join(c.params)}" if c.params else ""
            print(f"    - {c.name:28} {c.description}{p}")
        if api.conditions:
            print(f"\n  CONDITIONS you can test ({len(api.conditions)}):")
            for c in sorted(api.conditions, key=lambda x: x.name):
                print(f"    - {c.name:28} {c.description}")
    return 0


def _sub_name(text: str, name: str) -> str:
    return (text or "").replace("NAME", name) if text else text


def cmd_rules(path: str) -> int:
    """Render event_mgr programming as human-readable 'WHEN ... : do ...', resolving the
    numeric eventid against the trigger device's driver metadata. This is the read-side of the
    programming interface — the whole stack (project model + driver library) working together."""
    with C4Package.open(path) as pkg:
        pm = _pm(pkg)
        lib = DriverLibrary(pkg.path("drivers"))
        names = {d.id: d.name for d in pm.all_devices()}
        drivers = {d.id: d.driver for d in pm.all_devices()}

        def event_label(deviceid: str, eventid: str) -> str:
            drv = drivers.get(deviceid, "")
            api = lib.resolve(drv) if drv else None
            if api:
                for e in api.events:
                    if e.id == eventid:
                        return _sub_name(e.description or e.name, names.get(deviceid, "?"))
            return f"event {eventid}"

        def has_content(ci: CodeItem) -> bool:
            if ci.command or (ci.display or "").strip():
                return True
            return any(has_content(ch) for ch in ci.children)

        shown = 0
        for e in pm.events():
            cis = e.codeitems
            # an event's top-level codeitem is often an empty (id 0) container whose real
            # commands live in subitems — so test the whole subtree, not just the top level.
            real = [c for c in cis if has_content(c)]
            if not real:
                continue
            dev = names.get(e.deviceid, "?")
            print(f"\nWHEN {dev}: {event_label(e.deviceid, e.eventid)}")

            def render(ci: CodeItem, indent: int):
                disp = _sub_name(ci.display, names.get(ci.device, "NAME"))
                if disp.strip():
                    print(f"{'   ' * indent}-> {disp}")
                for ch in ci.children:
                    render(ch, indent + 1)

            for ci in real:
                render(ci, 1)
            shown += 1
        print(f"\n({shown} events with programming)")
    return 0


def cmd_roundtrip(path: str) -> int:
    """Unpack, verify, repackage unchanged, re-open, verify again. Proves the envelope
    is lossless and our manifest refresh is correct."""
    out = path + ".roundtrip.c4p"
    with C4Package.open(path) as pkg:
        pre = pkg.verify()
        print(f"open integrity : {'CLEAN' if not pre else str(len(pre)) + ' issues'}")
        changed = pkg.save(out)
        print(f"repackaged     : {out}")
        print(f"md5 changed    : {changed if changed else 'none (unchanged repack)'}")
    with C4Package.open(out) as pkg2:
        post = pkg2.verify()
        print(f"reopen integrity: {'CLEAN' if not post else str(len(post)) + ' issues'}")
        for i in post[:10]:
            print(f"   - {i.archive_path}: {i.kind} {i.detail}")
    return 0 if not post else 1


def cmd_identify(path: str) -> int:
    with C4Package.open(path) as pkg:
        print(_identity_card(pkg, _pm(pkg)))
    return 0


def cmd_rename(path: str, old: str, new: str, out: str, assume_yes: bool) -> int:
    with C4Package.open(path) as pkg:
        pm = _pm(pkg)
        if not _confirm_project(pkg, pm, assume_yes):
            return 3
        hit = None
        for d in pm.all_devices():
            if d.name == old:
                hit = d
                break
        if hit is None:
            print(f"no device named {old!r}")
            return 1
        print(f"renaming ({hit.id}) {old!r} -> {new!r}")
        hit.rename(new)
        pm.save()
        changed = pkg.save(out)
        print(f"wrote {out}")
        print(f"manifest md5 updated for: {changed}")
    # verify the new package is internally consistent
    with C4Package.open(out) as pkg2:
        issues = pkg2.verify()
        print(f"new package integrity: {'CLEAN' if not issues else issues}")
    return 0


def cmd_add_rule(path: str, trigger_dev: str, trigger_event: str, target_dev: str,
                  command_name: str, out: str, assume_yes: bool) -> int:
    """Demo of the programming compiler: WHEN trigger_dev fires trigger_event, send command_name
    to target_dev (no params -- for anything richer, use c4proj.programming directly)."""
    from . import programming as prog
    with C4Package.open(path) as pkg:
        pm = _pm(pkg)
        if not _confirm_project(pkg, pm, assume_yes):
            return 3
        names = {d.id: d.name for d in pm.all_devices()}
        target_name = names.get(target_dev, target_dev)
        action = prog.command(target_dev, command_name, f"{command_name} on {target_name}")
        prog.add_event_handler(pm, trigger_device_id=trigger_dev, trigger_event_id=trigger_event,
                                actions=[action])
        pm.save()
        changed = pkg.save(out)
        print(f"wrote {out}")
        print(f"manifest md5 updated for: {changed}")
    with C4Package.open(out) as pkg2:
        issues = pkg2.verify()
        print(f"new package integrity: {'CLEAN' if not issues else issues}")
    return 0


def cmd_properties(path: str, item_id: str) -> int:
    """Dump an item's <state> config as flat path=value fields (read-only)."""
    from .state import edit_state
    with C4Package.open(path) as pkg:
        pm = _pm(pkg)
        name = {d.id: d.name for d in pm.all_devices()}.get(item_id, "?")
        ed = edit_state(pm, item_id)
        fields = ed.fields()
        print(f"({item_id}) {name} — {len(fields)} state fields"
              + ("" if fields else "  (empty state)"))
        for k in sorted(fields):
            print(f"  {k} = {fields[k]!r}")
    return 0


def cmd_set_property(path: str, item_id: str, statepath: str, value: str, out: str,
                     assume_yes: bool) -> int:
    """Set one <state> field on an item, then repackage. The generic property/config write."""
    from .state import edit_state
    with C4Package.open(path) as pkg:
        pm = _pm(pkg)
        if not _confirm_project(pkg, pm, assume_yes):
            return 3
        ed = edit_state(pm, item_id)
        old = ed.get(statepath)
        ed.set(statepath, value)
        ed.flush()
        print(f"item {item_id}: {statepath}  {old!r} -> {value!r}")
        pm.save()
        changed = pkg.save(out)
        print(f"wrote {out}")
        print(f"manifest md5 updated for: {changed}")
    with C4Package.open(out) as pkg2:
        issues = pkg2.verify()
        print(f"new package integrity: {'CLEAN' if not issues else issues}")
    return 0


def main(argv: list) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd, path = argv[0], argv[1]
    if cmd == "info":
        return cmd_info(path)
    if cmd == "tree":
        depth = 99
        if "--depth" in argv:
            depth = int(argv[argv.index("--depth") + 1])
        return cmd_tree(path, depth)
    if cmd == "bindings":
        return cmd_bindings(path)
    if cmd == "program":
        return cmd_program(path)
    if cmd == "roundtrip":
        return cmd_roundtrip(path)
    if cmd == "identify":
        return cmd_identify(path)
    if cmd == "drivers":
        return cmd_drivers(path)
    if cmd == "device":
        return cmd_device(path, argv[2])
    if cmd == "properties":
        # properties <file> <item_id>
        return cmd_properties(path, argv[2])
    if cmd == "set-property":
        # set-property <file> <item_id> <state_path> <value> -o out.c4p [--yes]
        item_id, statepath, value = argv[2], argv[3], argv[4]
        out = argv[argv.index("-o") + 1] if "-o" in argv else path + ".prop.c4p"
        return cmd_set_property(path, item_id, statepath, value, out, assume_yes="--yes" in argv)
    if cmd == "rules":
        return cmd_rules(path)
    if cmd == "diff":
        from .diff import diff_packages
        diff_packages(path, argv[2], detail="--detail" in argv)
        return 0
    if cmd == "rename":
        # rename <file> <old> <new> -o out.c4p [--yes]
        old, new = argv[2], argv[3]
        out = argv[argv.index("-o") + 1] if "-o" in argv else path + ".renamed.c4p"
        return cmd_rename(path, old, new, out, assume_yes="--yes" in argv)
    if cmd == "add-rule":
        # add-rule <file> <trigger_dev> <trigger_event> <target_dev> <command> -o out.c4p [--yes]
        trigger_dev, trigger_event, target_dev, command_name = argv[2], argv[3], argv[4], argv[5]
        out = argv[argv.index("-o") + 1] if "-o" in argv else path + ".ruled.c4p"
        return cmd_add_rule(path, trigger_dev, trigger_event, target_dev, command_name, out,
                             assume_yes="--yes" in argv)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
