"""
authoring.py — the beginning of the WRITE engine: assemble/modify a project programmatically.

First capability: clone_device — take an existing device (a template) and add a fresh copy with
newly-allocated IDs, its proxy sub-items, and its bindings remapped. This is the core "add a
device" operation, and cloning from a known-good in-project device sidesteps the open question of
where driver-generated default state comes from (we reuse a real one as the template).

`skeletal=True` strips the <state> blobs from the clone — used to test whether Director
regenerates device state on project load (if it does, our tool needn't carry per-driver state).
"""

from __future__ import annotations

import copy
import datetime
import xml.etree.ElementTree as ET
from typing import Dict, List, Optional

from .model import ProjectModel


def _find_item(root: ET.Element, item_id: str) -> Optional[ET.Element]:
    for it in root.iter("item"):
        if it.findtext("id") == item_id:
            return it
    return None


def _subitems_parent(root: ET.Element, item_el: ET.Element) -> Optional[ET.Element]:
    """The <subitems> element that directly contains item_el."""
    for si in root.iter("subitems"):
        for child in list(si):
            if child is item_el:
                return si
    return None


def next_ids(model: ProjectModel, n: int) -> List[str]:
    """Allocate n fresh item IDs and bump properties/iditemcurrent."""
    cur_el = model.root.find(".//properties/iditemcurrent")
    base = int(cur_el.text) if (cur_el is not None and cur_el.text) else 0
    ids = [str(base + 1 + i) for i in range(n)]
    if cur_el is not None:
        cur_el.text = str(base + n)
    return ids


def _room_of(root: ET.Element, room_id: str) -> ET.Element:
    it = _find_item(root, room_id)
    if it is None:
        raise ValueError(f"no room/location item with id {room_id}")
    sub = it.find("subitems")
    if sub is None:
        sub = ET.SubElement(it, "subitems")
    return sub


def add_device(model: ProjectModel, driver_filename: str, name: str, room_id: str) -> str:
    """Add a device as a PARENT-ONLY skeletal item (driver ref + id + name, empty state, no proxy
    sub-items, no bindings) under room_id. Relies on Director to complete proxy subs/bindings/state
    on load. Returns the new item id. (The driver file must already be in the package's drivers/.)"""
    root = model.root
    new_id = next_ids(model, 1)[0]
    now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    item = ET.Element("item")
    ET.SubElement(item, "id").text = new_id
    ET.SubElement(item, "name").text = name
    ET.SubElement(item, "type").text = "6"          # physical device
    ET.SubElement(item, "created_datetime").text = now
    idata = ET.SubElement(item, "itemdata")
    ET.SubElement(idata, "config_data_file").text = driver_filename
    ET.SubElement(item, "state").text = ""
    ET.SubElement(item, "c4i").text = driver_filename
    ET.SubElement(item, "subitems")
    _room_of(root, room_id).append(item)
    return new_id


def add_room(model: ProjectModel, floor_id: str, name: str, template_room_id: str) -> str:
    """Add a room by cloning an existing room's structure (RoomDeviceData state) under floor_id."""
    root = model.root
    tmpl = _find_item(root, template_room_id)
    if tmpl is None:
        raise ValueError(f"no template room {template_room_id}")
    new_id = next_ids(model, 1)[0]
    clone = copy.deepcopy(tmpl)
    clone.find("id").text = new_id
    clone.find("name").text = name
    cd = clone.find("created_datetime")
    if cd is not None:
        cd.text = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    si = clone.find("subitems")          # empty the cloned room's contents
    if si is not None:
        for ch in list(si):
            si.remove(ch)
    _room_of(root, floor_id).append(clone)
    return new_id


def change_driver(model: ProjectModel, item_id: str, new_c4i: str, new_name: str) -> None:
    """Repoint an item to a different driver and strip its state (Director refills on load).
    Used to swap the controller type (Core Lite -> Core5)."""
    it = _find_item(model.root, item_id)
    if it is None:
        raise ValueError(f"no item {item_id}")
    it.find("c4i").text = new_c4i
    idata = it.find("itemdata")
    cdf = idata.find("config_data_file") if idata is not None else None
    if cdf is not None:
        cdf.text = new_c4i
    nm = it.find("name")
    if nm is not None:
        nm.text = new_name
    st = it.find("state")
    if st is not None:
        st.text = ""


def clone_device(model: ProjectModel, source_id: str, new_name: str,
                 skeletal: bool = False) -> Dict[str, str]:
    """Clone the device subtree rooted at source_id (parent + proxy subs) with fresh IDs, insert
    it as a sibling in the same room, clone its bindings remapped, and bump iditemcurrent.
    Returns the old->new id map."""
    root = model.root
    src = _find_item(root, source_id)
    if src is None:
        raise ValueError(f"no item with id {source_id}")

    old_ids = [it.findtext("id") for it in src.iter("item")]
    new = next_ids(model, len(old_ids))
    id_map = dict(zip(old_ids, new))

    clone = copy.deepcopy(src)
    now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    for it in clone.iter("item"):
        idel = it.find("id")
        idel.text = id_map[idel.text]
        cd = it.find("created_datetime")
        if cd is not None:
            cd.text = now
        if skeletal:
            st = it.find("state")
            if st is not None:
                st.text = ""
    # rename the top-level cloned item
    top_name = clone.find("name")
    if top_name is not None:
        top_name.text = new_name

    # insert as sibling of source
    sp = _subitems_parent(root, src)
    if sp is None:
        raise ValueError("could not find source's <subitems> parent")
    sp.append(clone)

    # clone bindings where either endpoint is in the cloned set, remapping ids
    bindings = root.find("bindings")
    if bindings is not None:
        for bb in list(bindings.findall("boundbinding")):
            prov = bb.findtext("deviceid")
            # Clone only the device's OWN outgoing (provider) bindings — its proxy wiring and
            # room memberships. Do NOT clone inbound connections others made to the original
            # (e.g. a scene linked to its button); those are external choices, not the device.
            if prov in id_map:
                nb = copy.deepcopy(bb)
                pe = nb.find("deviceid")
                if pe.text in id_map:
                    pe.text = id_map[pe.text]
                for b in nb.findall(".//bound"):
                    de = b.find("deviceid")
                    if de.text in id_map:
                        de.text = id_map[de.text]
                bindings.append(nb)

    return id_map
