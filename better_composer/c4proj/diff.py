"""
diff.py — the oracle instrument. Compare two .c4p captures (a project saved before and after a
single Composer operation) and report exactly what changed, so we can reverse-engineer each
authoring operation's data transform.

Reports:
  - manifest: files added / removed / md5-changed (flags identity.db, project.xml, drivers/* — the
    identity.db flag answers "does adding a controller touch identity at add-time?").
  - project.xml items: added (with full XML = the instantiation template we want), removed, and
    content-changed (by id).
  - bindings, variables, and programming-event count deltas.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from typing import Dict, List, Tuple

from .c4p import C4Package
from .model import ProjectModel


def _manifest_md5s(pkg: C4Package) -> Dict[str, str]:
    out = {}
    for src in pkg.manifest.get("manifest", {}).get("sources", []):
        for item in src.get("items", []):
            out[item["archive-path"]] = item.get("md5", "(no-md5)")
    return out


def _items_by_id(pm: ProjectModel) -> Dict[str, ET.Element]:
    out = {}
    for it in pm.root.iter("item"):
        i = it.findtext("id")
        if i is not None:
            out[i] = it
    return out


def _canon(el: ET.Element) -> str:
    # shallow canonical: this item's own fields excluding <subitems> (children compared separately)
    clone = ET.Element(el.tag)
    for c in el:
        if c.tag == "subitems":
            continue
        clone.append(c)
    return ET.tostring(clone, encoding="unicode")


def _item_label(el: ET.Element) -> str:
    return (f"({el.findtext('id')}) {el.findtext('name')}  "
            f"type={el.findtext('type')} c4i={el.findtext('c4i') or '-'}")


def _flatten(el: ET.Element, prefix: str = "") -> Dict[str, str]:
    """Flatten an element tree to {path: text} leaves (path includes positional index for repeats)."""
    out: Dict[str, str] = {}
    counts: Dict[str, int] = {}
    for c in el:
        counts[c.tag] = counts.get(c.tag, 0) + 1
    seen: Dict[str, int] = {}
    for c in el:
        if counts[c.tag] > 1:
            i = seen.get(c.tag, 0); seen[c.tag] = i + 1
            path = f"{prefix}/{c.tag}[{i}]"
        else:
            path = f"{prefix}/{c.tag}"
        kids = list(c)
        if kids:
            out.update(_flatten(c, path))
        else:
            out[path] = (c.text or "").strip()
    return out


def _parse_state(item: ET.Element):
    """The item's <state> holds escaped XML; ET already unescapes .text, so parse it as a tree."""
    st = item.find("state")
    if st is None or not (st.text or "").strip():
        return None
    try:
        return ET.fromstring(st.text)
    except Exception:
        return None


def _state_delta(a_item: ET.Element, b_item: ET.Element) -> None:
    sa, sb = _parse_state(a_item), _parse_state(b_item)
    if sa is None and sb is None:
        # non-state fields changed (e.g. name)
        for tag in ("name",):
            av = a_item.findtext(tag); bv = b_item.findtext(tag)
            if av != bv:
                print(f"      {tag}: {av!r} -> {bv!r}")
        return
    fa = _flatten(sa) if sa is not None else {}
    fb = _flatten(sb) if sb is not None else {}
    added = [k for k in fb if k not in fa]
    removed = [k for k in fa if k not in fb]
    changed = [k for k in (set(fa) & set(fb)) if fa[k] != fb[k]]
    for k in sorted(added):
        print(f"      + {k} = {fb[k]!r}")
    for k in sorted(removed):
        print(f"      - {k} (was {fa[k]!r})")
    for k in sorted(changed):
        print(f"      ~ {k}: {fa[k]!r} -> {fb[k]!r}")
    if not (added or removed or changed):
        av, bv = a_item.findtext("name"), b_item.findtext("name")
        if av != bv:
            print(f"      name: {av!r} -> {bv!r}")
        else:
            print("      (state structurally same; deeper/reordered change)")


def _binding_tuples(pm: ProjectModel):
    out = set()
    for b in pm.bindings():
        for c in b.consumers:
            out.add((b.provider_deviceid, b.provider_bindingid,
                     c["deviceid"], c["bindingid"], ",".join(c["classes"])))
    return out


def diff_packages(a_path: str, b_path: str, show_xml: bool = True, detail: bool = False) -> None:
    with C4Package.open(a_path) as a, C4Package.open(b_path) as b:
        print(f"A (before): {a_path}")
        print(f"B (after) : {b_path}\n")

        # ---- manifest / file-level ----
        ma, mb = _manifest_md5s(a), _manifest_md5s(b)
        added_f = sorted(set(mb) - set(ma))
        removed_f = sorted(set(ma) - set(mb))
        changed_f = sorted(k for k in (set(ma) & set(mb)) if ma[k] != mb[k])
        print("=== MANIFEST FILES ===")
        for f in added_f:
            print(f"  + {f}")
        for f in removed_f:
            print(f"  - {f}")
        for f in changed_f:
            flag = "  <-- IDENTITY TOUCHED" if f == "identity.db" else ""
            print(f"  ~ {f} (md5 changed){flag}")
        if not (added_f or removed_f or changed_f):
            print("  (no file changes)")

        # ---- project.xml items ----
        pa, pb = ProjectModel(a.project_xml), ProjectModel(b.project_xml)
        ia, ib = _items_by_id(pa), _items_by_id(pb)
        added = [i for i in ib if i not in ia]
        removed = [i for i in ia if i not in ib]
        changed = [i for i in (set(ia) & set(ib)) if _canon(ia[i]) != _canon(ib[i])]

        print(f"\n=== PROJECT ITEMS  (A:{len(ia)}  B:{len(ib)}) ===")
        print(f"  added: {len(added)}  removed: {len(removed)}  changed: {len(changed)}")
        for i in sorted(added, key=lambda x: int(x) if x.isdigit() else 0):
            print(f"\n  + ADDED {_item_label(ib[i])}")
            if show_xml:
                # the added item's own fields (trim nested subitems for readability)
                clone = ET.Element("item")
                for c in ib[i]:
                    if c.tag == "subitems":
                        n = len(c.findall("item"))
                        se = ET.SubElement(clone, "subitems")
                        se.text = f"[{n} nested items]"
                    else:
                        clone.append(c)
                xml = ET.tostring(clone, encoding="unicode")
                print("    " + xml.replace("\n", "\n    ")[:2000])
        for i in sorted(removed):
            print(f"  - REMOVED {_item_label(ia[i])}")
        for i in sorted(changed):
            print(f"  ~ CHANGED {_item_label(ib[i])}")
            if detail:
                _state_delta(ia[i], ib[i])

        # ---- bindings delta ----
        ta, tb = _binding_tuples(pa), _binding_tuples(pb)
        add_b = sorted(tb - ta); rem_b = sorted(ta - tb)
        print("\n=== BINDINGS / VARIABLES / PROGRAMMING ===")
        print(f"  provider bindings : {len(pa.bindings())} -> {len(pb.bindings())}")
        if detail:
            for t in add_b:
                print(f"    + bind provider #{t[0]}/{t[1]} -> consumer #{t[2]}/{t[3]} [{t[4]}]")
            for t in rem_b:
                print(f"    - bind provider #{t[0]}/{t[1]} -> consumer #{t[2]}/{t[3]} [{t[4]}]")
        print(f"  variables         : {len(pa.variables())} -> {len(pb.variables())}")
        print(f"  programming events: {len(pa.events())} -> {len(pb.events())}")
