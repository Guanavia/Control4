"""
state.py — read/edit a device or agent instance's <state> blob.

A project item's configuration lives in its <state> element as an ESCAPED XML document, e.g. a
dimmer's `<State><PRESET_LEVEL>100</PRESET_LEVEL>...` or a keypad's `<State><BUTTON_LIST_INFO>...`.
ElementTree unescapes it on read and re-escapes it on write, so we parse st.text into a normal
tree, edit it, and write the serialized tree back into st.text — model.save() re-escapes it.

Paths use the same notation as `c4proj diff`: "/TAG/CHILD", with a positional "[i]" index on tags
that repeat under the same parent (e.g. "/BUTTON_LIST_INFO/KEYPAD_BUTTON_INFO[1]/BUTTON_ID").
Paths are relative to the state ROOT's children (the root element itself is implicit).

This is the generic property/config write primitive that higher-level helpers (device properties,
agent config like lighting scenes / scheduler entries) build on.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from typing import Dict, List, Optional

from .model import ProjectModel

_SEG = re.compile(r"^([^\[\]]+)(?:\[(\d+)\])?$")


def _split(path: str) -> List[tuple]:
    """'/A/B[2]/C' -> [('A',0),('B',2),('C',0)]. Raises ValueError on a malformed segment."""
    parts = [p for p in path.strip("/").split("/") if p != ""]
    out = []
    for p in parts:
        m = _SEG.match(p)
        if not m:
            raise ValueError(f"bad path segment: {p!r}")
        out.append((m.group(1), int(m.group(2)) if m.group(2) is not None else 0))
    return out


class StateEditor:
    """Wraps one item's <state>. Edits happen on an in-memory tree; call flush() to write it back
    into the item (then model.save() to persist the project)."""

    def __init__(self, item: ET.Element):
        self._item = item
        st = item.find("state")
        if st is None:
            st = ET.SubElement(item, "state")
        self._state_el = st
        text = (st.text or "").strip()
        self.root: Optional[ET.Element] = ET.fromstring(text) if text else None

    # ---- lifecycle ----------------------------------------------------------
    def init_root(self, tag: str = "State") -> ET.Element:
        """Create an empty state root (for a skeletal/empty item, e.g. an agent). No-op if one
        already exists. Returns the root element."""
        if self.root is None:
            self.root = ET.Element(tag)
        return self.root

    def flush(self) -> None:
        """Serialize the edited tree back into the item's <state> (unescaped here; ET re-escapes
        on model.save())."""
        if self.root is None:
            self._state_el.text = ""
        else:
            self._state_el.text = ET.tostring(self.root, encoding="unicode")

    # ---- read ---------------------------------------------------------------
    def fields(self) -> Dict[str, str]:
        """Flatten the whole state to {path: value} leaves (positional [i] on repeats)."""
        if self.root is None:
            return {}
        return _flatten(self.root)

    def find(self, path: str) -> Optional[ET.Element]:
        """Resolve a path to its element, or None if any segment doesn't exist."""
        if self.root is None:
            return None
        cur = self.root
        for tag, idx in _split(path):
            matches = [c for c in cur if c.tag == tag]
            if idx >= len(matches):
                return None
            cur = matches[idx]
        return cur

    def get(self, path: str) -> Optional[str]:
        """Text value at path, or None if the path doesn't resolve."""
        el = self.find(path)
        if el is None:
            return None
        return (el.text or "").strip()

    # ---- write --------------------------------------------------------------
    def set(self, path: str, value) -> ET.Element:
        """Set the leaf value at path, creating any missing single-occurrence ancestors/leaf along
        the way. A path segment with an explicit [i] index must already exist (we won't invent
        arbitrary repeat positions — use append() for that). Returns the leaf element."""
        if self.root is None:
            self.init_root()
        cur = self.root
        for tag, idx in _split(path):
            matches = [c for c in cur if c.tag == tag]
            if idx < len(matches):
                cur = matches[idx]
            elif idx == 0:
                cur = ET.SubElement(cur, tag)   # create the missing single-occurrence child
            else:
                raise KeyError(f"cannot create indexed segment {tag}[{idx}] in {path!r} — "
                               f"there is no element at that position; use append() instead")
        cur.text = "" if value is None else str(value)
        return cur

    def append(self, parent_path: str, tag: str, value=None) -> ET.Element:
        """Append a new <tag> child under parent_path (use parent_path='' or '/' for the root).
        Returns the new element so the caller can populate its subtree."""
        if self.root is None:
            self.init_root()
        parent = self.root if parent_path.strip("/") == "" else self.find(parent_path)
        if parent is None:
            raise KeyError(f"no element at {parent_path!r}")
        el = ET.SubElement(parent, tag)
        if value is not None:
            el.text = str(value)
        return el

    # ---- driver properties --------------------------------------------------
    # A DriverWorks device stores its config-property VALUES in the state blob as
    # <properties><property><name>X</name><value>Y</value></property>...</properties>, keyed by the
    # same display name the driver's <properties> SCHEMA declares (see drivers.Property). These
    # helpers work by property name, joining to that schema.
    def driver_properties(self) -> Dict[str, str]:
        """{property name: value} for every <property> in the state (any nesting)."""
        out: Dict[str, str] = {}
        if self.root is None:
            return out
        for p in self.root.iter("property"):
            nm = p.findtext("name")
            if nm is not None:
                out[nm.strip()] = (p.findtext("value") or "").strip()
        return out

    def get_driver_property(self, name: str) -> Optional[str]:
        if self.root is None:
            return None
        for p in self.root.iter("property"):
            if (p.findtext("name") or "").strip() == name:
                return (p.findtext("value") or "").strip()
        return None

    def set_driver_property(self, name: str, value) -> ET.Element:
        """Set the value of the config property named `name`, matching how Composer's Properties
        view persists it. Updates the existing <property> if present, else creates one under a
        <properties> container (created at the state root if missing). Returns the <property>."""
        self.init_root()
        for p in self.root.iter("property"):
            if (p.findtext("name") or "").strip() == name:
                v = p.find("value")
                if v is None:
                    v = ET.SubElement(p, "value")
                v.text = "" if value is None else str(value)
                return p
        container = self.root.find("properties")
        if container is None:
            container = ET.SubElement(self.root, "properties")
        prop = ET.SubElement(container, "property")
        ET.SubElement(prop, "name").text = name
        ET.SubElement(prop, "value").text = "" if value is None else str(value)
        return prop

    def remove(self, path: str) -> bool:
        """Remove the element at path. Returns True if something was removed."""
        segs = _split(path)
        if self.root is None or not segs:
            return False
        parent = self.root
        for tag, idx in segs[:-1]:
            matches = [c for c in parent if c.tag == tag]
            if idx >= len(matches):
                return False
            parent = matches[idx]
        tag, idx = segs[-1]
        matches = [c for c in parent if c.tag == tag]
        if idx >= len(matches):
            return False
        parent.remove(matches[idx])
        return True


def _flatten(el: ET.Element, prefix: str = "") -> Dict[str, str]:
    """Flatten an element tree to {path: text} leaves (path includes positional index for repeats)."""
    out: Dict[str, str] = {}
    counts: Dict[str, int] = {}
    for c in el:
        counts[c.tag] = counts.get(c.tag, 0) + 1
    seen: Dict[str, int] = {}
    for c in el:
        if counts[c.tag] > 1:
            i = seen.get(c.tag, 0)
            seen[c.tag] = i + 1
            path = f"{prefix}/{c.tag}[{i}]"
        else:
            path = f"{prefix}/{c.tag}"
        if list(c):
            out.update(_flatten(c, path))
        else:
            out[path] = (c.text or "").strip()
    return out


def edit_state(model: ProjectModel, item_id: str) -> StateEditor:
    """Open a StateEditor on the item with the given id."""
    for it in model.root.iter("item"):
        if it.findtext("id") == item_id:
            return StateEditor(it)
    raise ValueError(f"no item with id {item_id}")
