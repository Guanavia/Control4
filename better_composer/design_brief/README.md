# Design brief — start here

Everything needed to design + build the UI for the Control4 project editor. The backend is done,
validated, and running behind an HTTP API; this folder is the handoff package for the design phase.

## For the Claude Design agent (read this first)

You have this whole repo. **Read `../../CLAUDE.md` for full project context** (why this exists, every
decision, the backend's capabilities and its validated confidence level) — it's written for a Claude
peer and will orient you fast. Then read this folder for the UI brief.

**Source of truth vs. orientation.** The files in this folder (`API_REFERENCE.md`, `sample_data.json`)
are hand-written SNAPSHOTS for fast orientation — helpful, but they can lag the code. The
AUTHORITATIVE API contract is the actual code, which you can read and run:
- **`../api_server/server.py`** — the real endpoints + request/response models (~33 routes).
- **`openapi.json`** — the machine-readable spec (also live at `/docs` when the server runs).
- **`../c4proj/project.py`** — the `Project` facade the server wraps (exact method semantics).

**Prefer running the API over trusting the docs.** Start it (`cd better_composer && uvicorn
api_server.server:app --port 8765`), hit `/docs`, and build against real responses. You can
regenerate `sample_data.json` yourself from live calls. If the API doesn't perfectly serve a UI need
(a batched call, an extra field), you can read `server.py` and add it, or flag it — those additions
are cheap and expected. Turn on debug logging (`POST /debug {"enabled": true}`) to trace every call
while you build.

## What's in here

| File | What it is | Who reads it |
|---|---|---|
| **`UI_BUILD_PROMPT.md`** | The base prompt: vision, architecture, interaction model, the three programming modes, linkable AI, mobile-forward, OS-4 scope. **The main thing to hand the design tool.** | design tool + you |
| **`API_REFERENCE.md`** | The backend contract + domain model: the `Project` facade, item kinds, the two config surfaces, the five functional areas, core flows, and the rules to respect. | design tool |
| **`sample_data.json`** | **Real** serialized payloads for every API shape (a device surface, an agent with vocab, an IP device, a rule, references, connection candidates, a catalog hit). Build against these — not mocks. | design tool |
| **`openapi.json`** | Machine-readable OpenAPI spec of all 33 endpoints (import into a tool, or generate a typed client). | design tool / codegen |
| `../api_server/README.md` | How to run the live API (`uvicorn api_server.server:app`), the endpoint list, action-JSON for rules, debug logging. | you / whoever runs it |

## Recommended process (best starting point)

1. **Absorb context.** Read `../../CLAUDE.md` (full project context, peer-written) and
   `UI_BUILD_PROMPT.md` (the UI vision + hard constraints). The one layout constraint that's
   non-negotiable: **no persistent tree + detail-pane layout** — that's the thing we're replacing.
2. **Dave provides visual direction, collaboratively.** Look-and-feel (color, typography, density,
   brand feel, specific screens) is deliberately open in the brief — work it out with Dave; propose
   directions and iterate. Everything else (architecture, interaction model, flows, data) is settled.
3. **Stand up the real backend and build against it.** Run `uvicorn api_server.server:app --port
   8765`, explore `/docs`, and design/build against live responses — not the sample snapshots.
   Generate a typed client from `openapi.json` if useful. This collapses the gap between mockup and
   working app: you're wired to the validated backend from the first screen.
4. **Start narrow, highest-value first.** Build the **focus + lenses shell** and the three core
   screens — **System Design / add-a-device**, **Programming**, **Connections** — polished, before
   breadth. The prompt explains why these.
5. **Extend the API when the UI needs it.** When a screen wants data shaped differently (a batched
   endpoint, an extra field), read `../api_server/server.py` and the `Project` facade
   (`../c4proj/project.py`) and add it — or flag it for the backend side. These are cheap and
   expected; the facade already exposes everything, it's just a matter of endpoint shape. Keep
   **debug logging** on (`POST /debug {"enabled": true}`) to trace calls.
6. **Mind the one open constraint.** The API is single-project-per-session and NOT thread-safe by
   design (see CLAUDE.md) — serialize write calls in the UI; don't fire parallel mutations.

## Backend status (context for design)

Done and validated to a high bar (multiple adversarial pressure passes). All five functional areas,
the full create/edit/delete surface, dependency-safe deletes, and a round-trippable programming API
work end-to-end, are JSON-serializable, and are reachable over the API. Known-deferred (additive,
build as the UI reaches them): Media depth, more agent-config recipes, remaining agent vocab. One
known open item by choice: the API server serializes one project per session and is not thread-safe,
so a UI should serialize its write calls (left open deliberately as a UI-behavior check; debug logs
help diagnose if it ever matters).
