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
from dataclasses import dataclass, field
from typing import Dict, List, Optional


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
from .agents import AgentVocab
from .c4p import C4Package
from .drivers import Command, Condition, Connection, Driver, DriverLibrary, Event as DrvEvent, \
    Property, ResolvedApi
from .model import Binding, Event, Item, ItemKind, ProjectModel, Variable
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
        return cls(C4Package.open(path))

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

    def save(self, out_path: Optional[str] = None) -> List[str]:
        """Flush every open state editor into the model, write project.xml, and repackage. If
        out_path is omitted, overwrites the source archive. Returns manifest paths whose md5 changed."""
        for ed in self._editors.values():
            ed.flush()
        self.model.save()
        changed = self._pkg.save(out_path or (self._pkg.source_path or ""))
        self._dirty = False
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

    # ---- read: areas --------------------------------------------------------
    def bindings(self) -> List[Binding]:
        return self.model.bindings()

    def variables(self) -> List[Variable]:
        return self.model.variables()

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
        """Set a driver config property by display name. When validate=True (default) and the item's
        driver declares a schema for this property, the value is checked against it first."""
        if validate:
            schema = {p.name: p for p in self.properties(item_id)}
            p = schema.get(name)
            if p is not None:
                if p.readonly:
                    raise ProjectError(f"property {name!r} is read-only")
                if not p.is_valid(value):
                    allowed = f" allowed: {p.options}" if p.options else \
                        (f" range: [{p.minimum}..{p.maximum}]" if p.minimum is not None else "")
                    raise ProjectError(f"invalid value {value!r} for {name!r} [{p.type}].{allowed}")
        self.state_editor(item_id).set_driver_property(name, value)
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
        self.get(item_id).rename(new_name)
        self._touch()

    def add_device(self, driver_filename: str, name: str, room_id: str) -> str:
        new_id = authoring.add_device(self.model, driver_filename, name, room_id)
        self._touch()
        return new_id

    def add_room(self, floor_id: str, name: str, template_room_id: str) -> str:
        new_id = authoring.add_room(self.model, floor_id, name, template_room_id)
        self._touch()
        return new_id

    def add_location_scaffold(self, **kw) -> Dict[str, str]:
        ids = authoring.add_location_scaffold(self.model, **kw)
        self._touch()
        return ids

    def add_controller(self, room_id: str, controller_driver: str, controller_name: str,
                       **kw) -> Dict[str, str]:
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

    def remove_item(self, item_id: str) -> None:
        if not authoring.remove_item(self.model, item_id):
            raise ProjectError(f"no item with id {item_id!r}")
        self._editors.pop(item_id, None)
        self._touch()

    # ---- write: connections -------------------------------------------------
    def add_binding(self, provider_id: str, provider_bindingid: str, consumer_id: str,
                    consumer_bindingid: str, name: str, classes: List[str]) -> None:
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
