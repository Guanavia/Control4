"""
drivers.py — read driver metadata from the .c4z / .c4i files bundled in a project.

Why this exists: project.xml tells you *which* devices exist and how they're wired, but not
what each device can *do*. That lives in the driver files, and — crucially — the proxy
definitions are bundled right alongside the drivers. A device driver declares
`<proxy>light_v2</proxy>`; the proxy driver (`light_v2.c4i`) declares the actual
`<commands>`, `<conditions>`, and `<events>`. So a device's full programmable surface resolves
locally: device driver -> its proxy driver -> commands/conditions/events.

This is the half of the model the "when X, do Y" programming UI is built on: for any device it
answers "what can trigger on it (events), what can I make it do (commands), what can I test
(conditions)".

Driver file shapes:
  *.c4i  — a single XML file, root <devicedata>
  *.c4z  — a zip containing driver.xml (root <devicedata>) plus lua/docs/icons

Command/event/condition schema: <id>, <name>, <description>. Parameters are expressed as
UPPERCASE placeholder tokens inside the description template (e.g. "Set Level on the NAME to
INTEGER" -> the device NAME plus an INTEGER parameter). We surface those as inferred params.
"""

from __future__ import annotations

import os
import re
import zipfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import Dict, List, Optional

# UPPERCASE tokens that appear in descriptions. NAME/BTN_NAME refer to the device/button
# itself; the rest denote a value the user supplies when programming.
_PLACEHOLDER = re.compile(r"\b([A-Z][A-Z0-9_]{2,})\b")
_SELF_TOKENS = {"NAME", "BTN_NAME", "LED", "ALL"}


def _params_from_desc(desc: str) -> List[str]:
    toks = []
    for m in _PLACEHOLDER.findall(desc or ""):
        if m in _SELF_TOKENS or m in toks:
            continue
        toks.append(m)
    return toks


@dataclass
class Command:
    id: str
    name: str
    description: str = ""
    params: List[str] = field(default_factory=list)


@dataclass
class Event:
    id: str
    name: str
    description: str = ""


@dataclass
class Condition:
    id: str
    name: str
    description: str = ""
    params: List[str] = field(default_factory=list)


@dataclass
class Connection:
    id: str
    name: str
    type: str = ""
    consumer: bool = False
    classes: List[str] = field(default_factory=list)


@dataclass
class Driver:
    filename: str
    name: str = ""
    manufacturer: str = ""
    model: str = ""
    proxy: str = ""
    capabilities: List[str] = field(default_factory=list)
    connections: List[Connection] = field(default_factory=list)
    commands: List[Command] = field(default_factory=list)
    conditions: List[Condition] = field(default_factory=list)
    events: List[Event] = field(default_factory=list)

    @property
    def stem(self) -> str:
        return os.path.splitext(self.filename)[0]

    @property
    def is_proxy_like(self) -> bool:
        """Declares its own commands/events -> acts as (or is) a proxy definition."""
        return bool(self.commands or self.events)


def _driver_root(path: str) -> Optional[ET.Element]:
    if path.endswith(".c4i"):
        return ET.parse(path).getroot()
    if path.endswith(".c4z"):
        with zipfile.ZipFile(path) as z:
            for n in z.namelist():
                if n.lower().endswith("driver.xml"):
                    return ET.fromstring(z.read(n))
    return None


def _parse_commands(root: ET.Element) -> List[Command]:
    out = []
    c = root.find("commands")
    if c is None:
        return out
    for cmd in c.findall("command"):
        desc = (cmd.findtext("description") or "").strip()
        out.append(Command(
            id=(cmd.findtext("id") or "").strip(),
            name=(cmd.findtext("name") or "").strip(),
            description=desc,
            params=_params_from_desc(desc),
        ))
    return out


def _parse_conditions(root: ET.Element) -> List[Condition]:
    out = []
    c = root.find("conditions")
    if c is None:
        return out
    for cond in c.findall("condition"):
        desc = (cond.findtext("description") or "").strip()
        out.append(Condition(
            id=(cond.findtext("id") or "").strip(),
            name=(cond.findtext("name") or "").strip(),
            description=desc,
            params=_params_from_desc(desc),
        ))
    return out


def _parse_events(root: ET.Element) -> List[Event]:
    out = []
    e = root.find("events")
    if e is None:
        return out
    for ev in e.findall("event"):
        out.append(Event(
            id=(ev.findtext("id") or "").strip(),
            name=(ev.findtext("name") or "").strip(),
            description=(ev.findtext("description") or "").strip(),
        ))
    return out


def _parse_connections(root: ET.Element) -> List[Connection]:
    out = []
    c = root.find("connections")
    if c is None:
        return out
    for conn in c.findall("connection"):
        classes = [cl.findtext("classname") or "" for cl in conn.findall("classes/class")]
        out.append(Connection(
            id=(conn.findtext("id") or "").strip(),
            name=(conn.findtext("connectionname") or "").strip(),
            type=(conn.findtext("type") or "").strip(),
            consumer=(conn.findtext("consumer") or "").strip().lower() == "true",
            classes=[c for c in classes if c],
        ))
    return out


def load_driver(path: str) -> Optional[Driver]:
    root = _driver_root(path)
    if root is None:
        return None
    caps = [c.tag for c in root.find("capabilities")] if root.find("capabilities") is not None else []
    return Driver(
        filename=os.path.basename(path),
        name=(root.findtext("name") or "").strip(),
        manufacturer=(root.findtext("manufacturer") or "").strip(),
        model=(root.findtext("model") or "").strip(),
        proxy=(root.findtext("proxy") or "").strip(),
        capabilities=caps,
        connections=_parse_connections(root),
        commands=_parse_commands(root),
        conditions=_parse_conditions(root),
        events=_parse_events(root),
    )


@dataclass
class ResolvedApi:
    """The effective programmable surface of a device: its driver's own declarations merged
    with everything inherited from its proxy chain."""
    commands: List[Command]
    conditions: List[Condition]
    events: List[Event]
    driver_chain: List[str]      # filenames walked, device driver first
    unresolved_proxy: Optional[str] = None


class DriverLibrary:
    """Index of every driver file in a project's drivers/ directory."""

    def __init__(self, drivers_dir: str):
        self.dir = drivers_dir
        self.by_file: Dict[str, Driver] = {}
        self.by_stem: Dict[str, Driver] = {}
        self._load()

    def _load(self) -> None:
        if not os.path.isdir(self.dir):
            return
        for f in os.listdir(self.dir):
            if not (f.endswith(".c4i") or f.endswith(".c4z")):
                continue
            try:
                d = load_driver(os.path.join(self.dir, f))
            except Exception:
                d = None
            if d is None:
                continue
            self.by_file[f] = d
            self.by_stem[d.stem] = d

    def get(self, c4i_filename: str) -> Optional[Driver]:
        if not c4i_filename:
            return None
        if c4i_filename in self.by_file:
            return self.by_file[c4i_filename]
        stem = os.path.splitext(c4i_filename)[0]
        return self.by_stem.get(stem)

    def _find_proxy(self, proxy_name: str) -> Optional[Driver]:
        if not proxy_name:
            return None
        # proxy "light_v2" -> light_v2.c4i ; "keypad" -> keypad_proxy.c4i
        for stem in (proxy_name, proxy_name + "_proxy"):
            if stem in self.by_stem:
                return self.by_stem[stem]
        return None

    def resolve(self, c4i_filename: str) -> Optional[ResolvedApi]:
        """Effective commands/conditions/events for a device given its driver filename,
        walking the proxy chain and merging (child declarations win on id collision)."""
        drv = self.get(c4i_filename)
        if drv is None:
            return None
        commands: Dict[str, Command] = {}
        conditions: Dict[str, Condition] = {}
        events: Dict[str, Event] = {}
        chain: List[str] = []
        unresolved = None
        seen = set()
        cur: Optional[Driver] = drv
        while cur is not None and cur.filename not in seen:
            seen.add(cur.filename)
            chain.append(cur.filename)
            for c in cur.commands:
                commands.setdefault(c.id or c.name, c)
            for c in cur.conditions:
                conditions.setdefault(c.id or c.name, c)
            for e in cur.events:
                events.setdefault(e.id or e.name, e)
            if cur.proxy:
                nxt = self._find_proxy(cur.proxy)
                if nxt is None:
                    unresolved = cur.proxy
                cur = nxt
            else:
                cur = None
        return ResolvedApi(
            commands=list(commands.values()),
            conditions=list(conditions.values()),
            events=list(events.values()),
            driver_chain=chain,
            unresolved_proxy=unresolved,
        )
