"""
project.py — the Project facade: one object a UI (or any caller) binds to.

Everything else in c4proj is a validated PRIMITIVE (parse, edit-a-state-blob, add-a-device, compile-
a-rule, ...). This module is the cohesion layer over them: it owns the open->edit->save lifecycle
(C4Package + ProjectModel + DriverLibrary), presents every functional area through one consistent
API, gives a single `surface_of(item)` that unifies an item's whole editable surface, tracks dirty
state, hands out one cached StateEditor per item (flushed on save), and reports failures with one
error type (ProjectError). Reads return typed dataclasses; writes raise ProjectError on bad input.

Typical use:
    with Project.open("Russell House.c4p") as proj:
        surface = proj.surface_of("16")          # everything editable about item 16
        proj.set_property("16", "Log Level", "3 - Info")
        proj.add_binding(...)
        proj.save("out.c4p")
"""

from __future__ import annotations

import dataclasses
import enum
import os
import shutil
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import Dict, List, Optional

_BLANK_SEED = os.path.join(os.path.dirname(__file__), "templates", "blank.c4p")


def jsonable(obj):
    """Recursively convert a facade value (dataclass / enum / list / dict / primitive) into plain
    JSON-ready types. Use this at a process boundary (web/design-tool UI). It does NOT descend into
    live-XML read models (Item/Event/CodeItem carry ET elements + parent cycles) — use the *_view
    methods on Project for those."""
    if dataclasses.is_dataclass(obj) and not isinstance(obj, type):
        return {f.name: jsonable(getattr(obj, f.name)) for f in dataclasses.fields(obj)}
    if isinstance(obj, enum.Enum):
        return obj.name
    if isinstance(obj, (list, tuple)):
        return [jsonable(x) for x in obj]
    if isinstance(obj, dict):
        return {k: jsonable(v) for k, v in obj.items()}
    return obj

from . import agent_config, authoring
from . import programming as prog
from ._logging import logger
from .agents import AgentVocab
from .c4p import C4Package
from .drivers import Command, Condition, Connection, Driver, DriverLibrary, Event as DrvEvent, \
    Property, ResolvedApi
from .model import Binding, Event, Item, ItemKind, NetworkBinding, ProjectModel, Variable
from .state import StateEditor


class ProjectError(Exception):
    """Any invalid request to the Project facade (missing item, illegal value, ...)."""


@dataclass
class PropertyValue:
    """A driver config property: its declared schema joined with the item's current value. This is
    what a config UI renders one row of."""
    name: str
    type: str
    value: Optional[str]           # current value, or None if unset (defaults apply)
    default: str = ""
    options: List[str] = field(default_factory=list)   # for LIST types
    minimum: Optional[str] = None
    maximum: Optional[str] = None
    readonly: bool = False

    @property
    def effective(self) -> str:
        return self.value if self.value is not None else self.default

    def is_valid(self, candidate=None) -> bool:
        """Is `candidate` (or the current value) legal for this property's schema?"""
        v = self.effective if candidate is None else str(candidate)
        if self.type == "LIST" and self.options:
            return v in self.options
        if self.type in ("RANGED_INTEGER", "RANGED_FLOAT"):
            try:
                n = float(v)
            except ValueError:
                return False
            if self.minimum is not None and n < float(self.minimum):
                return False
            if self.maximum is not None and n > float(self.maximum):
                return False
        return True


@dataclass
class ConnectionCandidate:
    """A valid target for wiring one of a device's connection points: a complementary endpoint
    (provider↔consumer) on another device that shares at least one binding class. This is what a
    Connections UI offers when the user wires a connection, so it never proposes an illegal binding."""
    from_connection_id: str        # the selected device's endpoint
    from_connection_name: str
    from_is_consumer: bool
    to_item_id: str                # the other device
    to_item_name: str
    to_connection_id: str
    to_connection_name: str
    classes: List[str]             # the shared binding class(es)

    def as_binding_args(self, from_item_id: str) -> dict:
        """The provider→consumer arguments for Project.add_binding() to realize this candidate."""
        if self.from_is_consumer:
            provider_id, provider_bid = self.to_item_id, self.to_connection_id
            consumer_id, consumer_bid = from_item_id, self.from_connection_id
        else:
            provider_id, provider_bid = from_item_id, self.from_connection_id
            consumer_id, consumer_bid = self.to_item_id, self.to_connection_id
        return {"provider_id": provider_id, "provider_bindingid": provider_bid,
                "consumer_id": consumer_id, "consumer_bindingid": consumer_bid,
                "name": self.to_connection_name, "classes": self.classes}


@dataclass
class Reference:
    """One place a device is referenced elsewhere in the project. Shown to the user before a
    destructive action (dependency-aware delete)."""
    ref_type: str        # "connection" | "programming" | "state" | "network"
    holder_id: str       # the item that holds/depends on the reference
    holder_name: str
    description: str      # human-readable ("member of lighting scene 'House Off'", ...)


@dataclass
class EditableSurface:
    """The complete editable surface of one selected item — the thing a UI needs to render a
    property/programming/connections panel for a selection, gathered in one place."""
    item_id: str
    name: str
    kind: ItemKind
    driver: str
    properties: List[PropertyValue]          # config surface (schema + values)
    commands: List[Command]                  # programmable: actions you can send it
    events: List[DrvEvent]                    # programmable: triggers it fires
    conditions: List[Condition]              # programmable: conditionals you can test
    connections: List[Connection]            # bindable endpoints declared by its driver
    bindings_out: List[Binding]              # connections currently made FROM this item
    network: List[NetworkBinding] = field(default_factory=list)  # IP/serial network config
    agent_config_kind: Optional[str] = None  # e.g. "advanced_lighting" if a config helper exists

    def to_dict(self) -> dict:
        """JSON-ready snapshot for sending across a process boundary (web/design-tool UI)."""
        return jsonable(self)


# driver-filename fragments -> the agent-config helper class that edits that agent's sub-model
_AGENT_CONFIG_HELPERS = {
    "adv_lighting": ("advanced_lighting", agent_config.AdvancedLighting),
    "advanced_lighting": ("advanced_lighting", agent_config.AdvancedLighting),
}


class Project:
    """A live, editable Control4 project. Open it, read/edit through the area methods, then save.
    Not thread-safe; intended to be driven by one UI session."""

    def __init__(self, pkg: C4Package):
        self._pkg = pkg
        self.model = ProjectModel(pkg.project_xml)
        self.drivers = DriverLibrary(pkg.path("drivers"))
        self.agent_vocab = AgentVocab()
        self._editors: Dict[str, StateEditor] = {}
        self._index: Optional[Dict[str, Item]] = None
        self._dirty = False

    # ---- lifecycle ----------------------------------------------------------
    @classmethod
    def open(cls, path: str) -> "Project":
        logger.debug("Project.open(%r)", path)
        p = cls(C4Package.open(path))
        logger.debug("  opened %r v%s (%d items)", p.name, p.version, len(p.items()))
        return p

    @classmethod
    def new(cls, name: Optional[str] = None) -> "Project":
        """Start a brand-new project from the bundled blank seed (one project-root item, empty
        sections) — the 'New Project' flow. Add a controller (add_controller) + rooms + devices,
        then save(out_path). Optionally set the project name."""
        work = os.path.join(tempfile.mkdtemp(prefix="c4new_"), "new.c4p")
        shutil.copy(_BLANK_SEED, work)
        proj = cls(C4Package.open(work))
        if name:
            root_item = proj.model.root.find("./systemitems/item")
            if root_item is not None:
                nm = root_item.find("name")
                if nm is not None:
                    nm.text = name
                    proj._touch()
        return proj

    def close(self) -> None:
        self._pkg.close()

    def __enter__(self) -> "Project":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    @property
    def dirty(self) -> bool:
        return self._dirty

    def _touch(self) -> None:
        self._dirty = True
        self._index = None   # structural or state edits can invalidate the id index

    @staticmethod
    def _require_name(name: str) -> str:
        if name is None or not str(name).strip():
            raise ProjectError("name must not be empty")
        return name

    def save(self, out_path: Optional[str] = None) -> List[str]:
        """Flush every open state editor into the model, write project.xml, and repackage. If
        out_path is omitted, overwrites the source archive. Returns manifest paths whose md5 changed."""
        logger.debug("Project.save(out_path=%r) [dirty=%s, %d cached editors]",
                     out_path, self._dirty, len(self._editors))
        for ed in self._editors.values():
            ed.flush()
        self.model.save()
        changed = self._pkg.save(out_path or (self._pkg.source_path or ""))
        self._dirty = False
        logger.debug("  saved; %d manifest file(s) changed", len(changed))
        return changed

    # ---- identity -----------------------------------------------------------
    def identity(self) -> dict:
        return self._pkg.identity()

    @property
    def name(self) -> str:
        return self.model.project_name

    @property
    def version(self) -> str:
        return self.model.project_version

    def summary(self) -> Dict[str, int]:
        return self.model.summary()

    # ---- read: items --------------------------------------------------------
    def tree(self) -> List[Item]:
        return self.model.device_tree()

    def items(self) -> List[Item]:
        return self.model.all_devices()

    def export_slim_dict(self) -> dict:
        """A compact overview of the project — small enough to load wholesale into a design/AI tool's
        context (~10x smaller than export_dict). Keeps everything structural and every device's CONFIG
        properties (what a Properties panel renders), but summarizes the bulky per-device programming
        vocabulary to counts + a few samples, and omits raw proxy state fields. Use export_dict() for
        the complete data to look things up in."""
        items = {}
        for it in self.items():
            s = self.surface_of(it.id)
            items[it.id] = {
                "id": it.id, "name": it.name, "kind": it.kind.name, "driver": it.driver,
                "properties": [dataclasses.asdict(pv) for pv in s.properties],
                "counts": {"commands": len(s.commands), "events": len(s.events),
                           "conditions": len(s.conditions), "connections": len(s.connections),
                           "bindings_out": len(s.bindings_out)},
                "sample_commands": [c.name for c in s.commands[:8]],
                "sample_events": [e.name for e in s.events[:8]],
                "network": [dataclasses.asdict(n) for n in s.network],
                "agent_config_kind": s.agent_config_kind,
            }
        return {
            "project": {"name": self.name, "version": self.version,
                        "identity": self.identity(), "summary": self.summary()},
            "tree": self.tree_view(),
            "items": items,
            "rules": [dict(r, action_json=self.rule_actions(r["handle"]))
                      for r in self.rules_view()],
            "variables": [dataclasses.asdict(v) for v in self.variables()],
            "bindings": [dataclasses.asdict(b) for b in self.bindings()],
            "network_bindings": [dataclasses.asdict(n) for n in self.network_bindings()],
        }

    def export_dict(self, *, include_state_fields: bool = True) -> dict:
        """A complete, JSON-ready snapshot of the whole project — every shape the UI binds to, in the
        same form the API returns. Intended for handing real project data to a design/UI tool without
        the ~125MB of driver binaries a .c4p carries (a 417-device project exports to ~2MB).

        Contains: project identity/summary, the full item tree, per-item editable surfaces (config
        properties with schema+values, programmable commands/events/conditions, connection points,
        current bindings, network address) + raw proxy state fields, all programming rules (with
        their action-JSON), variables, bindings, and network bindings.

        NOTE: this is REAL project data (room/device names, IP addresses). Treat it as private.
        """
        items = {}
        for it in self.items():
            entry = self.surface_of(it.id).to_dict()
            if include_state_fields:
                try:
                    entry["state_fields"] = self.state_fields(it.id)
                except Exception:
                    entry["state_fields"] = {}
            items[it.id] = entry
        return {
            "project": {"name": self.name, "version": self.version,
                        "identity": self.identity(), "summary": self.summary()},
            "tree": self.tree_view(),
            "items": items,
            "rules": [dict(r, action_json=self.rule_actions(r["handle"]))
                      for r in self.rules_view()],
            "variables": [dataclasses.asdict(v) for v in self.variables()],
            "bindings": [dataclasses.asdict(b) for b in self.bindings()],
            "network_bindings": [dataclasses.asdict(n) for n in self.network_bindings()],
            "drivers": {"bundled": self.bundled_driver_files(),
                        "missing": self.missing_drivers()},
        }

    def tree_view(self) -> List[dict]:
        """JSON-ready nested tree ({id,name,kind,driver,children}) for a UI. The live Item objects
        (from tree()) carry XML elements and parent cycles and can't be serialized directly."""
        def view(it: Item) -> dict:
            return {"id": it.id, "name": it.name, "kind": it.kind.name,
                    "driver": it.driver, "children": [view(c) for c in it.children]}
        return [view(r) for r in self.tree()]

    def _idx(self) -> Dict[str, Item]:
        if self._index is None:
            self._index = {it.id: it for it in self.model.all_devices()}
        return self._index

    def find(self, item_id: str) -> Optional[Item]:
        return self._idx().get(item_id)

    def get(self, item_id: str) -> Item:
        it = self.find(item_id)
        if it is None:
            raise ProjectError(f"no item with id {item_id!r}")
        return it

    def kind(self, item_id: str) -> ItemKind:
        return self.get(item_id).kind

    # ---- read: drivers ------------------------------------------------------
    def driver_of(self, item_id: str) -> Optional[Driver]:
        it = self.get(item_id)
        return self.drivers.get(it.driver) if it.driver else None

    def resolve(self, item_id: str) -> Optional[ResolvedApi]:
        """The item's programmable surface (commands/events/conditions). Resolves through the driver
        XML like any device; for an AGENT (whose vocab isn't in XML) it falls back to the bundled
        reverse-engineered agent vocab."""
        it = self.get(item_id)
        if not it.driver:
            return None
        api = self.drivers.resolve(it.driver)
        if api and (api.commands or api.events or api.conditions):
            return api
        agent_api = self.agent_vocab.resolve(it.driver)
        return agent_api if agent_api is not None else api

    # ---- driver catalog + install ------------------------------------------
    def bundled_driver_files(self) -> List[str]:
        d = self._pkg.path("drivers")
        return sorted(os.listdir(d)) if os.path.isdir(d) else []

    def missing_drivers(self) -> List[str]:
        """Driver files referenced by items but NOT present in the package's drivers/. Note: some
        are Director-internal (roomdevice.c4i, control4_agent_*.c4i) that Director supplies at load
        and needn't be bundled; the rest are genuinely missing and should be install_driver()'d."""
        bundled = set(self.bundled_driver_files())
        referenced = {it.driver for it in self.items() if it.driver}
        return sorted(referenced - bundled)

    def search_drivers(self, query: str, rows: int = 20):
        """Search the online Control4 driver catalog. Returns DriverHit dataclasses (serializable)."""
        from . import repo
        return repo.search(query, rows=rows)

    def install_driver(self, driver, md5: Optional[str] = None) -> str:
        """Download a driver into the package's drivers/ so it's bundled for save/load, and refresh
        the driver library. `driver` is a filename str or a DriverHit (from search_drivers). Returns
        the installed filename."""
        from . import repo
        filename = getattr(driver, "filename", driver)
        expect_md5 = getattr(driver, "md5sum", None) or md5
        dest = self._pkg.path("drivers")
        os.makedirs(dest, exist_ok=True)
        logger.debug("install_driver(%r) downloading -> %s", filename, dest)
        repo.download(filename, dest, expect_md5=expect_md5)
        logger.debug("  installed %r", filename)
        self.drivers = DriverLibrary(dest)   # re-index so the new driver resolves
        self._touch()
        return filename

    def add_device_from_catalog(self, driver, name: str, room_id: str) -> str:
        """One-call add-device create flow: install the catalog driver into the package, then add a
        device instance of it to the room. `driver` is a DriverHit or filename str. Returns item id."""
        filename = self.install_driver(driver)
        return self.add_device(filename, name, room_id)

    # ---- read: areas --------------------------------------------------------
    def bindings(self) -> List[Binding]:
        return self.model.bindings()

    def variables(self) -> List[Variable]:
        return self.model.variables()

    def network_bindings(self) -> List[NetworkBinding]:
        return self.model.network_bindings()

    def set_network_address(self, device_id: str, address: str) -> None:
        """Set an IP/serial device's network address (Connections > Network). Updates the device's
        existing <networkbinding>; raises ProjectError if it has none (address bindings are normally
        created by discovery on load, not authored from scratch)."""
        nb = self.model.root.find("networkbindings")
        target = None
        if nb is not None:
            for b in nb.findall("networkbinding"):
                if b.findtext("deviceid") == device_id:
                    target = b
                    break
        if target is None:
            raise ProjectError(f"device {device_id} has no network binding to set an address on")
        addr = target.find("addr")
        if addr is None:
            addr = ET.SubElement(target, "addr")
        addr.text = address
        self._touch()

    def rules(self) -> List[Event]:
        return self.model.events()

    def rule_handle(self, rule: Event) -> str:
        """A session-stable string id for a rule (Composer <event>s have no unique id, and two rules
        can share a trigger, so a UI needs this to target one across a boundary)."""
        return str(id(rule.el))

    def rules_view(self) -> List[dict]:
        """JSON-ready rules: each with a stable `handle`, its trigger, and its action tree. Pass the
        handle back to remove_rule/replace_rule."""
        def ci_view(ci) -> dict:
            return {"id": ci.id, "device": ci.device, "type": ci.type, "display": ci.display,
                    "command": ci.command, "children": [ci_view(c) for c in ci.children]}
        out = []
        for ev in self.rules():
            out.append({
                "handle": self.rule_handle(ev),
                "trigger_device": ev.deviceid,
                "trigger_event": ev.eventid,
                "actions": [ci_view(c) for c in ev.codeitems],
            })
        return out

    def rule_actions(self, rule) -> list:
        """A rule's script as action-JSON (the same shape add_rule/replace_rule accept) — so a UI can
        load an existing rule into its editor and round-trip it. `rule` is an Event or handle string."""
        return prog.decompile_event(self._resolve_rule(rule))

    def _resolve_rule(self, rule) -> Event:
        """Accept a rule as an Event object or a handle string (from rules_view)."""
        if isinstance(rule, str):
            for e in self.model.root.findall("event_mgr/event"):
                if str(id(e)) == rule:
                    return Event(e)
            raise ProjectError(f"no rule with handle {rule!r}")
        return rule

    def _read_editor(self, item_id: str) -> StateEditor:
        """A StateEditor for READING: the cached (possibly edited) one if it exists, else a transient
        one — so reads reflect pending edits without spuriously caching/dirtying on a plain read."""
        return self._editors.get(item_id) or StateEditor(self.get(item_id).el)

    def properties(self, item_id: str) -> List[PropertyValue]:
        """The item's config properties: driver-declared schema joined with current stored values."""
        drv = self.driver_of(item_id)
        schema: List[Property] = drv.properties if drv else []
        values = self._read_editor(item_id).driver_properties()
        out: List[PropertyValue] = []
        seen = set()
        for p in schema:
            seen.add(p.name)
            out.append(PropertyValue(
                name=p.name, type=p.type, value=values.get(p.name), default=p.default,
                options=list(p.items), minimum=p.minimum, maximum=p.maximum, readonly=p.readonly,
            ))
        # values present on the item but not in the (bundled) schema — still surface them
        for name, val in values.items():
            if name not in seen:
                out.append(PropertyValue(name=name, type="", value=val))
        return out

    def surface_of(self, item_id: str) -> EditableSurface:
        """One call: everything editable about the selected item — properties (schema+values),
        programmable API (commands/events/conditions), bindable connection points, current outgoing
        bindings, and whether a dedicated agent-config helper exists."""
        it = self.get(item_id)
        api = self.resolve(item_id)
        drv = self.driver_of(item_id)
        agent_kind = None
        if it.kind is ItemKind.AGENT and it.driver:
            for frag, (label, _cls) in _AGENT_CONFIG_HELPERS.items():
                if frag in it.driver:
                    agent_kind = label
                    break
        return EditableSurface(
            item_id=item_id,
            name=it.name,
            kind=it.kind,
            driver=it.driver,
            properties=self.properties(item_id),
            commands=api.commands if api else [],
            events=api.events if api else [],
            conditions=api.conditions if api else [],
            connections=drv.connections if drv else [],
            bindings_out=[b for b in self.model.bindings() if b.provider_deviceid == item_id],
            network=[nb for nb in self.model.network_bindings() if nb.deviceid == item_id],
            agent_config_kind=agent_kind,
        )

    # ---- write: state / config ---------------------------------------------
    def state_editor(self, item_id: str) -> StateEditor:
        """The single cached StateEditor for this item (created once; flushed on save). Using the
        cached instance avoids the lost-update hazard of two editors on the same item."""
        if item_id not in self._editors:
            self._editors[item_id] = StateEditor(self.get(item_id).el)
        return self._editors[item_id]

    def set_property(self, item_id: str, name: str, value, *, validate: bool = True) -> None:
        """Set a driver CONFIG property by display name (the <property><name>/<value> surface —
        i.e. what `properties()` / `surface_of().properties` return). When validate=True (default)
        the name must be a real config property of this item and the value must satisfy its schema —
        this guards against silently creating a bogus property from a typo or from a proxy state
        field. For raw proxy state fields (a dimmer's MAX_ON_LEVEL, keypad button config, ...) use
        set_state_field() instead."""
        if validate:
            schema = {p.name: p for p in self.properties(item_id)}
            p = schema.get(name)
            if p is None:
                raise ProjectError(
                    f"{name!r} is not a config property of item {item_id}. Use one of "
                    f"properties()'s names, or set_state_field() for raw proxy state fields.")
            if p.readonly:
                raise ProjectError(f"property {name!r} is read-only")
            if not p.is_valid(value):
                allowed = f" allowed: {p.options}" if p.options else \
                    (f" range: [{p.minimum}..{p.maximum}]" if p.minimum is not None else "")
                raise ProjectError(f"invalid value {value!r} for {name!r} [{p.type}].{allowed}")
        logger.debug("set_property(%r, %r, %r)", item_id, name, value)
        self.state_editor(item_id).set_driver_property(name, value)
        self._touch()

    def state_fields(self, item_id: str) -> Dict[str, str]:
        """Flat {path: value} of an item's raw <state> — the proxy-level config (dimmer levels,
        keypad buttons, ...) that lives as direct state fields rather than driver <properties>.
        Paths use the /TAG/CHILD[i] notation; edit with set_state_field()."""
        return self._read_editor(item_id).fields()

    def set_state_field(self, item_id: str, path: str, value) -> None:
        """Set a raw <state> field by path (e.g. '/MAX_ON_LEVEL'). The proxy-state config surface,
        distinct from driver config properties (set_property)."""
        self.state_editor(item_id).set(path, value)
        self._touch()

    def agent(self, item_id: str):
        """Return the dedicated config helper for an agent (e.g. AdvancedLighting), or raise if none
        is known for that agent's driver. Edits made through it are flushed on save via the shared
        editor cache."""
        it = self.get(item_id)
        if it.kind is not ItemKind.AGENT:
            raise ProjectError(f"item {item_id} is not an agent (kind={it.kind.name})")
        for frag, (_label, cls) in _AGENT_CONFIG_HELPERS.items():
            if frag in (it.driver or ""):
                self._touch()
                return cls(self.model, item_id, editor=self.state_editor(item_id))
        raise ProjectError(f"no config helper for agent driver {it.driver!r}")

    # ---- write: items -------------------------------------------------------
    def rename(self, item_id: str, new_name: str) -> None:
        self.get(item_id).rename(self._require_name(new_name))
        self._touch()

    def add_device(self, driver_filename: str, name: str, room_id: str) -> str:
        self._require_name(name)
        new_id = authoring.add_device(self.model, driver_filename, name, room_id)
        self._touch()
        return new_id

    def add_room(self, floor_id: str, name: str, template_room_id: Optional[str] = None) -> str:
        self._require_name(name)
        new_id = authoring.add_room(self.model, floor_id, name, template_room_id)
        self._touch()
        return new_id

    def add_location_scaffold(self, **kw) -> Dict[str, str]:
        ids = authoring.add_location_scaffold(self.model, **kw)
        self._touch()
        return ids

    def add_controller(self, room_id: str, controller_driver: str, controller_name: str,
                       **kw) -> Dict[str, str]:
        self._require_name(controller_name)
        ids = authoring.add_controller(self.model, room_id, controller_driver, controller_name, **kw)
        self._touch()
        return ids

    def clone_device(self, source_id: str, new_name: str, skeletal: bool = False) -> Dict[str, str]:
        ids = authoring.clone_device(self.model, source_id, new_name, skeletal=skeletal)
        self._touch()
        return ids

    def change_driver(self, item_id: str, new_c4i: str, new_name: str) -> None:
        authoring.change_driver(self.model, item_id, new_c4i, new_name)
        self._editors.pop(item_id, None)   # state was stripped; drop any cached editor
        self._touch()

    def _subtree_ids(self, item_id: str) -> set:
        """All item ids under (and including) item_id — a device plus its proxy subs."""
        return {x.findtext("id") for x in self.get(item_id).el.iter("item")}

    def references_to(self, item_id: str) -> List[Reference]:
        """Everywhere this item (and its proxy subs) is referenced elsewhere — connections,
        programming rules, lighting scenes / room lists, network. Show these before deleting so the
        user knows what a delete affects. Empty list = safe to remove with no cleanup."""
        ids = self._subtree_ids(item_id)
        return [Reference(**r) for r in authoring.find_references(self.model, ids)]

    def remove_item(self, item_id: str, *, clean_references: bool = False) -> None:
        """Remove an item (and its subtree) plus its bindings. When clean_references=True, ALSO
        remove dangling references to it elsewhere (rules triggered by / targeting it, lighting-scene
        members, room media entries, network bindings) so the project stays internally consistent —
        this is the safe, dependency-aware delete a UI should use after confirming with the user."""
        ids = self._subtree_ids(item_id)
        logger.debug("remove_item(%r, clean_references=%s) [subtree ids=%s]",
                     item_id, clean_references, sorted(ids))
        if clean_references:
            # clean_references edits other items' <state> directly on the tree; a cached StateEditor
            # holds a stale parsed copy that would clobber that on save. So: flush pending editor
            # edits into the tree, clean, then drop all caches (they re-parse the cleaned state).
            for ed in self._editors.values():
                ed.flush()
            authoring.clean_references(self.model, ids)
            self._editors.clear()
        if not authoring.remove_item(self.model, item_id):
            raise ProjectError(f"no item with id {item_id!r}")
        for i in ids:
            self._editors.pop(i, None)
        self._touch()

    # ---- write: connections -------------------------------------------------
    def connection_candidates(self, item_id: str,
                              connection_id: Optional[str] = None) -> List[ConnectionCandidate]:
        """Valid wiring targets for a device's connection point(s): complementary endpoints
        (provider↔consumer) on OTHER devices that share a binding class. Pass connection_id to scope
        to one endpoint. The UI offers these so it never proposes an illegal binding; realize a choice
        with `add_binding(**candidate.as_binding_args(item_id))`."""
        src = self.driver_of(item_id)
        if src is None:
            return []
        src_conns = [c for c in src.connections
                     if connection_id is None or c.id == connection_id]
        if not src_conns:
            return []
        others = [(it, self.driver_of(it.id))
                  for it in self.items() if it.id != item_id and it.driver]
        out: List[ConnectionCandidate] = []
        for sc in src_conns:
            sc_classes = set(sc.classes)
            for it, drv in others:
                if drv is None:
                    continue
                for oc in drv.connections:
                    if sc.consumer == oc.consumer:   # need one provider + one consumer
                        continue
                    shared = sc_classes & set(oc.classes)
                    if not shared:
                        continue
                    out.append(ConnectionCandidate(
                        from_connection_id=sc.id, from_connection_name=sc.name,
                        from_is_consumer=sc.consumer,
                        to_item_id=it.id, to_item_name=it.name,
                        to_connection_id=oc.id, to_connection_name=oc.name,
                        classes=sorted(shared)))
        return out

    def add_binding(self, provider_id: str, provider_bindingid: str, consumer_id: str,
                    consumer_bindingid: str, name: str, classes: List[str]) -> None:
        """Wire a connection provider->consumer. Both device ids must exist in the project (guards a
        UI against silently creating a dangling binding from a stale/typo id, which breaks load)."""
        if self.find(provider_id) is None:
            raise ProjectError(f"provider device {provider_id!r} does not exist")
        if self.find(consumer_id) is None:
            raise ProjectError(f"consumer device {consumer_id!r} does not exist")
        authoring.add_binding(self.model, provider_id, provider_bindingid, consumer_id,
                              consumer_bindingid, name, classes)
        self._touch()

    def remove_binding(self, provider_id: str, provider_bindingid: str, consumer_id: str,
                       consumer_bindingid: str) -> bool:
        removed = authoring.remove_binding(self.model, provider_id, provider_bindingid,
                                           consumer_id, consumer_bindingid)
        self._touch()
        return removed

    # ---- write: variables ---------------------------------------------------
    def add_variable(self, name: str, var_type: str = "3", **kw) -> str:
        self._require_name(name)
        vid = authoring.add_variable(self.model, name, var_type, **kw)
        self._touch()
        return vid

    def set_variable(self, variable_id: str, value) -> None:
        if not authoring.set_variable_value(self.model, variable_id, value):
            raise ProjectError(f"no variable with id {variable_id!r}")
        self._touch()

    def remove_variable(self, variable_id: str) -> None:
        if not authoring.remove_variable(self.model, variable_id):
            raise ProjectError(f"no variable with id {variable_id!r}")
        self._touch()

    # ---- write: programming -------------------------------------------------
    def add_rule(self, trigger_device_id: str, trigger_event_id: str, actions: list):
        logger.debug("add_rule(trigger=%s/%s, %d action(s))",
                     trigger_device_id, trigger_event_id, len(actions))
        ev = prog.add_event_handler(self.model, trigger_device_id, trigger_event_id, actions)
        self._touch()
        return ev

    def replace_rule(self, rule, actions: list):
        """Edit a rule's actions. `rule` is an Event (from rules()) or a handle string (rules_view)."""
        ev = self._resolve_rule(rule)
        try:
            new = prog.replace_event_actions(self.model, ev, actions)
        except ValueError as e:
            raise ProjectError(str(e))
        self._touch()
        return new

    def remove_rule(self, rule) -> None:
        """Delete a rule. `rule` is an Event (from rules()) or a handle string (rules_view)."""
        ev = self._resolve_rule(rule)
        if not prog.remove_event_handler(self.model, ev):
            raise ProjectError("rule not found in this project")
        self._touch()
