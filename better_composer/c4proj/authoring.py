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
import uuid
import xml.etree.ElementTree as ET
from typing import Dict, List, Optional

from . import _compound
from .model import ProjectModel


def _now() -> str:
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def _make_item(item_id: str, name: str, type_: str, *, c4i: Optional[str] = None,
               state: str = "", large_image: Optional[str] = None,
               small_image: Optional[str] = None, tag: Optional[str] = None) -> ET.Element:
    """Build a bare <item>. Locations have no c4i; devices/services carry a driver ref + state."""
    item = ET.Element("item")
    ET.SubElement(item, "id").text = item_id
    ET.SubElement(item, "name").text = name
    ET.SubElement(item, "type").text = type_
    ET.SubElement(item, "created_datetime").text = _now()
    idata = ET.SubElement(item, "itemdata")
    if c4i:
        ET.SubElement(idata, "config_data_file").text = c4i
    if large_image:
        ET.SubElement(idata, "large_image").text = large_image
    if small_image:
        ET.SubElement(idata, "small_image").text = small_image
    if tag:
        ET.SubElement(idata, "tag").text = tag
    ET.SubElement(item, "state").text = state
    if c4i:
        ET.SubElement(item, "c4i").text = c4i
    ET.SubElement(item, "subitems")
    return item


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


def add_room(model: ProjectModel, floor_id: str, name: str,
             template_room_id: Optional[str] = None) -> str:
    """Add a room under floor_id. If template_room_id is given, clone that room's structure;
    otherwise (or if no rooms exist yet) build a fresh room from the standard roomdevice defaults —
    so a UI can add the very first room without needing an existing one to clone."""
    root = model.root
    new_id = next_ids(model, 1)[0]

    tmpl = _find_item(root, template_room_id) if template_room_id else None
    if tmpl is None and template_room_id is None:
        # auto-pick any existing room as the template, else synthesize a fresh one
        tmpl = next((it for it in root.iter("item") if it.findtext("type") == "8"), None)

    if tmpl is not None:
        clone = copy.deepcopy(tmpl)
        clone.find("id").text = new_id
        clone.find("name").text = name
        cd = clone.find("created_datetime")
        if cd is not None:
            cd.text = _now()
        si = clone.find("subitems")          # empty the cloned room's contents
        if si is not None:
            for ch in list(si):
                si.remove(ch)
        _room_of(root, floor_id).append(clone)
    elif template_room_id is not None:
        raise ValueError(f"no template room {template_room_id}")
    else:
        room = _make_item(new_id, name, "8", c4i="roomdevice.c4i",
                          state=_compound.SCAFFOLD["room"]["state"],
                          large_image="locations_lg\\room.gif",
                          small_image="locations_sm\\room.gif")
        _room_of(root, floor_id).append(room)
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


def _bindings_root(root: ET.Element) -> ET.Element:
    b = root.find("bindings")
    if b is None:
        b = ET.SubElement(root, "bindings")
    return b


def _find_boundbinding(bindings: ET.Element, provider_id: str,
                       provider_bindingid: str) -> Optional[ET.Element]:
    for bb in bindings.findall("boundbinding"):
        if bb.findtext("deviceid") == provider_id and bb.findtext("bindingid") == provider_bindingid:
            return bb
    return None


def add_binding(model: ProjectModel, provider_id: str, provider_bindingid: str,
                consumer_id: str, consumer_bindingid: str, name: str,
                classes: List[str]) -> None:
    """Wire an arbitrary connection: bind provider (provider_id/provider_bindingid) to consumer
    (consumer_id/consumer_bindingid). Mirrors the Composer Connections screen. If a <boundbinding>
    already exists for this provider endpoint, the consumer is appended to it; otherwise a new
    <boundbinding> is created. Idempotent — re-adding the same consumer is a no-op. `classes` are
    the <boundclass> tags (e.g. ["BUTTON_LINK"], ["CONTROLLER"])."""
    bindings = _bindings_root(model.root)
    bb = _find_boundbinding(bindings, provider_id, provider_bindingid)
    if bb is None:
        bb = ET.SubElement(bindings, "boundbinding")
        ET.SubElement(bb, "deviceid").text = provider_id
        ET.SubElement(bb, "bindingid").text = provider_bindingid
        ET.SubElement(bb, "boundconsumers")
    consumers = bb.find("boundconsumers")
    if consumers is None:
        consumers = ET.SubElement(bb, "boundconsumers")
    for existing in consumers.findall("bound"):
        if (existing.findtext("deviceid") == consumer_id
                and existing.findtext("bindingid") == consumer_bindingid):
            return  # already wired
    bound = ET.SubElement(consumers, "bound")
    ET.SubElement(bound, "deviceid").text = consumer_id
    ET.SubElement(bound, "bindingid").text = consumer_bindingid
    ET.SubElement(bound, "name").text = name
    bcs = ET.SubElement(bound, "boundclasses")
    for cls in classes:
        ET.SubElement(bcs, "boundclass").text = cls


def remove_binding(model: ProjectModel, provider_id: str, provider_bindingid: str,
                   consumer_id: str, consumer_bindingid: str) -> bool:
    """Remove the consumer link from the provider's <boundbinding>. If that leaves the boundbinding
    with no consumers, remove the boundbinding too. Returns True if something was removed."""
    bindings = model.root.find("bindings")
    if bindings is None:
        return False
    bb = _find_boundbinding(bindings, provider_id, provider_bindingid)
    if bb is None:
        return False
    consumers = bb.find("boundconsumers")
    removed = False
    if consumers is not None:
        for bound in list(consumers.findall("bound")):
            if (bound.findtext("deviceid") == consumer_id
                    and bound.findtext("bindingid") == consumer_bindingid):
                consumers.remove(bound)
                removed = True
    if consumers is None or not consumers.findall("bound"):
        bindings.remove(bb)
    return removed


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


def add_location_scaffold(model: ProjectModel, *, home: str = "Home", house: str = "House",
                          floor: str = "Main", room: str = "Room") -> Dict[str, str]:
    """Create the 4-level location tree Home>House>Floor>Room under the project root (item 1),
    matching what Composer seeds when the first controller is added. Returns role->id for
    home/house/floor/room. The four items share one site tag (a fresh GUID), as Composer does."""
    root = model.root
    if _find_item(root, "1") is None:
        raise ValueError("no project-root item (id 1) to attach the location scaffold to")
    ids = next_ids(model, 4)
    id_map = dict(zip(("home", "house", "floor", "room"), ids))
    tag = uuid.uuid4().hex
    tag = f"{tag[:8]}_{tag[8:12]}_{tag[12:16]}_{tag[16:20]}_{tag[20:]}"[:35]

    home_it = _make_item(id_map["home"], home, "2",
                         large_image=_compound.SCAFFOLD["home"]["large_image"],
                         small_image=_compound.SCAFFOLD["home"]["small_image"], tag=tag)
    house_it = _make_item(id_map["house"], house, "3",
                          large_image=_compound.SCAFFOLD["house"]["large_image"],
                          small_image=_compound.SCAFFOLD["house"]["small_image"], tag=tag)
    floor_it = _make_item(id_map["floor"], floor, "4",
                          large_image=_compound.SCAFFOLD["floor"]["large_image"],
                          small_image=_compound.SCAFFOLD["floor"]["small_image"], tag=tag)
    room_it = _make_item(id_map["room"], room, "8", c4i="roomdevice.c4i",
                         state=_compound.SCAFFOLD["room"]["state"],
                         large_image="locations_lg\\room.gif",
                         small_image="locations_sm\\room.gif", tag=tag)

    home_it.find("subitems").append(house_it)
    house_it.find("subitems").append(floor_it)
    floor_it.find("subitems").append(room_it)
    _room_of(root, "1").append(home_it)   # create item-1 <subitems> if the blank project lacks it
    return id_map


def add_controller(model: ProjectModel, room_id: str, controller_driver: str,
                   controller_name: str, *, seed_media: bool = True) -> Dict[str, str]:
    """Add a controller under room_id: the controller item (type 6) + its two proxy subs
    (controller.c4i, uidevice.c4i, type 7), all emitted SKELETAL (empty state) — Director
    regenerates their model-specific state/icons on load. When seed_media is True, also seeds the
    generic media services (Manage Music / Stations / Channels + the digital-audio service) and
    wires the full internal binding topology, reproducing Composer's atomic add-controller compound.
    Returns role->id for every item created. Caller must ensure the referenced driver files are in
    the package's drivers/."""
    root = model.root
    room = _find_item(root, room_id)
    if room is None:
        raise ValueError(f"no room item with id {room_id}")
    room_subs = room.find("subitems")
    if room_subs is None:
        room_subs = ET.SubElement(room, "subitems")

    id_map: Dict[str, str] = {"room": room_id}

    # --- controller + proxy subs (skeletal; Director fills state/icons) ---
    cid, csub, uisub = next_ids(model, 3)
    id_map.update(controller=cid, controller_sub=csub, uidevice_sub=uisub)
    ctrl = _make_item(cid, controller_name, "6", c4i=controller_driver)
    ctrl_sub = _make_item(csub, controller_name, "7", c4i="controller.c4i")
    ui_sub = _make_item(uisub, "UIDevice", "7", c4i="uidevice.c4i")
    ctrl.find("subitems").append(ctrl_sub)
    ctrl.find("subitems").append(ui_sub)
    room_subs.append(ctrl)

    if seed_media:
        # --- generic media services (reuse captured model-independent state) ---
        mm, mmsub, st, stsub, ch, chsub = next_ids(model, 6)
        id_map.update(manage_music=mm, manage_music_sub=mmsub, stations=st,
                      stations_sub=stsub, channels=ch, channels_sub=chsub)
        for svc_role, sub_role, svc_id, sub_id in (
                ("manage_music", "manage_music_sub", mm, mmsub),
                ("stations", "stations_sub", st, stsub),
                ("channels", "channels_sub", ch, chsub)):
            svc_blob = _compound.SCAFFOLD[svc_role]
            svc = _make_item(svc_id, svc_blob["name"], svc_blob["type"], c4i=svc_blob["c4i"],
                             state=svc_blob["state"], large_image=svc_blob["large_image"],
                             small_image=svc_blob["small_image"])
            sub_blob = _compound.SCAFFOLD[sub_role]
            sub = _make_item(sub_id, sub_blob["name"], sub_blob["type"], c4i=sub_blob["c4i"],
                             state=sub_blob["state"], large_image=sub_blob["large_image"],
                             small_image=sub_blob["small_image"])
            svc.find("subitems").append(sub)
            room_subs.append(svc)

        # --- digital-audio service (system-service id range, like Composer's 100002) ---
        da_id = _next_system_id(model)
        id_map["digital_audio"] = da_id
        da_blob = _compound.SCAFFOLD["digital_audio"]
        da = _make_item(da_id, da_blob["name"], da_blob["type"], c4i=da_blob["c4i"],
                        state=da_blob["state"], large_image=da_blob["large_image"],
                        small_image=da_blob["small_image"])
        room_subs.append(da)

        # --- wire the internal binding topology ---
        for prov_role, prov_bid, cons_role, cons_bid, cls, name in _compound.BINDINGS:
            add_binding(model, id_map[prov_role], prov_bid,
                        id_map[cons_role], cons_bid, name, [cls])

    return id_map


def _next_system_id(model: ProjectModel) -> str:
    """Allocate a system-service id in the 100000+ range (media services etc.), separate from the
    user-device sequence tracked by iditemcurrent. Returns the lowest free id >= 100002."""
    used = {it.findtext("id") for it in model.root.iter("item")}
    n = 100002
    while str(n) in used:
        n += 1
    return str(n)


def remove_item(model: ProjectModel, item_id: str) -> bool:
    """Remove an item (and its whole subtree) from the project, plus every binding that references
    any id in that subtree (as provider or consumer). Returns True if the item was found."""
    root = model.root
    it = _find_item(root, item_id)
    if it is None:
        return False
    removed_ids = {x.findtext("id") for x in it.iter("item")}
    parent = _subitems_parent(root, it)
    if parent is not None:
        parent.remove(it)
    bindings = root.find("bindings")
    if bindings is not None:
        for bb in list(bindings.findall("boundbinding")):
            if bb.findtext("deviceid") in removed_ids:
                bindings.remove(bb)
                continue
            bc = bb.find("boundconsumers")
            if bc is not None:
                for bound in list(bc.findall("bound")):
                    if bound.findtext("deviceid") in removed_ids:
                        bc.remove(bound)
                if not bc.findall("bound"):
                    bindings.remove(bb)
    return True


# ---- referential integrity (dependency-aware delete) --------------------------------------------

def _item_name_map(root: ET.Element) -> Dict[str, str]:
    return {it.findtext("id"): (it.findtext("name") or "") for it in root.iter("item")}


def _parse_state_tree(item: ET.Element) -> Optional[ET.Element]:
    st = item.find("state")
    if st is None or not (st.text or "").strip():
        return None
    try:
        return ET.fromstring(st.text)
    except Exception:
        return None


def _enclosing_scene_name(record: ET.Element, parent_map: Dict[ET.Element, ET.Element]) -> Optional[str]:
    cur = record
    while cur is not None:
        if cur.tag == "AdvScene":
            nm = cur.find("name")
            return nm.text if nm is not None else None
        cur = parent_map.get(cur)
    return None


def find_references(model: ProjectModel, ids) -> List[dict]:
    """Find everywhere the given device id(s) are referenced across the project: connections, network
    bindings, programming (triggers + actions), and other items' <state> blobs (lighting-scene
    members, room media lists, ...). Returns dicts {ref_type, holder_id, holder_name, description}
    for the UI to show before a destructive action. Does not mutate."""
    ids = set(ids)
    root = model.root
    names = _item_name_map(root)
    out: List[dict] = []

    def nm(i):
        return names.get(i) or f"device {i}"

    bindings = root.find("bindings")
    if bindings is not None:
        for bb in bindings.findall("boundbinding"):
            prov = bb.findtext("deviceid")
            for bound in bb.findall("boundconsumers/bound"):
                cons = bound.findtext("deviceid")
                if prov in ids and cons not in ids:
                    out.append({"ref_type": "connection", "holder_id": cons, "holder_name": nm(cons),
                                "description": f"connected to {nm(cons)}"})
                elif cons in ids and prov not in ids:
                    out.append({"ref_type": "connection", "holder_id": prov, "holder_name": nm(prov),
                                "description": f"connected from {nm(prov)}"})

    em = root.find("event_mgr")
    if em is not None:
        for ev in em.findall("event"):
            trig = ev.findtext("deviceid")
            if trig in ids:
                out.append({"ref_type": "programming", "holder_id": trig, "holder_name": nm(trig),
                            "description": "triggers a programming rule"})
            for ci in ev.iter("codeitem"):
                if ci.findtext("device") in ids:
                    out.append({"ref_type": "programming", "holder_id": trig, "holder_name": nm(trig),
                                "description": f"used as an action in a rule (triggered by {nm(trig)})"})
                    break

    for it in root.iter("item"):
        iid = it.findtext("id")
        if iid in ids:
            continue
        tree = _parse_state_tree(it)
        if tree is None:
            continue
        parent_map = {c: p for p in tree.iter() for c in p}
        for el in tree.iter():
            if el.tag in ("deviceid", "device_id") and (el.text or "").strip() in ids:
                scene = _enclosing_scene_name(parent_map.get(el), parent_map)
                desc = (f"member of lighting scene '{scene}'" if scene
                        else f"referenced in {nm(iid)}'s configuration")
                out.append({"ref_type": "state", "holder_id": iid, "holder_name": nm(iid),
                            "description": desc})
    return out


def _remove_codeitems_targeting(container: ET.Element, ids) -> int:
    removed = 0

    def walk(ci: ET.Element):
        nonlocal removed
        si = ci.find("subitems")
        if si is None:
            return
        for child in list(si.findall("codeitem")):
            if child.findtext("device") in ids:
                si.remove(child)
                removed += 1
            else:
                walk(child)

    for ci in container.findall("codeitem"):
        walk(ci)
    return removed


def _clean_state_refs(tree: ET.Element, ids) -> int:
    parent_map = {c: p for p in tree.iter() for c in p}
    targets = [el for el in tree.iter()
               if el.tag in ("deviceid", "device_id") and (el.text or "").strip() in ids]
    removed = 0
    for el in targets:
        record = parent_map.get(el)                 # e.g. <AdvSceneMember> or a room's <device>
        record_parent = parent_map.get(record) if record is not None else None
        if record_parent is not None:
            try:
                record_parent.remove(record)
                removed += 1
            except ValueError:
                pass
    return removed


def clean_references(model: ProjectModel, ids) -> Dict[str, int]:
    """Remove dangling references to the given device id(s) so deleting them leaves no inconsistency:
    network bindings, programming (rules triggered by them, and actions targeting them), and other
    items' <state> records (lighting-scene members, room media entries). (Ordinary connection
    bindings are handled by remove_item.) Returns counts by category."""
    ids = set(ids)
    root = model.root
    counts = {"network": 0, "programming": 0, "state": 0}

    nb = root.find("networkbindings")
    if nb is not None:
        for b in list(nb.findall("networkbinding")):
            if b.findtext("deviceid") in ids:
                nb.remove(b)
                counts["network"] += 1

    em = root.find("event_mgr")
    if em is not None:
        for ev in list(em.findall("event")):
            if ev.findtext("deviceid") in ids:
                em.remove(ev)
                counts["programming"] += 1
                continue
            counts["programming"] += _remove_codeitems_targeting(ev, ids)

    for it in root.iter("item"):
        if it.findtext("id") in ids:
            continue
        st = it.find("state")
        if st is None or not (st.text or "").strip():
            continue
        try:
            tree = ET.fromstring(st.text)
        except Exception:
            continue
        n = _clean_state_refs(tree, ids)
        if n:
            st.text = ET.tostring(tree, encoding="unicode")
            counts["state"] += n

    return counts


def add_variable(model: ProjectModel, name: str, var_type: str = "3", *, value: str = "",
                 owner_id: str = "100001", readonly: bool = False, hidden: bool = False,
                 description: str = "") -> str:
    """Add a project variable. var_type: "1"=string, "3"=number, "4"=bool (Composer's codes).
    Owner defaults to the Variables agent (100001). Id allocated from the project id space. Returns
    the new variable id."""
    root = model.root
    v = root.find("variables")
    if v is None:
        v = ET.SubElement(root, "variables")
    vid = next_ids(model, 1)[0]
    var = ET.SubElement(v, "variable")
    var.set("deviceid", owner_id)
    var.set("variableid", vid)
    var.set("name", name)
    var.set("type", var_type)
    var.set("readonly", "1" if readonly else "0")
    var.set("hidden", "1" if hidden else "0")
    var.set("description", description)
    var.text = str(value)
    return vid


def set_variable_value(model: ProjectModel, variable_id: str, value) -> bool:
    """Set a variable's value. Returns True if the variable exists."""
    v = model.root.find("variables")
    if v is None:
        return False
    for var in v.findall("variable"):
        if var.get("variableid") == variable_id:
            var.text = str(value)
            return True
    return False


def remove_variable(model: ProjectModel, variable_id: str) -> bool:
    """Remove a variable. Returns True if it existed."""
    v = model.root.find("variables")
    if v is None:
        return False
    for var in list(v.findall("variable")):
        if var.get("variableid") == variable_id:
            v.remove(var)
            return True
    return False
