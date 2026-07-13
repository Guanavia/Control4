# Control4 Drivers Repo

Monorepo for all Control4 DriverWorks drivers built by Dave Woychek (david@propertyrenewal.llc).

## Repo conventions

- **One subfolder per driver.** All of a driver's source, docs, and research notes live in its folder (e.g. `nv_shield_tv/`, `sonoff_snzb02p/`).
- A `.c4z` file is just a **zip of the driver folder's contents** (files at zip root, not nested in a folder). `build.bat` / `build.ps1` are Windows scripts currently hardcoded to `nv_shield_tv`.
- Standard driver folder layout:
  - `driver.lua` — driver logic
  - `driver.xml` — driver metadata/config (devicedata XML)
  - `www/documentation.rtf` — dealer-facing docs shown in Composer
  - `www/icons/device_sm.gif`, `www/icons/device_lg.gif`, `www/icons/device/*.png`

## Drivers

### nv_shield_tv
NVIDIA Shield TV IP driver. Pre-existing, working. Built artifacts `nv_shield_tv-dmw.c4z` (own build) and `nv_shield_tv-fordev.c4z` at repo root.

### sonoff_snzb02p — CLOSED, no custom driver (research-only folder)
Original goal: get a Sonoff SNZB-02P temperature/humidity/battery sensor into Control4 for
dashboards, programmable threshold notifications, and history over time.

**Outcome (decided 2026-07-07): not building this.** A stock SNZB-02P cannot pair to a
Control4 zigbee mesh at all — see `sonoff_snzb02p/RESEARCH.md` for the full technical
reasoning (Control4's proprietary 0xC25D identify/product-string binding mechanism, which
stock Zigbee 3.0 firmware never speaks; plus C4's Zigbee 3.0 mesh currently only admitting
Control4 Lux lighting). Zigbee2MQTT was also considered as a bridge and ruled impractical for
this use case (see RESEARCH.md's mesh-topology section) in favor of the option below.

**Going with instead: Shelly H&T Gen3 (WiFi, battery) + Chowmain's Shelly Suite driver**
(https://chowmain.software/drivers/control4-shelly-generic — Dave is an authorized Chowmain
dealer). Works because the Shelly is a plain WiFi/IP device; DriverWorks IP drivers face none
of the zigbee gatekeeping. Battery life is worse than zigbee (~18mo vs ~4yr) but acceptable for
this scale. No driver-development work needed for the sensor itself.

**Remaining possible follow-on work** (not started): threshold-notification programming in
Composer, and a history/dashboard layer for long-term trends, once Shelly hardware + Chowmain
license are in place.

### better_composer — OPEN, investigation (feasibility of a modern Composer Pro replacement)

**ARCHITECTURE CLARIFICATION (don't get this wrong):** Composer is ALWAYS a live client of *a*
Director — there is no Composer-only project representation that later gets "applied." Editing in
Composer == editing that Director live (real controller = live changes to the home; "Virtual
Director" = identical, just Director running on a VM instead of hardware). The only discrete "load"
event is **Restore** (pushing a `.c4p` backup into a Director), which is when Director ingests +
completes it (this is what regenerates skeletal state). Our tool lives entirely on the `.c4p`
(backup/restore) side; it never talks to Director. Flow: Director → (backup) `.c4p` → our tool edits
→ `.c4p` → (restore) Director. So "open in Composer" already means "live in Director, fully
instantiated" — no load-then-program step.

**NEXT-SESSION HANDOFF (workstation):** reopen on the Windows workstation (has VSCode+Claude Code +
Composer Pro installed) to grab Director-internal driver defs NOT in the online catalog (confirmed 0
hits) and NOT bundled in projects: `roomdevice.c4i`, all `control4_agent_*.c4i` (agent vocab), and
proxy drivers `tv.c4i`/`light_v2.c4i`/`keypad_proxy.c4i`/`media_player.c4i`/`avswitch.c4i`/`fan.c4i`/
`thermostatV2.c4i`/`controller.c4i`/`uidevice.c4i`. Look in Composer's built-in drivers folder
(likely `C:\Program Files (x86)\Control4\Composer[ Pro]\Drivers\` or `%USERPROFILE%\Documents\
Control4\Drivers\`). Copy the whole drivers folder into the repo → closes the agent/room vocab gap.

Goal: determine whether a modern, streamlined replacement UI for Composer Pro is buildable.
Composer is just a client of Director; the open question was whether Director exposes a
project-*authoring* API (add device, bindings, programming) beyond the control/state surface
pyControl4 wraps. Full detail: `better_composer/FINDINGS.md`.

Key findings so far (2026-07-11):
- **Two Director interfaces.** (1) Modern REST + WebSocket (`/v1`, bearer token) = control/state
  only — what pyControl4/HA use; **no authoring**. (2) Legacy `c4soap` on port **5021 (SSL)**,
  gated by a **mutual-TLS client cert** (`CN: Composer_<login>_<machine>`) = the **full authoring
  surface** Composer uses. Controller = `core5-000fff9fc470` @ 192.168.1.123.
- **Write path = "PIP" (Project Info Packet).** Each Composer commit logs as `PIP received from
  remote client` → `Project Info Updated: project version: N`. Capturing one decrypted PIP is the
  highest-value artifact.
- **Logs give the data model for free.** `programming_change.log` (CodeItems: CIT_COMMAND/
  CONDITION/OPERATOR/ELSE with `<devicecommand>`/`<deviceconditional>` payloads, tree via
  parent/before ids) and `project_change.log` (Binding Added/Deleted, Bound Consumer add/remove,
  device Add, Name Change, version bumps) are a detailed audit trail — enough to reconstruct what
  each op *means*, but they are OUTPUT, not the request wire format.
- **Gate to building the authoring half:** need either a *decrypted* capture of a Composer
  authoring request on 5021 (mutual-TLS MITM — viable since we own both ends: Composer runs in a
  VMware Fusion Windows VM NAT'd through this Mac), OR confirmation we can edit the on-disk project
  + trigger a Director reload. Reading is largely solved; writing is the unsolved blocker.

**Capture done (2026-07-11) — strategy pivoted to project.db:**
- Recon capture during a live Composer edit confirmed Composer↔Director is **mutual TLS on 5021
  (authoring), 5810, and 443**, all ECDHE (no passive decrypt). Server cert **chains to a real
  "Control4 Corporation CA"**, so a forged-cert mitmproxy is rejected — MITM would need the *real*
  keys extracted from endpoints (controller `.p12`/`certs`, Composer client cert). **Deprioritized.**
- **Key discovery:** the project is a **SQLite DB** — `/opt/control4/var/director/project.db`
  (~348 KB; devices, bindings, programming), plus `system.db`/`state.db`/`drivers.db`/`identity.db`.
  Director keeps them open rw; `project.db` mtime tracks each commit. The log data-model (CodeItems,
  bindings) is almost certainly these tables.
- **Revised plan:** read side is basically solved (read `project.db` directly). Write side is
  tractable via offline-edit + Director reload (validate reload/locking semantics; do NOT write the
  live DB blindly). Cracking the PIP/c4soap wire protocol is no longer the critical path.
- **FEASIBILITY CONFIRMED — BUILDABLE.** Analyzed the local Composer project
  `better_composer/research/Russell House.c4p` (a zip of: **`project.xml`** = the entire authorable
  project; `drivers/` = the 38 `.c4z` + 22 `.c4i` referenced drivers; `mm.db`/`identity.db`;
  `meta/`). Composer saves the project as XML; the controller runtime is the SQLite equivalent.
- `project.xml` (root `<currentstate>`) sections: `properties`, `systemitems` (nested device/room
  tree), `bindings` (`boundbinding`→`boundconsumers/bound` with `boundclass`), `networkbindings`,
  `variables`, `event_mgr` (41 `event`→`codeitem` = programming; `codeitem/cmdcond` holds
  `devicecommand`/`deviceconditional`), `plugins`. **Maps 1:1 to the audit-log vocabulary.**
- **Read side solved** (parse project.xml + driver metadata). **Write side tractable** (edit
  project.xml, repackage .c4p); only open question is the **apply/load mechanism** — prefer
  round-tripping a `.c4p` through Composer's load, else controller `project.db` replace + reload.
- **Integrity = plain MD5, not a signature.** `meta/manifest.json` records md5+size per file
  (verified: project.xml md5 matches raw bytes). So edit project.xml → recompute md5/size → rezip.
  Restore writes `project.xml`→`.../project.xml.imported` and Director imports it into project.db.
- **SCAFFOLD BUILT & VERIFIED — `better_composer/c4proj/`** (Python, stdlib only). Reads a .c4p,
  verifies integrity, parses project.xml into a navigable model (devices tree, bindings,
  programming, variables), edits it, and repackages a valid self-consistent .c4p (manifest md5
  auto-refreshed). CLI: `python3 -m c4proj {info,tree,bindings,program,roundtrip,identify,rename}`.
  Every editing command shows a **version-confirmation card** (project/version/director/backup-date/
  counts) and asks "is this the current/desired project version?" before writing (`--yes` bypasses)
  — added after a stale 2025 (director 4.0.0) backup was nearly edited instead of the live 4.1.0.
- Verified on the **current** project: director **4.1.0.743847**, project **version 133**, **417
  devices**, 330 bindings, 98 programming events; parses a 125 MB archive in ~0.3s. Parser is
  version-tolerant (also handled the older 4.0.0 file).
- **APPLY PATH VALIDATED (Stage 1 done):** Composer opened a c4proj-generated `.c4p` against a
  **virtual director** — it parses AND imports. So the round-trip works end-to-end. The virtual
  director is our safe test loop. **Testing progression: virtual director → spare Core Lite
  controller → live home.** (Never test on production until proven on real spare hardware.)
- Current test artifact: `better_composer/test projects/Russell House v133 [c4proj-test].c4p`.
  **Convention: all generated/test .c4p files go in `better_composer/test projects/`** (gitignored;
  keep only current-version artifacts). MITM of the live protocol is **not** the path.
- **DRIVER-METADATA READER BUILT — `c4proj/drivers.py`.** A device driver declares
  `<proxy>NAME</proxy>`; the proxy driver (`light_v2.c4i` etc., bundled in `drivers/`) declares the
  real `<commands>`/`<conditions>`/`<events>`. `DriverLibrary.resolve(c4i)` walks device→proxy and
  returns the effective API; command params are inferred from UPPERCASE placeholders in the
  description. CLI: `c4proj drivers <c4p>`, `c4proj device <c4p> <id>`. NOTE: a device's driver is
  the `<c4i>` child of `<item>` (sibling of `<itemdata>`), not under itemdata (model.py fixed).
- Coverage (current project, 417 devices): **186 programmable devices resolve** (commands+events);
  171 empty (rooms/containers/agents w/o proxy); 51 driver files not bundled = **built-in agents
  (`control4_agent_*.c4i`) + `roomdevice.c4i` (×28)**, which live in Director/Composer, not the
  archive. **Gap:** programming against agents/rooms needs their command defs from Director or the
  online driver DB.
- **Online driver DB (Solr): https://drivers.control4.com/solr/drivers/browse** — live faceted
  catalog, **24,523 drivers** (facets: manufacturer, device type, control method IP/IR/Serial/
  Relay/ZigBee/Z-Wave, certification), each record has a **download link** to its `.c4z`/`.c4i`.
  `/browse` (Velocity HTML) works; `/select?q=` returns 404 (locked down — revisit query params
  when building "add device"). This is the source to fetch any driver file + metadata on demand →
  unlocks *adding devices* later. Note: the catalog's "AV" skew is a **legacy categorization
  artifact** (dealer-created drivers get tagged AV regardless of function — C4's AV/lighting
  origins), NOT a real content limit. Still, the built-in **agents/rooms** are Director-internal
  and not third-party drivers, so source those from a Composer/Director install, not this catalog.
- **`c4proj rules <c4p>`** renders existing `event_mgr` programming as human-readable "WHEN X: ->
  do Y" by resolving eventids against driver metadata — the read-side of the programming interface,
  the full stack working together. (Events on rooms/agents show "event NNNN" = the agent/room gap.)
- **BACKEND SCOPE CHECK (2026-07-12): NOT complete for "build a whole project from scratch =
  virtual-director parity."** What exists is a read + envelope + one edit-primitive + driver-
  capability layer (~a foundation). Verified gaps toward full parity:
  - Device **instance properties** live in the item's `<state>` escaped-XML blob (readable, not yet
    modeled/editable). Driver files have **no static `<properties>` schema** (light_v2=proxy only;
    core5=config) — property defs are often **dynamic/Lua**, so per-driver property schema+defaults
    is an unsolved discovery problem.
  - **No "add a device" engine**: id allocation (`iditemcurrent`), default `<state>` instantiation,
    connections, manifest+driver-file placement — none built. This is the linchpin for devices,
    controllers, sub-controllers.
  - **No blank/new-project seed** (baseline ~30 built-in agents + root item + identity.db defaults).
  - **Agents' config models unmapped**: agent item `<state>` is often empty (scheduler=0), so
    schedule/scene/announcement config lives elsewhere per-agent; each is its own sub-model.
  - **Controller + identity/network provisioning**: controller item carries a 13KB `<state>` +
    identity.db + certs (set aside). Hardest tier; provisioning NEW hardware likely DOES require
    Director/Control4 cloud (identity/certs/licensing) → may not be fully offline-synthesizable.
  - **51 Director-internal drivers** (agents, `roomdevice.c4i`, some proxies) not in archive — must
    be sourced from a Composer/Director install or controller `/opt/control4/...`.
  - **Write/authoring engine** (incl. programming rule→XML compiler) and **online-driver
    download/install** not built.
  - **REVISED SCOPE (2026-07-12, user's call). Composer bookends via the FILE, our tool is the
    editor:** Composer downloads current project from controller → `.c4p`; our tool imports → edits
    → exports `.c4p`; **Composer loads the `.c4p` back to the controller (APPLY is Composer, not our
    tool)**. Our tool NEVER interfaces Director. It owns all authoring: project info, rooms/
    locations, add devices/drivers, properties, connections/bindings, programming, agents.
  - **Controller nuance (user, likely correct):** virtual director opens a *blank* project; you then
    add a *controller driver* (an item) — hardware *registration* is deferred to load/identify time
    (Composer's job). So adding a controller driver is plausibly just project.xml data our tool
    could do too. OPEN EMPIRICAL Q: does Composer's "add controller" touch only project.xml, or also
    seed identity.db/certs at add-time? The blank→add-controller diff answers it. If project.xml-
    only → our tool can add controllers like any device; if it seeds identity.db → replicate or
    leave that step to Composer.
  - **Method to complete the backend:** use Composer + virtual director as an **oracle** — perform
    each operation (add room, add device, set property, add schedule…), save, and diff
    project.xml/manifest vs the prior save to reverse-engineer each operation's data transform.
    Baseline capture is now a *Composer-created blank project (with controller)* = our import start.
  - **Capture baseline note:** virtual director has no "New Project" — use **Clear Project** (yields
    a project named "new project"). This is fine because diffs are *differential* (residue is on both
    sides and cancels). Caveat: Clear may retain the old `drivers/` cache + stale identity/media, so
    (a) don't treat `01-blank` as a pristine seed template, and (b) adding a device whose driver was
    already cached won't show driver-file placement — use a novel/uncommon driver to capture that.
    Rule: captures must be a consecutive series on the SAME cleared project, one op at a time.
  - **DIFF INSTRUMENT BUILT: `c4proj diff <a.c4p> <b.c4p>`** (`c4proj/diff.py`) — reports manifest
    file changes (flags `identity.db` specifically → answers the controller-identity question),
    items added (with full XML = instantiation template) / removed / changed, and binding/variable/
    programming deltas. Self-tested. This is the oracle instrument for the capture campaign.
- **CAPTURE CAMPAIGN #1 DECODED (2026-07-12, 20 captures `research/captures/`):** built a project
  in virtual director one op at a time; `c4proj diff` down the series. Major decodings:
  - **Save format:** virtual-director "Save As" = LEAN zip: `project.xml` + `mm.db` + `drivers/`,
    **NO `meta/manifest.json`, NO `identity.db`** (metadata in zip comment). So this format has no
    MD5 integrity and no identity payload. (c4p.py now handles manifest-optional.)
  - **CONTROLLER QUESTION ANSWERED:** adding a Core Lite writes only project.xml + driver files;
    **identity.db is never present/touched** → identity/registration is deferred to hardware load
    (Composer). **Our tool CAN add controllers.**
  - **Item `type` codes:** 1=Project, 2=Site/Home, 3=Building/House, 4=Floor, 6=physical device
    (or controller/agent-parent), 7=proxy sub-device, 8=Room, 9=Agent.
  - **Add-controller is COMPOUND:** seeds the location tree (Home>House>Floor>Room), the controller
    (type6 `control4_corelite.c4i` w/ big state) + `controller.c4i` + `uidevice.c4i` subs, and media
    services (AddMusic/Stations/Channels + `control4_digitalaudio.c4i` at id 100002). +10 bindings.
  - **Add-device pattern:** one parent (type6, the driver c4z/c4i, default `<state>` from driver) +
    proxy sub-devices (type7) — a keypad-dimmer = parent `combo_dimmer.c4i` + `light_v2.c4i` +
    `keypad_proxy.c4i`. Each proxy sub adds a binding.
  - **Device/keypad CONFIG lives in the item's `<state>` blob** (steps 07–12: button add/rename/
    engraving/behavior all = edits to the keypad item's `<state>` BUTTON_LIST_INFO/BUTTON_BEHAVIORS/
    LED_BEHAVIORS). Property model = the escaped-XML `<state>`.
  - **AGENTS are type9 items; their config lives in the agent item's `<state>`** — Advanced Lighting
    starts `<State><all_scenes/><all_off_toggle_scenes/></State>`; creating a scene / adding loads /
    toggle all edit that state (+ the member load items).
  - **"Connections screen" = bindings** (step 19: connect keypad button→scene = +1 provider binding
    + keypad state change).
  - **ID allocation:** user devices get sequential low ints (2,3,…); system services high (100002);
    tracked by `properties/iditemcurrent`.
  - **STATE-DELTA DECODES (diff `--detail`, exact write recipes):**
    - *Create lighting scene* = add `<AdvScene>` under agent(22) state `all_scenes` with fields
      (name, scene_id, toggle_id/off_toggle_id=65535, colors, hold rates, all_members empty).
    - *Add load to scene* = add `AdvScene/all_members/AdvSceneMember[n]` with `device_id` (the light
      proxy id, e.g. 16/20) + level/color element (level=100, levelEnabled=True, levelRate=750…).
    - *Keypad button behavior* = edit keypad(17) state `BUTTON_LIST_INFO/KEYPAD_BUTTON_INFO[n]/
      BUTTON_BEHAVIOR` (0=Load On, 1=Load Off, 3=Keypad) + `BINDING` flag + `LED_BEHAVIOR`.
    - *Connect button→scene (Connections screen)* = add provider binding **agent#22/3 (scene) →
      consumer keypad#17/312 (button) [BUTTON_LINK]** + minor keypad LED_BEHAVIOR/LOCK_COLORS edit.
  - `c4proj diff <a> <b> --detail` now shows `<state>` field deltas + added/removed bindings.
- **WRITE ENGINE STARTED — `c4proj/authoring.py` `clone_device()`.** Adds a device by cloning an
  in-project template: deep-copies the parent+proxy-sub subtree, allocates fresh IDs (bumps
  `properties/iditemcurrent`), remaps `<state>`/bindings, inserts under the room's `<subitems>`,
  clones bindings remapped. Proven: from capture 05 (controller + Server Room + 1 dimmer), added a
  2nd dimmer (ids 18/19/20) with correct LIGHT_V2 + KEYPAD bindings.
- **ASSEMBLY LOAD TEST — TEST A PASSED (2026-07-12).** `test-A-full-clone.c4p` (2nd dimmer cloned
  from a template, full state) **loaded in virtual director; the added dimmer is present.** Diffs:
  (a) base capture 05 → test-A = ONLY the 3 dimmer items + 2 bindings added, nothing else touched
  (tool is faithful); (b) test-A → Composer's post-import save = only item(1) project-root bumped,
  our device kept intact (Director accepts a tool-ASSEMBLED project wholesale). So: **our tool can
  add a device instance and Director loads it.** `test-C-on-full-project.c4p` = same add on the full
  capture-19 project, whole project preserved (for user reassurance).
  - NOTE: test-A/B were built on capture **05** (early, 18 devices) not final 19 (23) — so they
    lack the later laundry/agent/scene; not data loss, just the chosen base. Always state the base.
  - **TEST B PASSED — DECISIVE (2026-07-12): Director REGENERATES device state on load.** The
    skeletal clone (empty `<state>`) loaded fine; diff of our input vs Director's post-import save
    shows items 18/19/20 came back with the FULL default state (PRESET_LEVEL=100, BACKLIGHT/STATUS
    LED settings, button layout, click rates…) — identical to a normally-added device. **⇒ NO
    per-driver template library needed.** Our tool can add a device as a skeletal item (driver ref +
    id + name + proxy-sub skeletons + bindings + room placement, empty state) and Director fills in
    all driver-specific defaults on load. **Tier-3 resolved: from-scratch project creation is not
    blocked.** User's intuition was correct.
  - **"Add ANY device (incl. not-yet-in-project driver)" path now clear:** (1) fetch driver `.c4z`/
    `.c4i` from the online DB → place in `drivers/`; (2) read its metadata (proxies/connections) to
    build skeletal parent(type6)+proxy-sub(type7) items; (3) wire internal proxy bindings from the
    driver's connection defs; (4) place in room; (5) Director completes state + validates on load.
    Open micro-Q (non-blocking): can the skeleton omit the proxy subs (does Director create them)?
  - Clone binding logic fixed: clones only the device's OWN provider bindings, not inbound external
    connections.
- **REPOSITORY ENGINE BUILT — `c4proj/repo.py`.** Control4 driver DB is a public Solr:
  `https://drivers.control4.com/solr/drivers/browse?q=<solr>&wt=json&fl=...` returns driver docs
  (fields: name, manufacturer, model, `proxy` [list], control, **`filename`**, `md5sum`, combo).
  Download direct from `https://drivers.control4.com/<filename>`. `repo.search()` + `repo.download()`
  (md5-verified). Parent driver's `<proxies proxybindingid=.. name=..>PROXYNAME</proxies>` declares
  its proxy sub-items (combo_dimmer→light_v2+keypad_proxy; core5→controller+uidevice; tv→tv).
- **ADD-DEVICE ENGINE (parent-only) — `c4proj/authoring.py`:** `add_device()` injects a PARENT-ONLY
  skeletal item (driver ref + id + name, empty state, no subs, no bindings) in a room — relies on
  Director to complete proxy subs/bindings/state on load (per the proven state-regeneration). Also
  `add_room()` (clones a room template under a floor) and `change_driver()` (repoint+strip state,
  used to swap controller type).
- **PRESSURE TEST — `test projects/pressure-test-theater.c4p` (pending user load).** Built from
  capture 03 base (Composer-made location scaffold + controller): swapped Core Lite→**Core5**,
  renamed Room→**Server Room**, added **Theater** room, added **dimmer keypad** (parent-only) to
  Server Room, downloaded a **Sony KDL-50WF660 TV** from the repo and added it (parent-only) to
  Theater. Bundled proxy drivers light_v2/keypad_proxy for the dimmer; **`tv.c4i` proxy NOT bundled**
  (potential TV break). Open Qs the load answers: (1) does Director complete a parent-only device
  (subs/bindings/state)? (2) controller-type swap OK? (3) tool-created rooms OK? (4) repo TV OK
  despite missing tv proxy? NOTE: `roomdevice.c4i` is referenced but never bundled (Director-
  internal) — proxy drivers may likewise be Director-internal. Started from cap-03 base, NOT absolute
  blank (synthesizing controller's compound location/media seeding from nothing still unproven).
- **PRESSURE TEST v2 — PASSED (2026-07-12): `test projects/theater-from-blank.c4p` loaded in VD
  exactly as expected (clean Core5, no Core-Lite artifacts, rooms/dimmer/TV correct). Built FROM
  BLANK capture 01.**
  Redo after user feedback (v1 wrongly started from cap-03 and left a "CORE LITE" name remnant from
  swapping instead of building). This one starts from the genuine blank project and **reproduces the
  "add controller" compound** — location scaffold Home>House>Main>Room + controller trio + media
  services (Manage Music/Stations/Channels/Digital Media) — with a real **Core5** and correct names
  throughout (0 "corelite"/"core lite" remnants incl. nav icons). Then Room→Server Room, add Theater,
  add dimmer (parent-only) to Server Room, download+add Sony TV (parent-only) to Theater.
  - v1 (`pressure-test-theater.c4p`) LOADED OK in VD: rooms/dimmer/TV correct; only issue was the
    Core-Lite-swap remnant (now fixed in v2). So: tool-assembled controller project loads; repo
    download + add-device engine work.
  - HONEST CAVEAT: the add-controller compound's structure is reproduced from our characterization
    template (the cap01→cap03 diff), Core5 substituted — i.e. replaying a decoded operation, not yet
    a fully code-generated `add_controller()`. Generalizing that into code is a later step.
- **DEVICE PROGRAMMING VOCAB IS METADATA-DERIVED (no capture needed for the per-device explosion).**
  `drivers.py` extracts per device: **events (triggers), commands (actions), conditionals** — all
  `id/name/description(+placeholder params)`. Russell House totals: **1507 events, 2891 commands,
  1149 conditionals** across 186 devices. FIXED bug: conditions live in `<conditionals>/<conditional>`
  (parser wrongly used `<conditions>`; now correct). GAP: **agents (type9, 12 in RH) + rooms**
  vocab is Director-internal (not in bundled drivers) — source from a Composer/Director install or
  capture programming against them.
- **Composer programming MODEL (from guide + logs):** event-driven. Pick a device event (trigger) →
  build a Script = ordered codeitems. Primitives: **Command, Conditional(if), Loop(While), Delay,
  Stop, Break, And, Or, Else**, + variables (bool/number/string, room, custom-agent). Codeitem XML:
  `event(deviceid,eventid)→codeitem(type=CIT_*, device, cmdcond=devicecommand|deviceconditional,
  subitems=nesting)`. Two UI paradigms in Composer: drag-drop (Programming view) + Connections tab
  (bindings — already decoded).
- **WHAT PROGRAMMING CAPTURES MUST PIN DOWN (finite — the primitives, NOT device combos):** exact
  codeitem XML for each of Command(static param), command w/ variable-ref & device-ref params,
  Conditional(operator+value), If/Else, And/Or, Delay, Stop, Break, While, and a variable set +
  compare. Then: (device vocab from metadata) + (primitive encodings from captures) + (value
  encodings) = the rule→codeitem **compiler**, which drives all 3 modes (manual drag-drop UI,
  connections, AI agent).
- **PROGRAMMING GRAMMAR FULLY DECODED (prog01–14) → `better_composer/PROGRAMMING.md` (compiler spec).
  COMPLETE — nothing more to capture.** Event-anchored: every script hangs off
  `<event>(deviceid,eventid)` → root container codeitem → `<subitems>` script. Codeitem `<type>`:
  1=command (incl. DELAY/BREAK/STOP on dev 100000), 2=if, 3=while, 4=else, 6=operator(AND/OR).
  And/Or = an `<expression>` block inside the If holding operator node(type6, AND|OR in display) +
  next condition. While(type3)=deviceconditional + body in subitems. Break=`command BREAK`,
  Stop=`command RETURN` (both type1 on dev 100000). `owneridtype`: ""=device (owneriditem=-1),
  "variable"=var op (owneriditem=variableid, name "="/"=="), "agent"=agent cmd. Device-cmd params
  `<value type><static>`; var-op params inline `<param name="value" type="int">`. Pseudo-devices
  100000=programming, 100001=Variables agent. DELAY time in ms. Nesting = parent's `<subitems>`.
- **DESIGN DECISION — open-ended logic:** Director is fundamentally event-anchored (no event-free
  if/while — confirmed by captures). USER WANTS declarative logic like "while var-test is true, keep
  light at 75%". SOLUTION (doesn't change Director): the compiler SYNTHESIZES event hooks — a
  declarative rule compiles to event handlers on the variable's change event + relevant device-state
  events (or a timer). Reactive/edge-triggered, not a literal loop, but equivalent for most cases.
  This declarative→event-hooks compilation is THE core value-add of our interface over Composer.

## Reference resources (better_composer)

- **Composer Pro User Guide** (v3.3, 590 pp): `better_composer/research/composer-pro-user-guide-rev-aa.pdf`
  — publicly available from Control4/SnapOne. THE reference for every authoring operation we must
  characterize. Use `pdftotext -f N -l M <pdf> -` (poppler installed) for targeted section reads.
  Key sections: Adding a controller / Register controller from Composer; How to add devices /
  Adding drivers manually / My Drivers tab; Configuring device properties; Connections view
  (Control/AV + Network); Agents view; Programming view; Loading a project's configuration to a
  controller (the apply flow).
- Online driver DB (Solr): https://drivers.control4.com/solr/drivers/browse (see above).

## Reference docs (Control4 DriverWorks)

- DriverWorks repo: https://github.com/snap-one/docs-driverworks
- API reference: https://snap-one.github.io/docs-driverworks-api
- Driver XML reference: https://snap-one.github.io/docs-driverworks-xml
- Fundamentals: https://snap-one.github.io/docs-driverworks-fundamentals/
- Zigbee implementation guide: https://snap-one.github.io/docs-zigbee
- Proxy protocol docs (per-proxy): linked from the DriverWorks README
