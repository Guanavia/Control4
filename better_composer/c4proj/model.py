"""
model.py — parse project.xml into a navigable read-model.

project.xml root is <currentstate> with these sections:
  properties       project meta (current max id, version, owner/dealer, geo, UI defaults)
  systemitems      the device/room/agent tree (nested <item> via <subitems>)
  bindings         binding graph: <boundbinding> provider -> <boundconsumers>/<bound>
  networkbindings  IP/serial network bindings
  variables        <variable> definitions
  event_mgr        programming: <event> -> <codeitem> tree (cmdcond = devicecommand/conditional)
  plugins          agents/plugins

This is a READ model built directly on ElementTree nodes: every object keeps a reference to
its underlying element, so edits made here are edits to the tree that C4Package.save() will
serialize. It intentionally preserves the original elements rather than rebuilding them, so
untouched parts round-trip verbatim.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import Dict, List, Optional


def _text(el: Optional[ET.Element], tag: str, default: str = "") -> str:
    if el is None:
        return default
    child = el.find(tag)
    return child.text if (child is not None and child.text is not None) else default


@dataclass
class Device:
    """A node in systemitems (room, device, or agent). Wraps its <item> element."""
    el: ET.Element
    parent: Optional["Device"] = None
    children: List["Device"] = field(default_factory=list)

    @property
    def id(self) -> str:
        return _text(self.el, "id")

    @property
    def name(self) -> str:
        return _text(self.el, "name")

    @property
    def type(self) -> str:
        return _text(self.el, "type")

    @property
    def driver(self) -> str:
        """The referenced driver file (c4i). It is a direct child of <item>, sibling of
        <itemdata> — e.g. 'switch_gen3.c4i'. Empty for structural items (rooms, folders)."""
        return _text(self.el, "c4i")

    def rename(self, new_name: str) -> None:
        n = self.el.find("name")
        if n is None:
            n = ET.SubElement(self.el, "name")
        n.text = new_name


@dataclass
class Binding:
    """A provider binding and the consumers bound to it."""
    provider_deviceid: str
    provider_bindingid: str
    consumers: List[dict]  # {deviceid, bindingid, name, classes:[...]}


@dataclass
class CodeItem:
    el: ET.Element

    @property
    def id(self) -> str: return _text(self.el, "id")
    @property
    def device(self) -> str: return _text(self.el, "device")
    @property
    def type(self) -> str: return _text(self.el, "type")
    @property
    def display(self) -> str: return _text(self.el, "display")

    @property
    def command(self) -> Optional[str]:
        cc = self.el.find("cmdcond")
        if cc is None:
            return None
        dc = cc.find("devicecommand")
        if dc is not None:
            return _text(dc, "command") or "(devicecommand)"
        if cc.find("deviceconditional") is not None:
            return "(conditional)"
        return None

    @property
    def children(self) -> List["CodeItem"]:
        sub = self.el.find("subitems")
        if sub is None:
            return []
        return [CodeItem(c) for c in sub.findall("codeitem")]


@dataclass
class Event:
    el: ET.Element

    @property
    def deviceid(self) -> str: return _text(self.el, "deviceid")
    @property
    def eventid(self) -> str: return _text(self.el, "eventid")

    @property
    def codeitems(self) -> List[CodeItem]:
        return [CodeItem(c) for c in self.el.findall("codeitem")]


class ProjectModel:
    def __init__(self, xml_path: str):
        self.xml_path = xml_path
        self.tree = ET.parse(xml_path)
        self.root = self.tree.getroot()  # <currentstate>

    def save(self) -> None:
        """Write the (possibly edited) tree back to project.xml."""
        self.tree.write(self.xml_path, encoding="utf-8", xml_declaration=False)

    # ---- properties ---------------------------------------------------------
    @property
    def project_name(self) -> str:
        # first systemitems/item is the project root ("Russell House")
        item = self.root.find("./systemitems/item")
        return _text(item, "name")

    @property
    def project_version(self) -> str:
        return _text(self.root.find(".//itemdata"), "project_version")

    # ---- devices ------------------------------------------------------------
    def device_tree(self) -> List[Device]:
        """Top-level Devices with nested children (mirrors the systemitems tree)."""
        si = self.root.find("systemitems")
        if si is None:
            return []
        roots: List[Device] = []
        for item in si.findall("item"):
            roots.append(self._build_device(item, None))
        return roots

    def _build_device(self, item: ET.Element, parent: Optional[Device]) -> Device:
        d = Device(el=item, parent=parent)
        sub = item.find("subitems")
        if sub is not None:
            for child in sub.findall("item"):
                d.children.append(self._build_device(child, d))
        return d

    def all_devices(self) -> List[Device]:
        out: List[Device] = []

        def walk(d: Device):
            out.append(d)
            for c in d.children:
                walk(c)

        for r in self.device_tree():
            walk(r)
        return out

    def find_device(self, id: str) -> Optional[Device]:
        for d in self.all_devices():
            if d.id == id:
                return d
        return None

    # ---- bindings -----------------------------------------------------------
    def bindings(self) -> List[Binding]:
        out: List[Binding] = []
        b = self.root.find("bindings")
        if b is None:
            return out
        for bb in b.findall("boundbinding"):
            consumers = []
            bc = bb.find("boundconsumers")
            if bc is not None:
                for bound in bc.findall("bound"):
                    classes = [c.text for c in bound.findall("boundclasses/boundclass")]
                    consumers.append({
                        "deviceid": _text(bound, "deviceid"),
                        "bindingid": _text(bound, "bindingid"),
                        "name": _text(bound, "name"),
                        "classes": classes,
                    })
            out.append(Binding(
                provider_deviceid=_text(bb, "deviceid"),
                provider_bindingid=_text(bb, "bindingid"),
                consumers=consumers,
            ))
        return out

    # ---- variables ----------------------------------------------------------
    def variables(self) -> List[dict]:
        v = self.root.find("variables")
        if v is None:
            return []
        return [dict(var.attrib, value=(var.text or "")) for var in v.findall("variable")]

    # ---- programming --------------------------------------------------------
    def events(self) -> List[Event]:
        em = self.root.find("event_mgr")
        if em is None:
            return []
        return [Event(e) for e in em.findall("event")]

    # ---- summary ------------------------------------------------------------
    def summary(self) -> Dict[str, int]:
        events = self.events()

        def count_ci(cis: List[CodeItem]) -> int:
            n = 0
            for ci in cis:
                n += 1 + count_ci(ci.children)
            return n

        total_ci = sum(count_ci(e.codeitems) for e in events)
        return {
            "devices_total": len(self.all_devices()),
            "bindings_provider": len(self.bindings()),
            "bindings_consumer_links": sum(len(b.consumers) for b in self.bindings()),
            "variables": len(self.variables()),
            "programming_events": len(events),
            "programming_codeitems": total_ci,
        }
