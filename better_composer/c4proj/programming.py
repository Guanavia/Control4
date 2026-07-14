"""
programming.py — the rule -> codeitem XML compiler (write side of Composer's Programming view).

Grammar is fully decoded in PROGRAMMING.md (prog01-14 captures). This module builds `<event>`/
`<codeitem>` trees matching that spec and appends them to a ProjectModel's `<event_mgr>`.

Codeitem ids are sequential WITHIN an event, starting at 0 for the root container -- a completely
separate id space from the project-wide item ids `next_ids()` (authoring.py) allocates.

Everything here builds `ET.Element` trees ("codeitems") that compose via nesting (subitems). A
codeitem is either a leaf action (command/delay/break/stop/set-variable) or a container (if/else/
while) whose body is a list of child codeitems.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from typing import List, Optional

from .model import ProjectModel

PROGRAMMING_DEVICE = "100000"  # pseudo-device: Delay/Break/Stop/Else/And-Or live here
VARIABLES_AGENT = "100001"


class _IdCounter:
    """Sequential codeitem ids within one event; root container is always id 0."""

    def __init__(self):
        self.next = 1

    def take(self) -> str:
        v = str(self.next)
        self.next += 1
        return v


def _codeitem(counter: _IdCounter, device: str, type_: str, display: str,
              cmdcond: Optional[ET.Element] = None,
              subitems: Optional[List[ET.Element]] = None,
              expression: Optional[List[ET.Element]] = None,
              item_id: Optional[str] = None) -> ET.Element:
    ci = ET.Element("codeitem")
    ET.SubElement(ci, "id").text = item_id if item_id is not None else counter.take()
    ET.SubElement(ci, "device").text = device
    ET.SubElement(ci, "type").text = type_
    ET.SubElement(ci, "display").text = display
    if cmdcond is not None:
        ci.append(cmdcond)
    else:
        ET.SubElement(ci, "cmdcond")
    if expression is not None:
        expr_el = ET.SubElement(ci, "expression")
        for e in expression:
            expr_el.append(e)
    if subitems is not None:
        sub_el = ET.SubElement(ci, "subitems")
        for s in subitems:
            sub_el.append(s)
    else:
        ET.SubElement(ci, "subitems")
    ET.SubElement(ci, "creator").text = "0"
    ET.SubElement(ci, "creatorstate")
    ET.SubElement(ci, "enabled").text = "True"
    return ci


def _value_param(name: str, value, value_type: str = "INTEGER") -> ET.Element:
    """Device-command/conditional param: <param><name>N</name><value type=T><static>V</static></value></param>"""
    p = ET.Element("param")
    ET.SubElement(p, "name").text = name
    v = ET.SubElement(p, "value")
    v.set("type", value_type)
    ET.SubElement(v, "static").text = str(value)
    return p


def _inline_param(name: str, value, value_type: str = "int") -> ET.Element:
    """Variable-op param: <param name="value" type="int">V</param> (inline, no nested <value>)."""
    p = ET.Element("param")
    p.set("name", name)
    p.set("type", value_type)
    p.text = str(value)
    return p


# ---- leaf actions (type=1 command) -----------------------------------------------------------

def command(device_id: str, command_name: str, display: str,
            params: Optional[dict] = None, owner_type: str = "", owner_id: str = "-1") -> "_Item":
    """A plain device (or agent, with owner_type='agent') command. `params` maps name->(value, type)."""
    dc = ET.Element("devicecommand")
    dc.set("owneridtype", owner_type)
    dc.set("owneriditem", owner_id)
    ET.SubElement(dc, "command").text = command_name
    params_el = ET.SubElement(dc, "params")
    for name, spec in (params or {}).items():
        value, value_type = spec if isinstance(spec, (tuple, list)) else (spec, "INTEGER")
        params_el.append(_value_param(name, value, value_type))
    cc = ET.Element("cmdcond")
    cc.append(dc)
    return _Item(device=device_id, type_="1", display=display, cmdcond=cc)


def agent_command(agent_id: str, command_name: str, display: str, params: Optional[dict] = None) -> "_Item":
    return command(agent_id, command_name, display, params=params, owner_type="agent", owner_id="0")


def set_variable(variable_id: str, value, display: Optional[str] = None, var_name: str = "") -> "_Item":
    """`{var} = value` -- owneridtype=variable, name="=", inline int param."""
    dc = ET.Element("devicecommand")
    dc.set("owneridtype", "variable")
    dc.set("owneriditem", variable_id)
    dc.set("name", "=")
    dc.append(_inline_param("value", value, "int"))
    cc = ET.Element("cmdcond")
    cc.append(dc)
    disp = display or f'#!"{var_name} = {value}";{var_name}="{var_name}:{VARIABLES_AGENT},{variable_id}"'
    return _Item(device=VARIABLES_AGENT, type_="1", display=disp, cmdcond=cc)


def delay(ms: int) -> "_Item":
    return command(PROGRAMMING_DEVICE, "DELAY", f"Delay {ms}ms", params={"time": (ms, "INT")})


def break_() -> "_Item":
    dc = ET.Element("devicecommand")
    ET.SubElement(dc, "command").text = "BREAK"
    cc = ET.Element("cmdcond")
    cc.append(dc)
    return _Item(device=PROGRAMMING_DEVICE, type_="1", display="Break", cmdcond=cc)


def stop() -> "_Item":
    dc = ET.Element("devicecommand")
    ET.SubElement(dc, "command").text = "RETURN"
    cc = ET.Element("cmdcond")
    cc.append(dc)
    return _Item(device=PROGRAMMING_DEVICE, type_="1", display="Stop", cmdcond=cc)


# ---- conditionals + containers (type=2 if, 3 while, 4 else, 6 and/or) ------------------------

def _conditional_cmdcond(name: str, params: Optional[dict], owner_type: str, owner_id: str) -> ET.Element:
    dcond = ET.Element("deviceconditional")
    dcond.set("owneridtype", owner_type)
    dcond.set("owneriditem", owner_id)
    if owner_type == "variable":
        # `name` carries the comparison operator for variable conditions (==, !=, >, <, >=, <=).
        dcond.set("name", name or "==")
        for pname, spec in (params or {}).items():
            value, value_type = spec if isinstance(spec, (tuple, list)) else (spec, "int")
            dcond.append(_inline_param(pname, value, value_type))
    else:
        ET.SubElement(dcond, "name").text = name
        if params:
            params_el = ET.SubElement(dcond, "params")
            for pname, spec in params.items():
                value, value_type = spec if isinstance(spec, (tuple, list)) else (spec, "INTEGER")
                params_el.append(_value_param(pname, value, value_type))
    cc = ET.Element("cmdcond")
    cc.append(dcond)
    return cc


def _and_or_node() -> "_Item":
    """type=6 operator node inside an <expression> block. `display` (AND/OR) set by caller."""
    return _Item(device=PROGRAMMING_DEVICE, type_="6", display="")


def if_(device_id: str, conditional_name: str, display: str, then: List["_Item"],
        else_: Optional[List["_Item"]] = None, params: Optional[dict] = None,
        owner_type: str = "", owner_id: str = "-1",
        extra_conditions: Optional[List[tuple]] = None) -> List["_Item"]:
    """Returns [if_item] or [if_item, else_item] -- else is a SIBLING of the if, not nested in it.
    extra_conditions: list of ("AND"|"OR", device_id, conditional_name, display, params) chained via
    <expression> -- each tuple adds one operator node + one more condition to the compound test."""
    cc = _conditional_cmdcond(conditional_name, params, owner_type, owner_id)
    expr = None
    if extra_conditions:
        expr = []
        for op, dev, cname, cdisplay, cparams in extra_conditions:
            op_node = _and_or_node()
            op_node.display = op
            expr.append(op_node)
            cond_item = _Item(device=dev, type_="2", display=cdisplay,
                               cmdcond=_conditional_cmdcond(cname, cparams, "", "-1"))
            expr.append(cond_item)
    item = _Item(device=device_id, type_="2", display=display, cmdcond=cc, subitems=then, expression=expr)
    items = [item]
    if else_ is not None:
        items.append(_Item(device=PROGRAMMING_DEVICE, type_="4", display="Else", subitems=else_))
    return items


def while_(device_id: str, conditional_name: str, display: str, body: List["_Item"],
           params: Optional[dict] = None) -> "_Item":
    cc = _conditional_cmdcond(conditional_name, params, "", "-1")
    return _Item(device=device_id, type_="3", display=display, cmdcond=cc, subitems=body)


# ---- assembly ----------------------------------------------------------------------------------

def _flatten_actions(actions):
    """Expand any list elements one level so builders compose uniformly. Needed because if_()
    returns a LIST ([if] or [if, else] — else is a sibling codeitem), while every other builder
    returns a single _Item. Lets a caller write actions=[cmd, if_(...), delay(...)] naturally."""
    out = []
    for a in actions or []:
        if isinstance(a, (list, tuple)):
            out.extend(a)
        else:
            out.append(a)
    return out


class _Item:
    """A not-yet-materialized codeitem: holds enough to build() once we have an _IdCounter."""

    def __init__(self, device: str, type_: str, display: str, cmdcond: Optional[ET.Element] = None,
                 subitems: Optional[List["_Item"]] = None, expression: Optional[list] = None):
        self.device = device
        self.type_ = type_
        self.display = display
        self.cmdcond = cmdcond
        self.subitems = subitems
        self.expression = expression

    def build(self, counter: _IdCounter) -> ET.Element:
        my_id = counter.take()
        sub_built = ([s.build(counter) for s in _flatten_actions(self.subitems)]
                     if self.subitems is not None else None)
        expr_built = None
        if self.expression is not None:
            expr_built = []
            for e in self.expression:
                expr_built.append(e.build(counter) if isinstance(e, _Item) else e)
        return _codeitem(counter, self.device, self.type_, self.display,
                          cmdcond=self.cmdcond, subitems=sub_built, expression=expr_built,
                          item_id=my_id)


def add_event_handler(model: ProjectModel, trigger_device_id: str, trigger_event_id: str,
                       actions: List["_Item"]) -> ET.Element:
    """Create a new <event> (trigger) whose script is `actions`, sequential codeitem ids assigned
    within this event (root container = id 0). Appends to (creating if needed) <event_mgr>."""
    em = model.root.find("event_mgr")
    if em is None:
        em = ET.SubElement(model.root, "event_mgr")

    counter = _IdCounter()
    built_actions = [a.build(counter) for a in _flatten_actions(actions)]

    root_ci = ET.Element("codeitem")
    ET.SubElement(root_ci, "id").text = "0"
    ET.SubElement(root_ci, "device").text = "0"
    ET.SubElement(root_ci, "type").text = "1"
    ET.SubElement(root_ci, "display")
    ET.SubElement(root_ci, "cmdcond")
    sub_el = ET.SubElement(root_ci, "subitems")
    for a in built_actions:
        sub_el.append(a)
    ET.SubElement(root_ci, "creator").text = "0"
    ET.SubElement(root_ci, "creatorstate")
    ET.SubElement(root_ci, "enabled").text = "True"

    event_el = ET.SubElement(em, "event")
    ET.SubElement(event_el, "deviceid").text = trigger_device_id
    ET.SubElement(event_el, "eventid").text = trigger_event_id
    event_el.append(root_ci)
    return event_el


def _param_value(param_el: ET.Element):
    """Return (value, type) from a param, handling both encodings: <value type=T><static>V</static>
    </value> (device commands) and inline <param name=.. type=..>V</param> (variable ops)."""
    v = param_el.find("value")
    if v is not None:
        static = v.find("static")
        return (static.text if static is not None else None), v.get("type")
    return param_el.text, param_el.get("type")


def _decompile_params(container: ET.Element) -> dict:
    out = {}
    params_el = container.find("params")
    if params_el is not None:
        for p in params_el.findall("param"):
            out[p.findtext("name")] = list(_param_value(p))
    for p in container.findall("param"):        # inline (variable-op) params
        if p.get("name"):
            out[p.get("name")] = [p.text, p.get("type")]
    return out


def _decompile_expression(expr_el: ET.Element) -> list:
    """<expression> -> extra_conditions [[op, device, conditional, display, params], ...]."""
    ecs, op = [], None
    for el in expr_el.findall("codeitem"):
        if el.findtext("type") == "6":
            op = el.findtext("display")
        else:
            dcond = el.find("cmdcond/deviceconditional")
            params = _decompile_params(dcond) if dcond is not None else {}
            cname = (dcond.findtext("name") or dcond.get("name")) if dcond is not None else None
            ecs.append([op, el.findtext("device"), cname, el.findtext("display") or "",
                        params or None])
    return ecs


def _decompile_codeitem(ci: ET.Element):
    """One codeitem -> one action-JSON node (the inverse of api_server's _build_action). Returns None
    for structural nodes handled by the caller (else/operator)."""
    typ = ci.findtext("type")
    device = ci.findtext("device")
    display = ci.findtext("display") or ""
    if typ == "1":
        dc = ci.find("cmdcond/devicecommand")
        cmd = dc.findtext("command") if dc is not None else None
        if device == PROGRAMMING_DEVICE:
            if cmd == "DELAY":
                params = _decompile_params(dc) if dc is not None else {}
                ms = (params.get("time") or [0])[0]
                return {"type": "delay", "ms": int(ms) if str(ms).isdigit() else ms}
            if cmd == "BREAK":
                return {"type": "break"}
            if cmd == "RETURN":
                return {"type": "stop"}
        owner = dc.get("owneridtype") if dc is not None else ""
        if owner == "variable":
            params = _decompile_params(dc)
            return {"type": "set_variable", "variable_id": dc.get("owneriditem"),
                    "value": (params.get("value") or [None])[0], "display": display}
        node = {"type": "agent_command" if owner == "agent" else "command",
                "command": cmd, "display": display}
        node["agent" if owner == "agent" else "device"] = device
        params = _decompile_params(dc) if dc is not None else {}
        if params:
            node["params"] = params
        return node
    if typ in ("2", "3"):
        dcond = ci.find("cmdcond/deviceconditional")
        node = {"type": "if" if typ == "2" else "while", "device": device, "display": display}
        if dcond is not None:
            node["conditional"] = dcond.findtext("name") or dcond.get("name")
            owner = dcond.get("owneridtype")
            if owner:
                node["owner_type"] = owner
                node["owner_id"] = dcond.get("owneriditem")
            params = _decompile_params(dcond)
            if params:
                node["params"] = params
        if typ == "2":
            expr = ci.find("expression")
            if expr is not None:
                ecs = _decompile_expression(expr)
                if ecs:
                    node["extra_conditions"] = ecs
            node["then"] = _decompile_subitems(ci.find("subitems"))
        else:
            node["body"] = _decompile_subitems(ci.find("subitems"))
        return node
    return None  # type 4 (else) paired by caller; type 6 handled in expression


def _decompile_subitems(subitems_el: Optional[ET.Element]) -> list:
    if subitems_el is None:
        return []
    cis = subitems_el.findall("codeitem")
    out, i = [], 0
    while i < len(cis):
        ci = cis[i]
        if ci.findtext("type") == "4":       # stray else without a preceding if
            i += 1
            continue
        node = _decompile_codeitem(ci)
        if node is not None:
            if node.get("type") == "if" and i + 1 < len(cis) and cis[i + 1].findtext("type") == "4":
                node["else"] = _decompile_subitems(cis[i + 1].find("subitems"))
                i += 1
            out.append(node)
        i += 1
    return out


def decompile_event(event) -> list:
    """A rule's script as action-JSON — the inverse of add_event_handler's builders — so a UI can
    load an existing rule back into its visual/expression editor and round-trip it. `event` is a
    model.Event or an <event> element."""
    ev = getattr(event, "el", event)
    root = ev.find("codeitem")
    return _decompile_subitems(root.find("subitems")) if root is not None else []


def remove_event_handler(model: ProjectModel, event) -> bool:
    """Remove a rule. `event` is a model.Event (wrapping the live <event> element). Returns True
    if it was found and removed."""
    em = model.root.find("event_mgr")
    if em is None:
        return False
    target = getattr(event, "el", event)
    for e in list(em.findall("event")):
        if e is target:
            em.remove(e)
            return True
    return False


def replace_event_actions(model: ProjectModel, event, actions: List["_Item"]) -> ET.Element:
    """Edit a rule by replacing its whole action script, keeping the same trigger. Returns the new
    <event> element. (Composer rules are event-anchored; editing = rebuild the script under the
    same trigger — the compiler reassigns codeitem ids.)"""
    trigger_dev, trigger_evt = event.deviceid, event.eventid
    if not remove_event_handler(model, event):
        raise ValueError("event not found in this project's event_mgr")
    return add_event_handler(model, trigger_dev, trigger_evt, actions)
