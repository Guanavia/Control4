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
        value, value_type = spec if isinstance(spec, tuple) else (spec, "INTEGER")
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
        dcond.set("name", "==")
        for pname, spec in (params or {}).items():
            value, value_type = spec if isinstance(spec, tuple) else (spec, "int")
            dcond.append(_inline_param(pname, value, value_type))
    else:
        ET.SubElement(dcond, "name").text = name
        if params:
            params_el = ET.SubElement(dcond, "params")
            for pname, spec in params.items():
                value, value_type = spec if isinstance(spec, tuple) else (spec, "INTEGER")
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
