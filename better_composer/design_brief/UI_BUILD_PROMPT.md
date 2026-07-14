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

## Architecture — a cross-platform DESKTOP app (not a browser web app)

- Target a **native desktop app** for Windows and macOS from one codebase, using **web UI technology**
  (React/HTML/CSS) inside a lightweight shell (**Tauri** preferred; Electron acceptable). This matches
  the dealer workflow (on-site laptop, offline, opening/saving local `.c4p` files with native file
  dialogs) and removes browser/hosting friction.
- The proven **Python `c4proj` backend ships bundled as a local sidecar process** (Tauri sidecar /
  Electron child process); the UI calls it over a local IPC/HTTP channel. Do NOT rewrite the backend —
  it's hard-won and validated; keep it as the engine. Design as if each backend call returns the JSON
  in `sample_data.json`.
- **Build desktop-first, but design mobile/tablet-FORWARD.** A real goal (phase 2) is an app that
  on-site programmers can actually use on **iPads/large tablets and phones** — Control4's current
  mobile tool ("Composer Express") is barely usable beyond trivial tasks, and a genuinely capable
  touch tool would be a major benefit. So while we ship desktop first, **do not make choices that
  paint us into a desktop-only corner**: use responsive/adaptive layouts, **touch-first-friendly**
  interactions (large targets, no hover-only affordances, drag that also works by touch, no
  right-click-only actions), and a component structure that reflows to tablet/phone. This *reinforces*
  the no-rigid-tree decision above — the focus+lenses / search / canvas model adapts to touch far
  better than a dense tree+detail desktop layout. (Engine note: the Python backend can't run
  on-device, so the eventual mobile client talks to a backend — but keeping the UI React + adaptive
  keeps that path cheap.)
- One open project = one editing session with dirty-tracking and an explicit **Save** (produces a
  `.c4p` the dealer loads onto the controller).

## Scope: Control4 OS 4+ only (a deliberate simplification)

Target **Director OS version 4 and newer**. We can **disregard OS 3 and earlier** entirely — no OS 3
project formats, agents, or director interaction. **Old DEVICES stay supported** (a legacy driver
still runs on an OS 4 director; the driver catalog covers old + new hardware, and the backend handles
old driver files) — we just don't support old OS *directors*. Note: unlike Composer Pro (which pins a
specific Director OS version because it connects live to that controller), our tool is **file-based** —
it edits the `.c4p`, and Composer does the final load to a matching director. So we don't need
Composer's "pick an OS version on open" gate; we read the project's director version from `identity()`,
preserve it, and align our driver/agent vocab to OS 4.x. This narrows scope meaningfully — build to
OS 4.x semantics and don't spend effort on backward-compat with OS 3.

## Interaction model — DO NOT build a persistent-tree master-detail layout

**Hard requirement / explicit anti-goal:** the classic Composer-style **left-hand project tree +
right-hand detail panel is exactly the layout we are replacing.** It's a primary reason this tool
exists. It forces hunting through a rigid hierarchy, wastes space, and — critically — makes it HARDER
to keep context as you move between tasks. Do not reproduce it. (A tree may exist as *one optional*
navigation affordance, never as the mandatory spine.)

What must be preserved is the **capability**, delivered through a better model. The backend primitive
`surface_of(itemId)` returns **everything editable about a selection** in one object (config
properties, programmable vocab, connections, network, agent-config) — a portable "context bundle."
Design a model where **the current object of focus travels with the user across functional areas**,
navigated by something better than a tree. Directions worth exploring (pick/combine; the visual
direction will be supplied separately):

- **Focus + lenses:** a persistent, lightweight "what am I working on" context (a room, a device, a
  rule) that stays constant while the user switches *lenses* (System Design / Connections / Media /
  Agents / Programming) over that same focus — you change the object, not the panel.
- **Search / command-palette first:** jump to any device/room/agent/rule instantly (modern-editor
  style), reducing reliance on hierarchical browsing.
- **Spatial / canvas:** rooms and devices laid out spatially (floor-plan or graph); selection and
  context are anchored to the object in space and follow you.
- **AI-assistant as navigation & authoring** (see below): describing intent to the built-in assistant
  is itself a way to find and change things, further reducing rigid navigation.

The goal: keeping a device's full context constant across sections must be EASIER than Composer, not
harder — that is the bar this layout decision is judged against.

## The five functional areas (lenses over a shared focus, not silos)

Offer the five areas — **System Design, Connections, Media, Agents, Programming** — as **lenses over
the current focus**, not separate screens the user context-switches between. See `API_REFERENCE.md §5`
for the data/methods each uses. Beta priorities: **System Design** (add/configure devices),
**Programming** (rules), **Connections**.

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
4. **Programming — THREE authoring modes over one engine.** A rule = a **trigger** (a device + one of
   its events) → an **ordered, nestable action list** from a fixed vocabulary (Command, Agent Command,
   Set Variable, Delay, If/Else, While, Break, Stop); each device's `surface` supplies the concrete
   choices. All three modes below **compile to the same backend** (`add_rule`/`replace_rule` with the
   builder-produced actions), and the user can move a rule between modes:
   - **(a) Visual drag-and-drop** — block/node based (Scratch / Node-RED feel): drag triggers,
     actions, conditionals; snap them into sequences and nested blocks. The approachable default.
   - **(b) Advanced expression building** — a power-user surface with the full grammar (compound
     And/Or conditions, nested If/While, variables, precise parameters). Parity with what Composer
     power users can express, but far cleaner. For dealers who want exact control.
   - **(c) AI-driven** — when a model is linked (see AI section), the dealer describes intent in
     natural language ("when the theater lights are off and it's after sunset, set the hallway to
     30%") and the model generates the rule (compiling to the same actions). A headline differentiator
     when enabled; the other two modes stand alone without it.
   Render existing rules from `rules_view()` (each has a stable `handle`). This is the highest-value
   area to get right — Composer's programming view is universally disliked.
5. **Connections should show compatibility, not raw ids.** For a selected device, show its connection
   points (`surface.connections`) and current wires (`surface.bindings_out`); when wiring, offer only
   compatible targets (matching binding classes). Show IP devices' addresses (`surface.network`).
6. **Non-destructive & reversible-feeling.** Reflect `dirty` state clearly; make Save deliberate;
   consider an activity/undo affordance. Nothing hits the real home until the dealer loads the saved
   file.
7. **Empty and loading states matter** — a `Project.new()` project has one root item; the UI should
   guide the dealer through "add your first controller → room → devices."

## AI — a linkable model integration (a first-class option, not a hard dependency)

The tool is designed to **link to an AI model** (Claude via the Anthropic API, or another provider —
keep it provider-agnostic and configurable). AI does NOT have to be baked in as a mandatory
dependency: the core editor is fully usable without a model connected. But when the user **links a
model**, a set of AI capabilities lights up across the app — not just for programming, but as a way to
**navigate, author, and explain** the whole project. Because the backend already exposes the entire
project as serializable data (`tree_view`, `surface_of`, `rules_view`, `variables`, driver vocab, …)
and as validated write operations, a linked model can be given **full project context** and **act on
it**:

- **Author programming** from natural language (mode (c) above) — the flagship use.
- **Answer/navigate:** "which devices are in the theater?", "take me to the hallway dimmer", "what's
  connected to the receiver?" — the assistant reads the project data and jumps/focuses.
- **Bulk & assistive edits:** "add a Roku to every bedroom", "rename all the keypads consistently",
  "set every dimmer's max level to 90%" — proposed as reviewable actions the user confirms.
- **Explain existing config:** summarize what a rule does, or what a device is wired to.

Design implications:
- **Model linking is a setting:** a "connect a model" config (provider + API key, stored locally,
  provider-agnostic). AI features are present but gracefully **dormant/hidden until a model is linked**
  — the editor never depends on it to function.
- When linked, an accessible **assistant surface** (a panel/overlay/command-bar — your call) becomes
  available; not intrusive when unused.
- The assistant proposes **structured, reviewable actions** that map to backend write calls; the user
  confirms before anything changes (respect the non-destructive / explicit-save principle).
- The same project-context data the UI renders is what a linked model consumes — one source of truth.

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
