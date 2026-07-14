# Base Prompt — Modern Control4 Project Editor UI

> Hand this to the design/build tool as the starting brief. Add your own visual/aesthetic direction
> on top (color, typography, density, brand feel). Two companion files provide the hard facts:
> **`API_REFERENCE.md`** (the backend contract + domain model) and **`sample_data.json`** (real
> payloads for every API shape). Build against those exact shapes — they are not mock data.

## What we're building

A modern replacement for Control4's **Composer Pro** — the dealer tool for building and editing home
automation projects (devices, rooms, connections, programming, system agents). Composer Pro works but
its UX is dated and painful; **a cleaner, faster, more intuitive editor is the entire reason this
project exists.** This is a from-scratch UI, not a reskin — feel free to rethink the interaction model
completely, as long as it maps to the backend capabilities.

The backend is done and battle-tested: a Python library (`c4proj`) that reads/edits/writes real
`.c4p` project files, exposed through one clean `Project` facade with JSON-serializable reads and
validated writes. The UI's job is to make that capability feel effortless.

## Architecture

- **You build the web frontend.** It talks to a thin **API server** (a mechanical JSON wrapper around
  the `Project` facade — generated separately, not your concern) over HTTP. Design as if each backend
  call returns the JSON in `sample_data.json`.
- One open project = one editing session with dirty-tracking and an explicit **Save** (produces a
  `.c4p` the dealer loads onto the controller).

## The spine: selection → surface

The backend exposes `surface_of(itemId)` → **everything editable about a selection** in one object
(config properties with types/values/validation, programmable commands/events/conditions, connection
points, current bindings, network address, agent-config availability). The natural, high-leverage
layout is **master–detail**:

- **Left: the project tree** (`tree_view`) — rooms, devices, agents. Persistent, always visible,
  fast to navigate/search.
- **Right: the contextual detail panel** — renders `surface_of(selected)`. Its content adapts to the
  selection's `kind` (a Room ≠ a Device ≠ an Agent).

Composer scatters a single device's settings across disjoint tabs; **keep the selected item's context
constant as the user moves between functional areas** — that continuity is a big part of "smooth."

## The five functional areas (surface as modes, not silos)

Offer the five areas — **System Design, Connections, Media, Agents, Programming** — but treat them as
lenses over a shared selection rather than separate apps. See `API_REFERENCE.md §5` for exactly what
data/methods each uses. Priorities for a workable beta: **System Design** (tree + add-device),
**Programming** (rules), and **Connections** — those are where dealers spend their time.

## Interaction principles for "smooth" (specific, opinionated)

1. **Add-a-device is a single search box.** `search_drivers("Sony TV")` → pick a result →
   `add_device_from_catalog(hit, name, room)` in one action. Composer's add-device is a multi-step
   slog; making this instant is a signature win.
2. **Progressive disclosure of config.** Show the driver's declared **properties** first (typed:
   `LIST`→dropdown, `RANGED_INTEGER`→slider, `STRING`→field, `LABEL`→section header, `readonly`→
   display-only). Put raw proxy **state fields** behind an "Advanced" expander. Never dump everything
   flat.
3. **Validate live, fail gracefully.** Writes validate server-side and throw a `ProjectError` with a
   human message (e.g. "invalid value for 'Poll Interval'"). Prefer constraining the input (dropdowns,
   clamped sliders) so errors are rare, and surface the message inline when they happen.
4. **Programming as a structured rule builder.** A rule = a **trigger** (pick a device + one of its
   events) → an **ordered action list**. Actions come from a fixed vocabulary: Command, Agent Command,
   Set Variable, Delay, If/Else, While, Break, Stop. Each device's `surface` supplies the concrete
   choices (its commands/conditions). Support nesting (If/While contain sub-actions). Render existing
   rules from `rules_view()` (each has a stable `handle` for edit/delete). This is the highest-value
   screen to get right — Composer's programming view is universally disliked.
5. **Connections should show compatibility, not raw ids.** For a selected device, show its connection
   points (`surface.connections`) and current wires (`surface.bindings_out`); when wiring, offer only
   compatible targets (matching binding classes). Show IP devices' addresses (`surface.network`).
6. **Non-destructive & reversible-feeling.** Reflect `dirty` state clearly; make Save deliberate;
   consider an activity/undo affordance. Nothing hits the real home until the dealer loads the saved
   file.
7. **Empty and loading states matter** — a `Project.new()` project has one root item; the UI should
   guide the dealer through "add your first controller → room → devices."

## Data shapes you'll bind to (see sample_data.json for real payloads)

- **Tree:** `{id, name, kind, driver, children[]}`.
- **Surface:** `{item_id, name, kind, driver, properties[], commands[], events[], conditions[],
  connections[], bindings_out[], network[], agent_config_kind}`.
- **Property:** `{name, type, value, default, options[], minimum, maximum, readonly}`.
- **Rule:** `{handle, trigger_device, trigger_event, actions[]}` where an action is `{id, device,
  type, display, command, children[]}`.
- **Variable / Binding / NetworkBinding / DriverHit** — see `sample_data.json`.

## What NOT to worry about

- The `.c4p` file format, XML, integrity/manifest — all handled by the backend.
- The API server — generated separately.
- Media library content — runtime data, not authored here.

## Deliverable for a first beta

A working editor that can: open or create a project; browse/search the tree; add a device from the
catalog; configure a selected item's properties (validated); wire a connection; author/edit a
programming rule; and save. Prioritize the master-detail spine and the three core areas (System
Design, Programming, Connections) — polished and smooth — over breadth.
