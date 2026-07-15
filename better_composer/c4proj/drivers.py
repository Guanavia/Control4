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
class Property:
    """A driver-declared configuration option — the config surface Composer renders in the
    Properties view. Sourced statically from the driver's <properties> XML (no capture needed)."""
    name: str
    type: str = ""                 # LIST, RANGED_INTEGER, STRING, DYNAMIC_LIST, ...
    default: str = ""
    items: List[str] = field(default_factory=list)   # allowed values for LIST types
    minimum: Optional[str] = None
    maximum: Optional[str] = None
    readonly: bool = False


@dataclass
class ActionParam:
    """A parameter of a driver Action (Composer's Actions tab). `type` can be a rich selector
    (e.g. DEVICE_SELECTOR) with `items` constraining the choices."""
    name: str
    type: str = ""
    items: List[str] = field(default_factory=list)
    multiselect: bool = False


@dataclass
class Action:
    """A dealer-invokable driver action — what Composer renders as the device's Actions tab."""
    name: str
    command: str = ""
    params: List[ActionParam] = field(default_factory=list)


@dataclass
class Tab:
    """A driver-supplied custom tab (embedded HTML UI) — Composer shows these per device."""
    name: str
    file: str = ""


@dataclass
class ProxyRef:
    """A proxy this driver instantiates (combo drivers declare several)."""
    proxy: str                 # proxy type, e.g. "media_service", "light_v2"
    name: str = ""
    small_image: str = ""
    large_image: str = ""


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
    properties: List[Property] = field(default_factory=list)
    # ---- identity / metadata Composer displays ----
    version: str = ""
    created: str = ""
    modified: str = ""
    creator: str = ""
    copyright: str = ""
    control: str = ""                # <control> e.g. "light_v2"
    control_method: str = ""         # <controlmethod> e.g. ip / serial / ir / zigbee / virtual
    categories: List[str] = field(default_factory=list)   # <composer_categories>
    small_icon: str = ""             # path INSIDE the .c4z (e.g. icons/device_sm.png)
    large_icon: str = ""
    combo: bool = False
    minimum_os_version: str = ""
    proxies: List[ProxyRef] = field(default_factory=list)
    # ---- the other Composer tabs ----
    actions: List[Action] = field(default_factory=list)   # Actions tab
    tabs: List[Tab] = field(default_factory=list)         # driver-supplied custom tabs (HTML)
    has_documentation: bool = False                       # Documentation tab
    has_script: bool = False                              # Lua driver (Script/console)

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
    # drivers use <conditionals>/<conditional> (not <conditions>/<condition>)
    c = root.find("conditionals")
    if c is None:
        return out
    for cond in c.findall("conditional"):
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


def _parse_properties(root: ET.Element) -> List["Property"]:
    """Parse the driver's declared config <properties> — name/type/items/min/max/default/readonly.
    This is the per-driver config surface; it needs no capture, just like commands/events."""
    out: List[Property] = []
    # <properties> is a direct child in some drivers and nested under <config> in others.
    c = root.find("properties") or root.find("config/properties")
    if c is None:
        return out
    for p in c.findall("property"):
        items = [(i.text or "").strip() for i in p.findall("items/item")]
        ro = (p.findtext("readonly") or "").strip().lower() == "true"
        out.append(Property(
            name=(p.findtext("name") or "").strip(),
            type=(p.findtext("type") or "").strip(),
            default=(p.findtext("default") or "").strip(),
            items=items,
            minimum=(p.findtext("minimum") or None),
            maximum=(p.findtext("maximum") or None),
            readonly=ro,
        ))
    return out


def _parse_actions(root: ET.Element) -> List["Action"]:
    """<config><actions> — the dealer-invokable actions Composer shows on a device's Actions tab."""
    out: List[Action] = []
    c = root.find("config/actions") or root.find("actions")
    if c is None:
        return out
    for a in c.findall("action"):
        params = []
        for p in a.findall("params/param"):
            params.append(ActionParam(
                name=(p.findtext("name") or "").strip(),
                type=(p.findtext("type") or "").strip(),
                items=[(i.text or "").strip() for i in p.findall("items/item")],
                multiselect=(p.findtext("multiselect") or "").strip().lower() == "true",
            ))
        out.append(Action(name=(a.findtext("name") or "").strip(),
                          command=(a.findtext("command") or "").strip(), params=params))
    return out


def _parse_tabs(root: ET.Element) -> List["Tab"]:
    """<config><tabs> — driver-supplied custom tabs (embedded HTML UIs)."""
    c = root.find("config/tabs") or root.find("tabs")
    if c is None:
        return []
    return [Tab(name=t.get("name", ""), file=t.get("file", "")) for t in c.findall("tab")]


def _parse_proxies(root: ET.Element) -> List["ProxyRef"]:
    """<proxies> — the proxy sub-devices this driver instantiates (combo drivers declare several)."""
    c = root.find("proxies")
    if c is None:
        return []
    out = []
    for p in c.findall("proxies") + c.findall("proxy"):
        out.append(ProxyRef(proxy=(p.text or "").strip(), name=p.get("name", ""),
                            small_image=p.get("small_image", ""),
                            large_image=p.get("large_image", "")))
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
        properties=_parse_properties(root),
        version=(root.findtext("version") or "").strip(),
        created=(root.findtext("created") or "").strip(),
        modified=(root.findtext("modified") or "").strip(),
        creator=(root.findtext("creator") or "").strip(),
        copyright=(root.findtext("copyright") or "").strip(),
        control=(root.findtext("control") or "").strip(),
        control_method=(root.findtext("controlmethod") or "").strip(),
        categories=[(c.text or "").strip()
                    for c in root.findall("composer_categories/category")],
        small_icon=(root.findtext("small") or "").strip(),
        large_icon=(root.findtext("large") or "").strip(),
        combo=(root.findtext("combo") or "").strip().lower() == "true",
        minimum_os_version=(root.findtext("minimum_os_version") or "").strip(),
        proxies=_parse_proxies(root),
        actions=_parse_actions(root),
        tabs=_parse_tabs(root),
        has_documentation=(root.find("config/documentation") is not None
                           or root.find("config/driverdocumentation") is not None),
        has_script=root.find("config/script") is not None,
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
