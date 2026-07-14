# Design brief — start here

Everything needed to design + build the UI for the Control4 project editor. The backend is done,
validated, and running behind an HTTP API; this folder is the handoff package for the design phase.

## What's in here

| File | What it is | Who reads it |
|---|---|---|
| **`UI_BUILD_PROMPT.md`** | The base prompt: vision, architecture, interaction model, the three programming modes, linkable AI, mobile-forward, OS-4 scope. **The main thing to hand the design tool.** | design tool + you |
| **`API_REFERENCE.md`** | The backend contract + domain model: the `Project` facade, item kinds, the two config surfaces, the five functional areas, core flows, and the rules to respect. | design tool |
| **`sample_data.json`** | **Real** serialized payloads for every API shape (a device surface, an agent with vocab, an IP device, a rule, references, connection candidates, a catalog hit). Build against these — not mocks. | design tool |
| **`openapi.json`** | Machine-readable OpenAPI spec of all 33 endpoints (import into a tool, or generate a typed client). | design tool / codegen |
| `../api_server/README.md` | How to run the live API (`uvicorn api_server.server:app`), the endpoint list, action-JSON for rules, debug logging. | you / whoever runs it |

## Recommended process (best starting point)

1. **You add the visual direction.** The brief deliberately leaves look-and-feel open — color,
   typography, density, brand feel, any specific screens you envision. Layer that on top of
   `UI_BUILD_PROMPT.md`. (One hard constraint the prompt already sets: **no persistent tree +
   detail-pane layout** — that's the thing we're replacing.)
2. **Give the design tool the prompt + the two references.** Lead with `UI_BUILD_PROMPT.md`; attach
   `API_REFERENCE.md` and `sample_data.json` so it designs against real shapes. If the tool can read
   this repo/folder or GitHub, point it here; if it's web-only, paste them in.
3. **Run the live API** (`cd better_composer && uvicorn api_server.server:app --port 8765`, see
   `../api_server/README.md`). If the tool can consume a live API / OpenAPI, this lets it generate a
   frontend already wired to real data and try endpoints at `/docs`. Otherwise, `openapi.json` is the
   static contract.
4. **Start narrow, highest-value first.** Have it design the **focus + lenses shell** and the three
   core screens — **System Design / add-a-device**, **Programming**, **Connections** — polished,
   before breadth. The prompt explains why these.
5. **Iterate against reality.** As the UI reveals needs the API doesn't perfectly serve (a batched
   call, an extra field), those are expected and easy to add on the backend. Turn on **debug logging**
   (`POST /debug {"enabled": true}`) while developing to trace exactly what the backend receives.

## Backend status (context for design)

Done and validated to a high bar (multiple adversarial pressure passes). All five functional areas,
the full create/edit/delete surface, dependency-safe deletes, and a round-trippable programming API
work end-to-end, are JSON-serializable, and are reachable over the API. Known-deferred (additive,
build as the UI reaches them): Media depth, more agent-config recipes, remaining agent vocab. One
known open item by choice: the API server serializes one project per session and is not thread-safe,
so a UI should serialize its write calls (left open deliberately as a UI-behavior check; debug logs
help diagnose if it ever matters).
