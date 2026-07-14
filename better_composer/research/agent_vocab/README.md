# Agent vocab extraction (2026-07-13)

Structured output of the Ghidra-disassembly vocab extraction for Control4's compiled
`control4_agent_*.c4w` binaries (no source `.c4i` exists for these — see CLAUDE.md's
"AGENT VOCAB GAP" section for why). Each `<agent>.json` is one agent's extracted
commands/conditionals/config schema. `_base_agent_api.json` is the vocab shared by every agent.

## Method

1. Install Ghidra 12.1.2 (`github.com/NationalSecurityAgency/ghidra` releases) + OpenJDK 21.
   Scripts must go in `%USERPROFILE%\ghidra_scripts\` (Ghidra's OSGi script loader silently
   fails to resolve scripts placed via an arbitrary `-scriptPath`).
2. Import the `.c4w` (it's a plain PE DLL despite the extension) into a Ghidra project, run
   auto-analysis.
3. Run `ExtractVocab.java` (headless `-postScript`): decompiles every function, extracts every
   string token matching Control4's `ALL_CAPS_WITH_UNDERSCORES` naming convention (both Ghidra's
   `PTR_s_<NAME>_<addr>` labeled-pointer form AND inline `"LITERAL"` string form — Ghidra picks
   one or the other per reference depending on how the compiler emitted it, so both must be
   checked), filtered against a small stoplist of OpenSSL/XML/crypto noise that happens to match
   the shape.
4. Two architecture families exist (see CLAUDE.md for full detail): "legacy" agents
   (Scheduler, ...) hand-roll their own `ExecuteCommand`/`TestCondition` with sequential string
   comparisons — extraction is clean and complete. "Modern" agents (the majority) register
   commands into a shared `CmdDispatcher` map at construction time instead; their vocab is
   scattered across many small registration call sites rather than one big function, so
   extraction is partial (catches base-class + shared vocab reliably, agent-specific commands
   inconsistently — some may use numeric IDs or a different mechanism like network bindings
   instead of string-named commands at all).
5. `TraceCreation.java` / `TraceCallees.java` (also in `ghidra_scripts`) are the tools used to
   find the universal `GetAgentName`/`GetCreationFunc` PE exports (every agent's factory
   interface) and recursively decompile the constructor chain — this is how the base-class API
   (`_base_agent_api.json`) was found and validated by hand for one agent (Notification).

## Open lead, not yet pursued

Every agent exposes `GET_CAPABILITIES` and `GET_COMMAND_INFO` (see `_base_agent_api.json`). If
these can be invoked and their result captured — e.g. by authoring a programming rule that calls
`GET_COMMAND_INFO` and writes the result to a Variable, loading it via the existing proven `.c4p`
round-trip through Composer into a virtual director, triggering it, then reading the result back
out (captured variable value, or Director's own logs) — that could yield complete,
runtime-authoritative vocab for every agent **without** needing the live-Director access that was
separately investigated and paused (see CLAUDE.md). Worth testing next session.

## Status per agent (batch complete, 2026-07-13)

All 18 batched agents finished (plus 9 processed earlier = all 27 `control4_agent_*` covered).
Summary: **17 of 27 have real, non-noise vocab; 2 (Access, Light Properties) are confirmed null
results with this technique; the rest have modest signal not yet curated.**

- **Complete, high confidence:** `control4_agent_scheduler.json` (legacy-style, full command +
  conditional + config-schema extraction, zero manual tracing needed).
- **Clean, unambiguous, curated:** `control4_agent_announcements.json` (`SHOW_POPUP`/`HIDE_POPUP`/
  `PLAY_ANNOUNCEMENT`), `control4_agent_macros.json` (`ADD_MACRO`/`DELETE_MACRO`/`EXECUTE_MACRO`/
  `GET_MACROS`), `control4_agent_navigation.json` (`BUILD_HISTORY_URI`/`JUMP_TO_DEVICE`/`SEND_URI`),
  `control4_agent_uiconfiguration.json`, `control4_agent_services.json`,
  `control4_agent_hospitality_wmb.json`, `control4_agent_timer.json` (all real but sparse — likely
  incomplete extractions, not incomplete agents).
- **Rich, medium-high confidence (groupings by naming convention, not per-function verified):**
  `control4_agent_media_sessions.json` (54 real tokens — whole-house audio group/zone/volume
  management, the richest non-Scheduler result), `control4_agent_videointercom.json` (call-state
  machine vocab), `control4_agent_audioscenes.json` (scene/volume/room-linking).
- **Null result (honest — a limit of the technique, not a failure to look):**
  `control4_agent_access.json`, `control4_agent_light_properties.json` — base API only, nothing
  agent-specific surfaced. Would need the deeper `GetCreationFunc`/`TraceCallees.java` manual
  tracing (as done for Notification's `GET_LAST_ACTION`) to make further progress on these two.
- **Raw/uncurated but real signal present** (`*.raw_tokens.json` only, needs the same by-hand
  grouping the curated ones got): `control4_agent_backup`, `control4_agent_diagnostics`,
  `control4_agent_driverupdate`, `control4_agent_emailnotification`, `control4_agent_history`,
  `control4_agent_identity` — run `summarize_vocab.py`-style noise-subtraction (copy into repo if
  resuming, currently only in the session scratchpad) to see each one's real tokens quickly.
- **STOPLIST in `ghidra_scripts/ExtractVocab.java` grew during this batch** (media-type constants,
  OpenSSL/logging noise, TLS 1.3 handshake secret labels, `PROXY_NAME`/`DIR_ADD`/`DIR_LOAD`/
  `LIST_ADD` all confirmed generic across 3+ agents) — a fresh re-run of any already-processed
  agent would now come back cleaner than what's currently saved.
