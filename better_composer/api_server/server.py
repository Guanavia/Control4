"""
api_server/server.py — the local HTTP API that fronts the c4proj Project facade.

This is the "thin wrapper" the desktop UI talks to: one open project per session (single-user local
desktop model), every facade capability exposed as a JSON endpoint. The core `c4proj` library stays
stdlib-only; this server is the one place that depends on FastAPI, and it ships as the desktop app's
bundled backend sidecar.

Run for development:
    uvicorn api_server.server:app --reload --port 8765
(from the `better_composer/` directory, with c4proj importable). Interactive docs at /docs.
"""

from __future__ import annotations

import dataclasses
import os
import time
import urllib.error
import zipfile
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel

import c4proj
from c4proj import Project, ProjectError
from c4proj import programming as prog
from c4proj import logger as c4logger

app = FastAPI(title="c4proj API", version="1.0",
              description="Local API over the c4proj Project facade (Control4 .c4p editor backend).")

# Permissive CORS for local dev (the UI runs on a different port / the Tauri webview).
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


# Enable debug logging at startup from env: C4PROJ_DEBUG=1 [C4PROJ_DEBUG_LOG=/path/to/debug.log]
if os.environ.get("C4PROJ_DEBUG", "").lower() in ("1", "true", "yes"):
    c4proj.enable_debug_logging(os.environ.get("C4PROJ_DEBUG_LOG") or None)


@app.middleware("http")
async def _log_requests(request: Request, call_next):
    # When debug logging is on, record each request + its status/timing.
    if not c4proj.is_debug_enabled():
        return await call_next(request)
    t0 = time.time()
    c4logger.debug("--> %s %s", request.method, request.url.path)
    response = await call_next(request)
    c4logger.debug("<-- %s %s %s (%dms)", request.method, request.url.path,
                   response.status_code, int((time.time() - t0) * 1000))
    return response

# ---- session (one open project) -----------------------------------------------------------------
_session: Dict[str, Optional[Project]] = {"project": None}


def proj() -> Project:
    p = _session["project"]
    if p is None:
        raise HTTPException(status_code=409, detail="no project open (POST /project/open or /project/new)")
    return p


# Client-caused errors (bad path, bad file, bad id/input) -> 400 with a clean message.
_CLIENT_ERRORS = (ProjectError, FileNotFoundError, IsADirectoryError, ValueError, KeyError,
                  zipfile.BadZipFile, urllib.error.URLError)


@app.exception_handler(ProjectError)
def _project_error(_request, exc: ProjectError):
    return JSONResponse(status_code=400, content={"detail": str(exc)})


@app.exception_handler(FileNotFoundError)
def _not_found(_request, exc: FileNotFoundError):
    return JSONResponse(status_code=400, content={"detail": f"file not found: {exc.filename or exc}"})


@app.exception_handler(Exception)
def _unexpected(_request, exc: Exception):
    # Known client-input errors -> 400; anything truly unexpected -> 500. Either way, return a clean
    # message (never leak a stack trace to the UI) and never let a request crash.
    status = 400 if isinstance(exc, _CLIENT_ERRORS) else 500
    return JSONResponse(status_code=status, content={"detail": f"{type(exc).__name__}: {exc}"})


def _aslist(items) -> List[dict]:
    return [dataclasses.asdict(i) for i in items]


# ---- lifecycle ----------------------------------------------------------------------------------
class OpenReq(BaseModel):
    path: str


class NewReq(BaseModel):
    name: Optional[str] = None


class SaveReq(BaseModel):
    out_path: Optional[str] = None


def _project_info(p: Project) -> dict:
    return {"name": p.name, "version": p.version, "dirty": p.dirty,
            "identity": p.identity(), "summary": p.summary()}


@app.get("/health")
def health():
    return {"ok": True, "project_open": _session["project"] is not None}


class DebugReq(BaseModel):
    enabled: bool
    path: Optional[str] = None      # log file path; default ~/.c4proj/debug.log


@app.get("/debug")
def debug_get():
    """Current debug-logging state + log file path."""
    return {"enabled": c4proj.is_debug_enabled(), "path": c4proj.debug_log_path()}


@app.post("/debug")
def debug_set(req: DebugReq):
    """Toggle debug logging (the UI's 'create debug logs' switch). When enabled, backend operations
    and API requests are written to the log file; returns its path."""
    if req.enabled:
        path = c4proj.enable_debug_logging(req.path)
        return {"enabled": True, "path": path}
    c4proj.disable_debug_logging()
    return {"enabled": False, "path": None}


@app.post("/project/open")
def project_open(req: OpenReq):
    if _session["project"] is not None:
        _session["project"].close()
    _session["project"] = Project.open(req.path)
    return _project_info(_session["project"])


@app.post("/project/new")
def project_new(req: NewReq):
    if _session["project"] is not None:
        _session["project"].close()
    _session["project"] = Project.new(req.name)
    return _project_info(_session["project"])


@app.get("/project")
def project_get():
    return _project_info(proj())


@app.post("/project/save")
def project_save(req: SaveReq):
    changed = proj().save(req.out_path)
    return {"saved": True, "changed": changed, "dirty": proj().dirty}


@app.post("/project/close")
def project_close():
    if _session["project"] is not None:
        _session["project"].close()
        _session["project"] = None
    return {"closed": True}


# ---- reads --------------------------------------------------------------------------------------
@app.get("/tree")
def tree():
    return proj().tree_view()


@app.get("/items/{item_id}/surface")
def surface(item_id: str):
    return proj().surface_of(item_id).to_dict()


@app.get("/items/{item_id}/references")
def references(item_id: str):
    return _aslist(proj().references_to(item_id))


@app.get("/items/{item_id}/connection-candidates")
def connection_candidates(item_id: str, connection_id: Optional[str] = None):
    return _aslist(proj().connection_candidates(item_id, connection_id))


@app.get("/items/{item_id}/state-fields")
def state_fields(item_id: str):
    return proj().state_fields(item_id)


@app.get("/rules")
def rules():
    return proj().rules_view()


@app.get("/rules/{handle}/actions")
def rule_actions(handle: str):
    """The rule's script as action-JSON (same shape POST/PUT accept) — load an existing rule into the
    editor and round-trip it."""
    return proj().rule_actions(handle)


@app.get("/variables")
def variables():
    return _aslist(proj().variables())


@app.get("/bindings")
def bindings():
    return _aslist(proj().bindings())


@app.get("/network")
def network():
    return _aslist(proj().network_bindings())


@app.get("/drivers/search")
def drivers_search(q: str, rows: int = 20):
    return _aslist(proj().search_drivers(q, rows=rows))


@app.get("/drivers/missing")
def drivers_missing():
    return {"missing": proj().missing_drivers(), "bundled": proj().bundled_driver_files()}


# ---- item writes --------------------------------------------------------------------------------
class AddDeviceReq(BaseModel):
    driver: str
    name: str
    room_id: str


class AddDeviceCatalogReq(BaseModel):
    filename: str
    md5: Optional[str] = None
    name: str
    room_id: str


class AddRoomReq(BaseModel):
    floor_id: str
    name: str
    template_room_id: Optional[str] = None


class AddControllerReq(BaseModel):
    room_id: str
    driver: str
    name: str
    seed_media: bool = True


class ScaffoldReq(BaseModel):
    home: str = "Home"
    house: str = "House"
    floor: str = "Main"
    room: str = "Room"


class RenameReq(BaseModel):
    name: str


class CloneReq(BaseModel):
    name: str


class ChangeDriverReq(BaseModel):
    c4i: str
    name: str


@app.post("/items/device")
def add_device(req: AddDeviceReq):
    return {"id": proj().add_device(req.driver, req.name, req.room_id)}


@app.post("/items/device-from-catalog")
def add_device_from_catalog(req: AddDeviceCatalogReq):
    # accept a bare filename (+optional md5); install_driver handles the DriverHit-or-filename form
    class _Hit:
        filename = req.filename
        md5sum = req.md5
    return {"id": proj().add_device_from_catalog(_Hit(), req.name, req.room_id)}


@app.post("/items/room")
def add_room(req: AddRoomReq):
    return {"id": proj().add_room(req.floor_id, req.name, req.template_room_id)}


@app.post("/items/controller")
def add_controller(req: AddControllerReq):
    return proj().add_controller(req.room_id, req.driver, req.name, seed_media=req.seed_media)


@app.post("/location-scaffold")
def location_scaffold(req: ScaffoldReq):
    return proj().add_location_scaffold(home=req.home, house=req.house, floor=req.floor, room=req.room)


@app.post("/items/{item_id}/rename")
def rename(item_id: str, req: RenameReq):
    proj().rename(item_id, req.name)
    return {"ok": True}


@app.post("/items/{item_id}/clone")
def clone(item_id: str, req: CloneReq):
    return {"id_map": proj().clone_device(item_id, req.name)}


@app.post("/items/{item_id}/change-driver")
def change_driver(item_id: str, req: ChangeDriverReq):
    proj().change_driver(item_id, req.c4i, req.name)
    return {"ok": True}


@app.delete("/items/{item_id}")
def remove_item(item_id: str, clean_references: bool = False):
    proj().remove_item(item_id, clean_references=clean_references)
    return {"ok": True}


# ---- config writes ------------------------------------------------------------------------------
class SetPropertyReq(BaseModel):
    name: str
    value: Any
    validate_value: bool = True


class SetStateFieldReq(BaseModel):
    path: str
    value: Any


class NetworkAddressReq(BaseModel):
    address: str


@app.post("/items/{item_id}/property")
def set_property(item_id: str, req: SetPropertyReq):
    proj().set_property(item_id, req.name, req.value, validate=req.validate_value)
    return {"ok": True}


@app.post("/items/{item_id}/state-field")
def set_state_field(item_id: str, req: SetStateFieldReq):
    proj().set_state_field(item_id, req.path, req.value)
    return {"ok": True}


@app.post("/items/{item_id}/network-address")
def set_network_address(item_id: str, req: NetworkAddressReq):
    proj().set_network_address(item_id, req.address)
    return {"ok": True}


# ---- connections --------------------------------------------------------------------------------
class BindingReq(BaseModel):
    provider_id: str
    provider_bindingid: str
    consumer_id: str
    consumer_bindingid: str
    name: str = ""
    classes: List[str] = []


@app.post("/bindings")
def add_binding(req: BindingReq):
    proj().add_binding(req.provider_id, req.provider_bindingid, req.consumer_id,
                       req.consumer_bindingid, req.name, req.classes)
    return {"ok": True}


@app.delete("/bindings")
def remove_binding(req: BindingReq):
    removed = proj().remove_binding(req.provider_id, req.provider_bindingid,
                                    req.consumer_id, req.consumer_bindingid)
    return {"removed": removed}


# ---- variables ----------------------------------------------------------------------------------
class AddVariableReq(BaseModel):
    name: str
    type: str = "3"
    value: str = ""


class SetVariableReq(BaseModel):
    value: Any


@app.post("/variables")
def add_variable(req: AddVariableReq):
    return {"id": proj().add_variable(req.name, req.type, value=req.value)}


@app.patch("/variables/{variable_id}")
def set_variable(variable_id: str, req: SetVariableReq):
    proj().set_variable(variable_id, req.value)
    return {"ok": True}


@app.delete("/variables/{variable_id}")
def remove_variable(variable_id: str):
    proj().remove_variable(variable_id)
    return {"ok": True}


# ---- programming --------------------------------------------------------------------------------
def _build_action(a: dict):
    """Compile one action-JSON node into a programming builder result. Supports nesting for if/while.

    Shapes:
      {"type":"command","device":ID,"command":NAME,"display":TXT,"params":{k:[val,type]}}
      {"type":"agent_command","agent":ID,"command":NAME,"display":TXT,"params":{...}}
      {"type":"set_variable","variable_id":ID,"value":V,"var_name":NAME}
      {"type":"delay","ms":N}   {"type":"break"}   {"type":"stop"}
      {"type":"if","device":ID,"conditional":NAME,"display":TXT,"then":[...],"else":[...],
       "params":{...},"owner_type":"","owner_id":"-1","extra_conditions":[[op,dev,cond,disp,params],...]}
      {"type":"while","device":ID,"conditional":NAME,"display":TXT,"body":[...],"params":{...}}
    """
    t = a.get("type")
    if t == "command":
        return prog.command(a["device"], a["command"], a.get("display", a["command"]),
                            params=a.get("params"))
    if t == "agent_command":
        return prog.agent_command(a["agent"], a["command"], a.get("display", a["command"]),
                                  params=a.get("params"))
    if t == "set_variable":
        return prog.set_variable(a["variable_id"], a["value"], display=a.get("display"),
                                 var_name=a.get("var_name", ""))
    if t == "delay":
        return prog.delay(int(a["ms"]))
    if t == "break":
        return prog.break_()
    if t == "stop":
        return prog.stop()
    if t == "if":
        then = [_build_action(x) for x in a.get("then", [])]
        els = [_build_action(x) for x in a["else"]] if a.get("else") else None
        return prog.if_(a["device"], a["conditional"], a.get("display", ""), then, else_=els,
                        params=a.get("params"), owner_type=a.get("owner_type", ""),
                        owner_id=a.get("owner_id", "-1"),
                        extra_conditions=[tuple(ec) for ec in a["extra_conditions"]]
                        if a.get("extra_conditions") else None)
    if t == "while":
        body = [_build_action(x) for x in a.get("body", [])]
        return prog.while_(a["device"], a["conditional"], a.get("display", ""), body,
                           params=a.get("params"))
    raise HTTPException(status_code=400, detail=f"unknown action type {t!r}")


class AddRuleReq(BaseModel):
    trigger_device: str
    trigger_event: str
    actions: List[dict]


@app.post("/rules")
def add_rule(req: AddRuleReq):
    actions = [_build_action(a) for a in req.actions]
    proj().add_rule(req.trigger_device, req.trigger_event, actions)
    return {"ok": True}


class ReplaceRuleReq(BaseModel):
    actions: List[dict]


@app.put("/rules/{handle}")
def replace_rule(handle: str, req: ReplaceRuleReq):
    actions = [_build_action(a) for a in req.actions]
    proj().replace_rule(handle, actions)
    return {"ok": True}


@app.delete("/rules/{handle}")
def remove_rule(handle: str):
    proj().remove_rule(handle)
    return {"ok": True}
