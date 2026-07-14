# c4proj — API & Domain Reference (for the UI build)

This is the contract the UI is built against. The backend is `c4proj`, a Python library that reads,
edits, and writes Control4 `.c4p` project files. The UI never touches `.c4p` internals — it talks to
the **`Project` facade**, whose reads return JSON-serializable data and whose writes are validated.

Real example payloads for every shape below are in **`sample_data.json`** (same folder). Build
against those exact shapes.

---

## 1. Architecture (read this first)

```
   ┌─────────────┐     HTTP/JSON      ┌──────────────────┐   Python    ┌──────────────┐
   │  UI (web)   │  ───────────────▶  │  API server      │  ────────▶  │  c4proj      │  ──▶ .c4p
   │  (you build)│  ◀───────────────  │  (thin wrapper)  │  ◀────────  │  Project     │  ◀── file
   └─────────────┘   surface_of(),    └──────────────────┘  facade     └──────────────┘
                     tree_view(), ...
```

- **Target a cross-platform DESKTOP app** (Windows/macOS) using web UI tech (React) in a native shell
  (**Tauri** preferred; Electron acceptable) — matches the dealer workflow (on-site, offline, local
  `.c4p` files, native open/save dialogs) and avoids browser/hosting friction. See
  `UI_BUILD_PROMPT.md` "Architecture".
- The proven Python `c4proj` backend ships as a **bundled local sidecar**; the "API server" above is a
  thin JSON wrapper (~one endpoint per facade method) that the UI calls over local IPC/HTTP. **Do not
  rewrite the backend** — it's the validated engine. The wrapper is mechanical glue, **generated
  separately, not the design tool's concern.** Design the frontend as if these calls return the JSON
  in `sample_data.json`. Mobile is a later phase (thin client to a backend), not part of this build.
- One `Project` instance = one open project = one editing session. It tracks `dirty`; Save persists
  (`save(out_path)`) a `.c4p` that Composer loads into a Director.

## 2. The core idea: selection → surface

Given any selected item id, `surface_of(id)` returns **everything editable about that selection** in
one object: its config properties (with types + current values + validation), its programmable API
(commands/events/conditions), its connection points, its current bindings, its network address, and
whether it has a special agent-config editor. Think of it as a **portable "context bundle" for the
current focus** — whatever the UI is focused on, this is everything it can show/edit about it, in one
call. (NOTE: do **not** assume a tree-left/detail-right master-detail layout — that classic Composer
arrangement is an explicit anti-goal; see `UI_BUILD_PROMPT.md` "Interaction model". `surface_of`
powers whatever focus-centric model the design uses, not a fixed panel.)

## 3. The domain model

A project is a tree of **items**. Every item has an `id`, `name`, `driver` (a `.c4z`/`.c4i` filename,
empty for structural items), and a **`kind`** (`ItemKind`):

| kind | meaning |
|---|---|
| `PROJECT` | the root ("Russell House") |
| `SITE` / `BUILDING` / `FLOOR` | location scaffold |
| `ROOM` | a room (holds devices) |
| `DEVICE` | a physical device (the thing you install a driver for) |
| `PROXY` | a sub-capability of a device (a keypad-dimmer = a DEVICE with `light` + `keypad` PROXY children) |
| `AGENT` | a system service (Scheduler, Advanced Lighting, Announcements, …) — singleton, not in a room |

**Two kinds of device config** (the UI must present both, but distinctly):
1. **Driver properties** — `surface.properties`, a list of `PropertyValue{name,type,value,default,
   options,minimum,maximum,readonly}`. `type` is `LIST` (dropdown, use `options`), `RANGED_INTEGER`
   (slider/number, use `minimum`/`maximum`), `STRING`, `LABEL` (section header — render as a heading,
   not editable). Edit with `set_property(id, name, value)` — it validates against the schema.
2. **Proxy state fields** — raw device internals (a dimmer's `MAX_ON_LEVEL`, keypad button config).
   Get with `state_fields(id)` → `{path: value}`; edit with `set_state_field(id, path, value)`.
   Present these under an **"Advanced"** disclosure, secondary to #1.

## 4. The Project facade — methods the UI calls

**Lifecycle**
- `Project.open(path)` — open an existing `.c4p`. `Project.new(name)` — start a blank project.
- `dirty` (bool), `save(out_path)`, `close()`. `identity()`, `name`, `version`, `summary()`.

**Read (all return JSON-ready via the *_view methods / to_dict())**
- `tree_view()` → nested `{id,name,kind,driver,children}` — the project tree.
- `surface_of(id).to_dict()` → the selection surface (see §2, sample_data.json).
- `rules_view()` → `[{handle, trigger_device, trigger_event, actions:[…]}]` — programming.
- `variables()`, `bindings()`, `network_bindings()` — dataclass lists (JSON via `asdict`).
- `properties(id)`, `state_fields(id)` — the two config surfaces.
- `search_drivers(query)` → `[DriverHit{name,manufacturer,model,proxy,control,filename,md5sum}]`.
- `missing_drivers()`, `bundled_driver_files()`.

**Write (raise `ProjectError` on bad input — surface the message to the user)**
- Items: `add_device(driver, name, room_id)`, `add_device_from_catalog(hit, name, room_id)` (search
  → install → add, one call), `add_room(floor_id, name)`, `add_location_scaffold(...)`,
  `add_controller(room_id, driver, name)`, `clone_device(id, name)`, `change_driver(id, c4i, name)`,
  `rename(id, name)`, `remove_item(id)`.
- Config: `set_property(id, name, value)`, `set_state_field(id, path, value)`, `agent(id)` (returns
  a specialized config helper, e.g. lighting scenes).
- Connections: `add_binding(provider, provider_bindingid, consumer, consumer_bindingid, name,
  classes)`, `remove_binding(...)`. Network: `set_network_address(device_id, addr)`.
- Variables: `add_variable(name, type)`, `set_variable(id, value)`, `remove_variable(id)`.
- Programming: `add_rule(trigger_device, trigger_event, actions)`, `replace_rule(handle, actions)`,
  `remove_rule(handle)`. Build `actions` from the rule builders: `command`, `agent_command`,
  `set_variable`, `delay`, `break_`, `stop`, `if_(...)`, `while_(...)` (all importable from `c4proj`).

## 5. The five functional areas (Composer's tabs — what each needs)

1. **System Design** — the item tree + add/remove/rename items, add devices from the catalog. Uses
   `tree_view`, `add_device_from_catalog`, `add_room`, `surface_of` (properties).
2. **Connections** — wire devices together. Each device's `surface.connections` are its bindable
   endpoints (`{id,name,type,consumer,classes}`); `surface.bindings_out` are current connections;
   `surface.network` is its IP. `add_binding`/`remove_binding`, `set_network_address`.
3. **Media** — mostly adding media *source* drivers (= `add_device` from catalog). The media library
   itself is runtime data, not authored here.
4. **Agents** — configure system services. `surface_of(agent)`; for agents with a helper,
   `agent_config_kind` is set and `agent(id)` returns a specialized editor (e.g. lighting scenes).
5. **Programming** — event-driven rules. `rules_view()` to list/render; the rule builders +
   `add_rule`/`replace_rule`/`remove_rule` to author. Each device's `surface` gives the vocab: what
   events it fires (triggers), what commands it accepts (actions), what conditions it tests.

## 6. Core create flows (the flows the UI must nail)

- **New project:** `Project.new(name)` → `add_controller(...)` → `add_room(...)` → add devices.
- **Import project:** `Project.open(path)` → edit → `save`.
- **Add a device:** `search_drivers("Sony TV")` → user picks a hit → `add_device_from_catalog(hit,
  name, room_id)`. (Composer's add-device is painful; this should be a single search box.)
- **Configure:** select item → render `surface_of` → edit properties (validated) / agent config.
- **Program:** pick a trigger device+event → build an action list → `add_rule`.

## 7. Rules the UI must respect

- **`LABEL`-type properties are section headers**, not inputs.
- **`readonly` properties** are display-only.
- **Validate before write is automatic** — `set_property` rejects bad LIST/range values with a
  `ProjectError`; show the message.
- **`ItemKind` drives everything** — a ROOM's detail panel ≠ a DEVICE's ≠ an AGENT's.
- **Two property surfaces** (driver properties vs proxy state) — primary vs Advanced.
- **Save is explicit**; reflect `dirty` state; the output `.c4p` is what Composer loads.
