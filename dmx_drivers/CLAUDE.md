# dmx_drivers — Art-Net DMX driver set for Control4

**Status: OPEN, v0.1.0 — BUILT AND OFFLINE-TESTED (2026-09-24). Nothing has run on a controller
or touched a fixture yet.** Next step is the bench session below, when the hardware is on site.

Spec: `dmx-artnet-driver-set-brief.md` (Dave's brief, v2). This file records status and every
decision; where it and the brief disagree, **this file wins** (several brief items were changed
by Dave's calls, listed below).

Three c4z's from one shared codebase:
- **`artnet_node`**: one universe on one node. Merges fixtures, runs every fade, sends ArtDmx
  unicast on UDP 6454, 1 Hz keepalive, frame-rate cap, ping health check, patch display.
- **`dmx_light`**: any non-moving fixture as ONE light_v2 load; non-light channels on Extras.
- **`dmx_mover`**: a moving head as ONE light_v2 load; position, beam, effects and presets on
  Extras; presets linkable to lighting scenes.

Hardware: Pknight CR011R, ColorKey MiniWash Quad 4 MKII, DazzlingStage 4x8W RGBW pars. Separate
universe from Control4's own Vibrant DMX.

## Layout and tooling

```
common/      util, artnet (packet), layouts (roles/types/built-ins/compiler), color (xy/CCT ->
             emitters), protocol (node<->fixture), extras (Extras XML), light (light_v2), fixture
             (the shared fixture engine)
artnet_node/ main.lua, universe.lua (slices, fades, overlap policy, frame), driver.xml, www/
dmx_light/   main.lua (thin), driver.xml, www/
dmx_mover/   main.lua, position.lua, presets.lua, driver.xml, www/
tools/       bundle.py, checks.py, scopecheck.py (from YAS209), make_icons.py
test/        unit.lua, scenarios.lua, c4sim.lua (offline Director), testlib.lua
build.sh     -> build/<name>/ (staged) and dist/<name>.c4z (both gitignored)
```
- `./build.sh` builds all three, then runs both test suites. **Needs `luajit`** (`brew install
  luajit`): Director runs drivers with `jit="1"` (confirmed in Control4's own DMX Light
  driver.xml), so tests run under LuaJIT for 5.1 semantics. `luac` 5.5 would accept 5.3+ syntax
  the controller rejects.
- **`bundle.py`** inlines `main.lua` + required modules into one driver.lua behind a LOCAL
  `require`, so the drivers never depend on Director's package system.
- **`checks.py`** fails the build if the Lua reads a property driver.xml does not declare, or if an
  Action's command is never handled. Both fail silently on a controller. Negative-controlled (a
  typo'd property and a renamed action command were both caught). Shared code that reads a
  mover-only property declares it with `-- @optional-properties:`.
- The 64 Custom channel properties are expanded from `<!-- @CUSTOM_CHANNELS@ -->` at build time.
- Versioning per repo rule: `VERSION` = product (0.x until release), integer `<version>`
  auto-bumped per driver only when its package changes (rebuild is idempotent, verified), both
  stamped into `@BUILD@` and logged unsilenceably on load.
- c4z names are load-bearing (`GetDevicesByC4iName("artnet_node.c4z")`): never suffix them.

## Decisions (all Dave's calls unless noted)

1. **One fixture = one driver = one load.** The brief's second light_v2 "Positions" proxy and the
   `uibutton` web-view "Controls" proxy are DROPPED: each proxy shows as its own room item.
   The mover has exactly one proxy, light_v2.
2. **Mover controls on the light's Extras tab.** No web page, no hold-to-move d-pad. Position is
   **Pan/Tilt sliders** (absolute % of travel) plus nudge buttons (Fine/Medium/Coarse) and Home.
   Presets: slot list, Recall, Name, Save mode (Position only / Position + Color / Everything),
   Save, Link to Last Scene, Unlink.
3. **Positions in scenes (my design, Dave to judge on the bench):** the mover declares
   `advanced_scene_support=true` (FULL ALS), so ACTIVATE_SCENE carries the scene id. A preset
   linked to a scene id is recalled whenever that scene fires (position/beam/effects only: the
   scene owns intensity and color). `dmx_light` stays reduced ALS. Dave was unsure whether
   position needs to be in scenes at all: let the bench decide.
4. **Overlap policy:** light<->light shares channels (HTP, both told, mismatched layouts warned);
   anything touching a mover is REFUSED, the incumbent (earlier registration, kept across
   re-registers while the node runs) keeps running. After a node restart, registration order
   decides the incumbent again: in practice stable, noted in case it ever is not.
5. **Node IP must be static**, stated in the documentation and the property tooltip.
6. **Health check is ICMP ping** (`C4:CreatePingClient`, OS 3.3.1), not ArtPoll as first
   proposed: Art-Net nodes reply to ArtPoll on port 6454, which a Control4 UDP connection may
   not be listening on, so ArtPoll could have produced a false "offline". Ping cannot. If ping
   is unavailable the state stays "unknown": never reported as a failure without evidence.
7. **Snap One's light template is NOT used (my call, forced by its licence).** The template repo
   is licensed confidential, needs a Control4 licence to use, and assigns derivative works to
   Control4. This repo is PUBLIC. `common/light.lua` is our own light_v2 implementation, written
   from the public Light V2 protocol docs. Reading the template to learn protocol facts (param
   names, the PUSH_SCENE element XML) is fine; copying its code is not.
8. The brief's `Default Position` property and the Positions level mapping (1-32 = slot,
   33-100 = default) went with the Positions proxy. Home = centre of the soft limits.

## What the offline tests prove (282 checks: 125 unit + 157 scenario)

`test/c4sim.lua` runs the **built** drivers together (node + 2 pars + mover), one Lua environment
each, and reads the Art-Net bytes off the wire. Its C4 stub only has doc-verified APIs (anything
else raises), honours `bRepeat` (a one-shot fires once, no `Reset()`), queues SendToDevice with
string params, and does not fire OnPropertyChanged on UpdateProperty. Every section also fails
if any driver logged a thrown handler error.
Covered: both boot orders, color/CCT/white extraction/virtual-dimmer gamma on the wire, fades
(no level streaming, one CHANGING + one CHANGED), frame cap, 1 Hz keepalive, hold-to-ramp
buttons, 8ch Extras, every config refusal/revert, Custom mirror both ways, overlap policy all
ways, mover position/limits/invert/16-bit fades, reset + events, presets (exact restore,
position-only, cross-layout, export/import, bad import), scene links, blackout, test channel,
ping failure/recovery, duplicate node drivers, node reload, controller reboot with **no frame
differing from the restored look**.
**Mutation-tested:** disabling the overlap policy, dropping persistence restore, keepalive every
tick, removing white extraction, a one-shot frame engine, ignoring scene links and dropping the
button echo are EACH caught.
**Found by the harness, fixed:** a `nudge` field shadowing the `Pos:nudge` method (the driver
logged the error and did nothing; the new no-failures guard exists because of it); no frame
sent until the first keepalive on an all-dark rig.
**What it cannot prove:** anything about Director itself. That is the bench list below.

## Bench session (brief Phase 0), in order. Back up the project first.

**Bench found (2026-10-08): `artnet_node` was "added" but never listed; `dmx_light` listed fine.**
The node declared NO proxy. Every driver without a standard proxy still names a SELF-proxy
(ButtonTimer, LEDWizard, Chowmain, Control4's own Enttec master `ExtraVeg_ArtNet_IP_Cloud`).
Fixed in build 5: `<proxy name="Art-Net Node">artnet_node</proxy>`, category `Others` (the Enttec
master declares none and lands in Other). `checks.py` now fails any driver with no proxy
(negative-controlled). The CR011R itself is proven: Control4's Enttec set drives a par through it.
Remove/unbind that master before testing ours, or two senders fight over the universe.
**Test Channel Action REPLACED by live Channel Test properties (Dave's ask, 2026-10-08):** one
channel for 5 s could not drive a fixture with master on 1 + RGBW on 2-5. Now: `Test Channels`
(Off/1-16), `Test Start Channel`, `Test Ch 1..16` sliders (shown/hidden to match the count),
`Test Addresses` readout. Properties, not an Action, because an Action dialog is a fixed form that
applies only on OK. Overrides fixtures (not HTP), holds until Off, forced Off on every load,
flagged in Status. Bench-confirmed working. **`RANGED_INTEGER` renders as a numeric box, not a
slider**; Composer's slider types are `SCROLL` (continuous) and `TRACK` (discrete ticks), both
documented since OS 2.10 (fundamentals, Advanced Properties). Test Ch now `SCROLL` (build 11),
UNVERIFIED: no shipping driver sample uses either type. If it renders well, consider it for the
fixture drivers' level-type properties too.
**Property edits always need Composer's Set** (no driver can make the Properties tab live), so the
node's test can never be drag-live. Live sliders are only plausible on a fixture's Extras tab
(light_v2 only; the node has no light proxy, and adding one would put a fake light in the room).
Possible later: a per-fixture channel test on Extras, once the Extras tab is bench-verified.
**Bench item 1 DONE (2026-10-08):** node lists, Status reads "node answers ping" (ICMP health check
works on the controller), and the channel test drives the par through the CR011R, so UDP output,
IP and Net/Sub-Net/Universe are confirmed. Node items still open: binding (several fixtures on ONE
output), reboot behaviour, keepalive holding the look; all need a fixture driver bound.

1. **Node output:** set the IP, watch Status reach "node answers ping", Test Channel a par's
   first channel. If nothing arrives: CreateNetworkConnection is called with no type argument,
   then `NetConnect(6001, 6454, "UDP")`. Try `"UDP"` as the third CreateNetworkConnection arg,
   or a static `<connection>` in driver.xml. Confirm Net/Sub-Net/Universe mapping on the CR011R.
2. **Binding:** one node output with several fixtures bound (Director may allow only one consumer
   per provider; if so, 24 numbered outputs). Confirm `GetBoundProviderDevice` / OnBindingChanged
   give the node's device id and SendToDevice round-trips (Patch fills in).
3. **light_v2 on a par:** color picker, brightness, CCT, scene, keypad link, Room Off, voice.
   Watch that DYNAMIC_CAPABILITIES_CHANGED is honoured (a Dimmer-type layout must hide color).
4. **Extras tab:** the slider (`min`/`max`/`resolution`/`value`) and button (`buttontext`)
   ATTRIBUTE NAMES are from documented field names, not a captured sample: UNVERIFIED. Also
   whether `textfield` (preset name) renders. All in `extras.lua` `object_xml()`, one place.
   Also confirm Extras commands arrive with a `value` param (a shipping driver says yes).
5. **Mover full ALS:** put the mover in a scene; confirm PUSH_SCENE arrives, ACTIVATE_SCENE fires
   with the id, the scene applies, and a linked preset moves the head. Keypad LED tracking.
6. **Fixture facts** (then set `verified=true` in `layouts.lua`): ColorKey strobe 0 = no strobe?
   speed direction? reset hold time? DazzlingStage 4/8ch channel order from the paper manual.
7. **What the CR011R does when Art-Net stops** (hold vs blackout): reboot the controller and
   watch for a jump.
8. Reboot restore, keepalive ~1 Hz (Wireshark/DMX-Workshop), frame-rate cap, overlap warning.

## Control4's "Artnet DMX via Enttec" driver set — evaluated as a master, NOT adopted (2026-10-08)

Dave got the CR011R + a par working with Control4's own catalog set (`ExtraVeg_ArtNet_IP_Cloud.c4i`
master + `light_ExtraVeg_ArtNet_*` children, Control4/ExtraVeg, last modified 2016). That proves
the node, network and Net/Universe config independently of our drivers. Question: reuse their master
and only write light drivers? Findings from the catalog files (all `.c4i`, XML readable):
- **Master and every child have ENCRYPTED Lua** (`<script>` is ciphertext). Their binding class
  `ArtNet_DMX_CIRCUIT` (master id 1 provider, child id 1 consumer) and properties are visible; the
  **messages over that binding are not**, and are documented nowhere.
- Children: Dimmer/Relay (light), Dimmer V2/Relay V2 (light_v2, single channel), RGB and RGB-M
  (**four `light` v1 proxies**, i.e. the master + R + G + B sub-lights Dave saw). No white, no CCT,
  no color picker: the set predates light_v2 color.
- Master: one universe, `Fade Interval` 20-500 ms (default 500, 20/50 "use at your own risk"),
  universe entered as one number with Sub-Net as the high nibble (Sub-Net 1 Uni 0 = 16).
**Why not adopted:** using it means reverse-engineering an encrypted, undocumented, abandoned
protocol we can never fix or extend (16-bit pan/tilt, mover overlap refusal, color cross-fades as one
fade, keepalive/reboot restore all depend on the master), and our `artnet_node` is already built
and tested, so it saves no work. If ever wanted, the cheap way in is a spy driver: declare an
`ArtNet_DMX_CIRCUIT` provider, bind their Dimmer V2 to it, and log what arrives.

## Light driver bench feedback (2026-10-08/10)

- **Color picker, CCT and dimming work flawlessly on the par. Protect them**: any redesign of the
  fixture section must leave the color engine (`color.lua`, the mixed-emitter path) untouched, and
  the scenario checks on wire bytes are the guard.
- **`has_leds` KEPT (Dave's instinct, confirmed by the keypad BUTTON_LINK protocol).** The light's
  LED colors are what a keypad button bound to its On/Off/Toggle Button Link shows: the light sends
  `BUTTON_COLORS {ON_COLOR, OFF_COLOR}` + `MATCH_LED_STATE` down the link and answers
  `REQUEST_BUTTON_COLORS`. **Our light implemented none of the color half** (only MATCH_LED_STATE),
  and never sent `BUTTON_INFO {BUTTON_ID, ON_COLOR, OFF_COLOR, CURRENT_COLOR}` to the proxy, which
  is the likely reason the device screen's buttons were black. Fixed in light build 7: handles
  `SET_BUTTON_COLOR` / `REQUEST_BUTTON_COLORS`, persists colors, reports both ways. Defaults: On and
  Toggle blue-when-on, Off blue-when-off. Param names read from Snap One's template (facts only,
  decision 7). UNVERIFIED on hardware: that the black buttons were these, and keypad follow.
- **Fixture section redesign: proposed, awaiting Dave** (see conversation 2026-10-10): Fixture Type
  becomes how the fixture maps onto Control4's controls, not a model; per-channel functions stay;
  non-color channels already go to Extras.

## Carried-over lessons applied (from YAS209)

Repeating timers pass `bRepeat=true`; every C4 call used was checked against Snap One's published
API; misconfiguration logs through `C4:ErrorLog` regardless of Debug Mode; the Channel Map mirror
cannot echo-loop (UpdateProperty does not fire OnPropertyChanged, and init reads properties once);
structural changes (proxies/connections) must be batched and backed up before install.

## Out of scope (brief 13)

QLC+ link, sACN, ArtPoll discovery, multi-element scenes beyond what full ALS gives the mover,
Amber/Lime/Cyan in color mixing (they are Extras sliders), pixel mapping, Control4-generated
chases.
