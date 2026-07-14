# c4proj API server

The local HTTP API that fronts the `c4proj` `Project` facade — the backend the desktop UI talks to.
One open project per session (single-user local desktop model). The core `c4proj` library is
stdlib-only; this server is the one component that depends on FastAPI, and it ships as the desktop
app's bundled backend **sidecar**.

## Run (development)

```bash
cd better_composer
python -m venv .venv && source .venv/bin/activate
pip install -r api_server/requirements.txt
uvicorn api_server.server:app --reload --port 8765
```

- Interactive, auto-generated API docs + try-it console: **http://localhost:8765/docs**
- CORS is wide-open for local dev (the UI runs on a different origin / the Tauri webview).

## Model

- `POST /project/open {path}` or `POST /project/new {name}` opens the session's single project.
- Reads return the same JSON shapes the UI binds to (see `../design_brief/sample_data.json`).
- Writes return `{"ok": true}` or the created id(s). Invalid input (a `ProjectError`) returns **HTTP
  400** with `{"detail": "..."}` — surface that message to the user.
- `POST /project/save {out_path?}` writes the `.c4p`.

## Endpoints (summary)

| Method + path | Facade call |
|---|---|
| `POST /project/open` / `/project/new` / `/project/save` / `/project/close` | open / new / save / close |
| `GET /project`, `GET /health` | identity/summary/dirty |
| `GET /tree` | `tree_view()` |
| `GET /items/{id}/surface` | `surface_of(id)` |
| `GET /items/{id}/references` | `references_to(id)` (call before delete) |
| `GET /items/{id}/connection-candidates` | `connection_candidates(id)` |
| `GET /items/{id}/state-fields` | `state_fields(id)` |
| `GET /rules` `/variables` `/bindings` `/network` | the read-lists |
| `GET /drivers/search?q=` `/drivers/missing` | catalog search / missing |
| `POST /items/device` `/items/device-from-catalog` `/items/room` `/items/controller` | add* |
| `POST /location-scaffold` | `add_location_scaffold` |
| `POST /items/{id}/rename` `/clone` `/change-driver` | rename / clone / change_driver |
| `DELETE /items/{id}?clean_references=` | dependency-aware delete |
| `POST /items/{id}/property` `/state-field` `/network-address` | config writes |
| `POST` / `DELETE /bindings` | add / remove binding |
| `POST /variables`, `PATCH`/`DELETE /variables/{id}` | variable CRUD |
| `GET /rules`, `GET /rules/{handle}/actions` | list rules / a rule's script as action-JSON |
| `POST /rules`, `PUT`/`DELETE /rules/{handle}` | add / replace / delete a rule |

## Authoring rules over the API (action-JSON)

`POST /rules` takes `{trigger_device, trigger_event, actions[]}`. Each action is a JSON node the
server compiles to the programming builders (this is also the shape a linked AI model should emit):

```jsonc
{"type":"command","device":"20","command":"ON","display":"ON","params":{"LEVEL":["50","LEVEL"]}}
{"type":"agent_command","agent":"22","command":"TOGGLE_SCENE","display":"toggle","params":{...}}
{"type":"set_variable","variable_id":"68","value":1,"var_name":"MotionActive"}
{"type":"delay","ms":500}
{"type":"break"}   {"type":"stop"}
{"type":"if","device":"16","conditional":"IS_ON","display":"if on",
 "then":[ ...actions... ], "else":[ ...actions... ],
 "extra_conditions":[["AND","20","IS_ON","and lux on",null]]}
{"type":"while","device":"16","conditional":"IS_ON","display":"while on","body":[ ...actions... ]}
```

`PUT /rules/{handle}` replaces a rule's actions (handle comes from `GET /rules`).

## Packaging note (desktop sidecar)

In the Tauri/Electron app, bundle a Python runtime with `c4proj` + these requirements and spawn
`uvicorn api_server.server:app` on a local port as a child process; the UI calls `http://localhost:<port>`.
The server holds one project in memory for the session.
