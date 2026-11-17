# dmx_drivers — Art-Net DMX driver set for Control4

**2026-11-17: dmx_light now handles PIXEL fixtures** (Alcon 11260 for a client job): see "Pixel
fixtures in dmx_light". Built + offline-tested, not yet on hardware. The multi-fixture/mover bench
plan below is paused, not dropped.

**Status: OPEN, v0.1.0 — ON THE BENCH (2026-10-11).** Node + one RGBW par proven on the real
controller (output, ping, channel test, colour picker, CCT, dimming, Max Brightness). Light Extras
proven NOT to render on this system; controls re-homed to Composer + programming. **Next bench
session (Dave, 2026-10-11 evening): several fixtures on one node output at different addresses,
then the moving head** (first time the mover driver is installed). See "Next bench session" below.

Spec: `dmx-artnet-driver-set-brief.md` (Dave's brief, v2). This file records status and every
decision; where it and the brief disagree, **this file wins** (several brief items were changed
by Dave's calls, listed below).

Three c4z's from one shared codebase:
- **`artnet_node`**: one universe on one node. Merges fixtures, runs every fade, sends ArtDmx
  unicast on UDP 6454, 1 Hz keepalive, frame-rate cap, ping health check, patch display.
- **`dmx_light`**: any non-moving fixture as ONE light_v2 load, including pixel fixtures (a repeated
  channel group, all pixels the same color); non-light channels via Set Control.
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

## Next bench session: multiple fixtures, then the moving head

1. **Several fixtures on ONE node output** (open item from bench item 2). Bind every fixture's Art-Net
   Node input to the node's single Fixtures output. If Composer refuses a second binding, the node
   needs numbered outputs: a STRUCTURAL change, so stop and report rather than work around it.
   The node's **Patch** should list every fixture with its range.
2. **Addresses:** each fixture's Start Address matches its DIP/menu address; Footprint shows the
   range. Lights may share channels (both told, Patch says shared); anything overlapping the mover
   is refused, and Status names the collision.
3. **Moving head (dmx_mover, first install: add it new, no restart issue):** set **Pan/Tilt
   Min/Max soft limits before moving it**; choose the ColorKey layout matching the fixture's DMX
   mode (16ch preferred, both UNVERIFIED); then Aim Pan/Tilt, Nudge, Home, save a preset, Recall
   Preset from programming, link a preset to a scene. Check bench item 6 facts: strobe 0 = no
   strobe? speed direction? reset hold time?
4. If anything misbehaves: Debug Mode on, Lua output, plus the node's Patch and the fixture's Status.

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
- **Fixture section REDESIGNED (Dave's call, 2026-10-10; light build 11).** Fixture Type now says
  HOW a light maps onto Control4's controls, never which product: Single Color (On/Off), Single
  Color Dimmable, Tunable White, RGB, RGBW, RGB + Tunable White, Manual Color. **The Layout dropdown
  and every light model preset are GONE**: a light is Fixture Type + Start Address + Channel Count +
  per-channel Function (Channel Map mirrors them). Known maps live in the light's documentation.
  Rules worth keeping:
  * **Capabilities still come from the channels present**, never the type, so the color engine is
    untouched; `color.lua` was not edited. Single-color types use `mix_as = "dimmer"` for the one
    type check color.lua has. **RGB/RGBW/RGB+TW all keep the color TEMPERATURE slider**: Dave's
    RGBW par does CCT beautifully by mixing (one white LED), and that must not be lost.
  * **Proven unchanged: old build vs new build, byte-identical on the wire** for a dimmer+RGBW par
    across primaries, a pastel, D65, two CCTs, dim and fade; and identical for an OLD project
    migrated on load. Re-run that A/B (scratch worktree of the previous commit + a fixed command
    script) before any change near color.
  * On/Off: light_v2 `dimmer=false`, any level outputs full, fades forced to 0.
  * Manual Color: no picker, no CCT; brightness drives ONLY the Dimmer channel (refused without one);
    every color channel is an Extras slider.
  * Type change keeps the map only if it FITS: every channel allowed AND the channels the type
    depends on are present (an RGB+TW "fit" with no RGB would show no picker); else the type's
    starting map. First version kept a white-only map on RGB+TW: caught by the new scenarios.
  * Migration on load: old type labels ("Color Par / Wash", "Strobe / Effect", "Dimmer") resolve
    from the existing channels; the Channel Map text is the source of truth (it was the only record
    of a chosen built-in); a brand-new fixture starts from RGBW's map.
  * **Composer "default color rate ... DefaultColorRateMinimum 0 / Maximum 0 ... out of range"
    (bench, 2026-10-10):** we never declared `color_rate_behavior` (default 0 = unchangeable, with
    a 0-0 range, per the proxy's documented defaults) and our DYNAMIC_CAPABILITIES_CHANGED omitted
    the rate ranges. Fixed (light/mover build 12): `color_rate_behavior` 2 in driver.xml AND every
    dynamic update restates behavior + color/brightness rate min/max; `UPDATE_COLOR_RATE_DEFAULT`
    now handled. **Rule: a dynamic capability update should restate the rate ranges every time.**
    Colour output re-checked byte-identical. UNVERIFIED: that this clears the dialog.
  * **Extras live in NAVIGATOR only** (app / touch screen), never Composer (Snap One: "Extras Tab
    located on the main Navigator screen for the Proxy"). In Composer the only route is the `Set
    Control` programming command, which Dave confirmed lists Strobe. **First bench run: no Extras
    tab in Navigator.** Evidence gathered (light build 14): Snap One's own sample
    (`docs-driverworks/sample_drivers/thermostat_v2/get extras setup.xml`) shows a button's text as
    a CHILD ELEMENT `<buttontext>`, which we had as an attribute: fixed. No public sample of a
    slider exists anywhere searched (Snap One docs, templates, GitHub code search, local drivers);
    its min/max/resolution are now written as BOTH attributes and child elements. Also answering
    `GET_EXTRAS_SETUP`/`GET_EXTRAS_STATE` (a public YeeLight driver does), and the setup XML is
    logged in Debug. If the tab is still missing: force-quit/reopen the app (has_extras is a
    capability the UI may have cached), then try a section with only a list object (the one shape
    confirmed by several shipping drivers) to split "slider XML" from "Extras at all".
  * **Build 14 bench: still no Extras tab**, although the log proves a well-formed setup is sent
    and updated, and Navigator NEVER sent GET_EXTRAS_SETUP. Suspect: has_extras never reaches the
    proxy (static driver.xml says False; only our dynamic update says True, and NO dynamic
    capability has yet been confirmed applied on hardware). Build 15 adds the **Show Proxy
    Capabilities** action: reads light_v2 proxy variable 6661 ("Light Dynamic Capabilities") via
    `C4:GetDeviceVariable(C4:GetProxyDevices(), 6661)` and prints it beside what we last sent. If
    has_extras reads False there, the dynamic path is not applied and the fix is static
    `<has_extras>True</has_extras>` (structural: batch with color_rate_behavior, one restart).
  * **Show Proxy Capabilities result (bench, build 15): the DYNAMIC PATH WORKS.** The proxy held
    has_extras=True and color_rate_behavior=2, so runtime capabilities are applied (the colour-rate
    fix is confirmed at the proxy) and Extras is NOT blocked by the proxy. **Found a new bug the
    same way:** our numeric capabilities arrived as `6.5535e+06` (the static XML values read
    `6553500`). Lua numbers through SendToProxy can be float-formatted. Build 16: `Light:notify`
    sends every whole number as an integer string. **Rule: send integers to a proxy as strings.**
    (Harness: notifies now keep `raw` (as sent) beside number-normalised `params`.)
  * **Navigator still shows no Extras tab with the proxy saying has_extras=True.** Build 16 adds a
    temporary **Extras Test** property (Diagnostics; forced Off on load): replaces the setup with ONE
    fixed object (Snap One sample list / slider as attributes / as elements / both / button) and
    logs every command Navigator sends back. One bench pass then says which shape renders. Remove
    the property once settled.
  * **Extras Test result (bench, build 16): NOTHING renders, not even Snap One's sample list shape**,
    after force-quit / restart / app update. So it is NOT our XML and NOT the proxy flag (proxy
    variable 6661 says has_extras=True). The 6.5535e+06 persisted after we sent "6553500": that
    formatting is the PROXY's own, harmless, not ours. Remaining suspect: Navigator decides on the
    Extras tab from the STATIC capability at device load and ignores the dynamic one (our static
    was False; the mover's is True; Control4's own DMX Light declares True statically).
    **Build 17 = the structural batch** (one Director restart, back up first): dmx_light static
    `has_extras` True, plus `color_rate_behavior` 2 on both drivers. If the tab then appears, keep
    static True and let the dynamic value drive it; if not, Extras for lights may not render in the
    Control4 app at all, and the next check is a touch screen or a known-good Extras driver.
  * **Build 17 result (after the Director restart): still no Extras tab, on the phone app AND a
    T4.** Navigator has never once sent GET_EXTRAS_SETUP to the driver: it does not ask and fail, it
    never asks. Every driver-side cause found is ruled out, and no working light Extras example has
    ever been seen on this system (Control4's own DMX Light declares has_extras but sends nothing).
    **Decisive test = `tools/extras_probe/`** (Dave approved): a bare light_v2 dimmer, static +
    dynamic has_extras, ONE object (Snap One sample checkbox / Hue-shape switch / list, one Action
    each), logs every proxy/UI message. Packaged by hand to `dist/extras_probe.c4z` (zip the folder's
    contents), sim-checked. Tab appears -> something in dmx_light blocks it, bisect. Nothing -> light
    Extras do not render on this system: stop, record it, and give extended channels another home
    (Set Control already works; properties need Set; a separate device was ruled out by Dave).
  * **SETTLED (2026-10-11): LIGHT EXTRAS DO NOT RENDER ON THIS SYSTEM. DO NOT RE-INVESTIGATE.**
    `extras_probe` (bare light_v2, static + dynamic has_extras, one object each in Snap One's sample
    checkbox / Hue switch / list shapes) showed NO Extras and no sub-menus on the phone app or the
    T4 (OS 4.1 Director). Its log shows the UIs NEVER sent GET_EXTRAS_SETUP: only
    SET_BRIGHTNESS_TARGET. So the documented light Extras path is dead here regardless of driver.
    Everything built for it is correct per the docs and stays (harmless; may work on a later OS),
    but nothing user-facing may DEPEND on it. **This breaks decision 2: the mover's whole control
    surface (pan/tilt sliders, nudges, presets) was designed for Extras** and must be re-homed
    before the mover's bench session. Extended light channels (strobe, program, speed) need a home
    too; `Set Control` in programming is confirmed working. Decision pending with Dave.
  * **RE-HOMED (Dave's call, 2026-10-11; build 19): options 1 + 2.** Clients reach extended
    channels and mover presets through PROGRAMMING (Set Control, Recall Preset, Set Position) on
    Custom/Experience buttons, keypads and scenes; dealers set up in COMPOSER. Mover gained `Aim Pan
    (%)` / `Aim Tilt (%)` (SCROLL; each Set moves the head; they always show the real, clamped
    position), `Nudge Size` + four Nudge Actions, `Save Mode` (was an Extras list), and Actions
    `Link Selected Preset to Last Scene` / `Unlink Last Scene` (were Extras buttons). The Extras
    Test property is removed; the Extras code stays, unused. A scenario section drives the mover
    with NO Extras command at all. Docs rewritten for both drivers. Option 3 (extra light proxies as
    live sliders) not taken; option 4 (driver-hosted web page) is for discussion only, not built.
  * **Any edit to static `<capabilities>` makes Composer demand a Director restart** (Dave hit it
    on build 12: the only structural diff was one added `<color_rate_behavior>` line). Build 13
    takes it back out; the dynamic update carries the value. **PENDING STRUCTURAL BATCH** (apply
    together, one restart, back up first): add `<color_rate_behavior>2</color_rate_behavior>` to
    the static capabilities of dmx_light and dmx_mover. Before shipping any build, diff its
    capabilities/connections/proxies against the installed build to know which kind of update it is.
    (Batch APPLIED in build 17.)
  * **MAX BRIGHTNESS (Dave: "the light wasn't as bright as it should be", 2026-10-11; build 20).**
    Root cause, measured on the wire: white extraction moved the common R/G/B part to the W
    emitter and normalised, so pure white ran W ALONE with R/G/B at 0 (one emitter of four), and
    pale colours left R/G/B headroom unused; a WW/CW pair ran constant-sum (50%/50% mid-range). New
    `Max Brightness` property (On default; shown for RGB+W or WW/CW): once W is full, the remaining
    white also comes from R=G=B (scale s = min(2/(w+maxc), 1/maxc)); WW/CW normalised to peak.
    **Proven:** Off is byte-identical to build 19 on the A/B script; On changes ONLY whitish rows
    (D65 0,0,0,255 -> 255,255,255,255; 4600K default brighter) and leaves primaries, the pastel,
    warm CCTs and dimming identical. Unit sweep: chromaticity preserved exactly under the engine's
    model (W == R+G+B white), never over full, never dimmer than Off, saturated colours unchanged.
    **Warm whites cannot get brighter while staying warm** (red is already pegged, the W LED is
    cooler): an inherent limit of an RGBW fixture, not a bug. Real W LEDs are not exactly D65, so
    very pale colours may tint slightly with On: that is what the Off setting is for.
  * **dmx_mover still has Layout + its ColorKey presets** (shared code treats Layout as optional).
    Revisit when the mover reaches the bench.

## Pixel fixtures in dmx_light (2026-11-17, light build 27) — BUILT + offline-tested, NOT on hardware

**Why:** Dave's client job uses an **Alcon Lighting 11260 RGBW, 3 ft**, whose LEDs are
individually addressable: factory address 1, RGBW per pixel in order (ch1-4 = pixel 1, ch5-8 =
pixel 2...). With "2-inch" pixel control that is believed to be **18 pixels / 72 channels:
UNVERIFIED** (Alcon's docs are unreliable: their "single pixel control" product turned out to mean
the whole fixture is one pixel). Control4's stock DMX driver needs one driver per pixel. Dave's ask:
one flexible light driver for pars, this bar, pixel tape, any RGBWW pixel layout; **movers and
animation explicitly out of scope** (still).
**Model (my design, Dave asked for a clear UX):** a fixture = **fixture channels** (the existing
Channel N rows; masters like dimmer/strobe/program) + an optional **pixel group** repeated
`Pixel Count` times, placed after `Fixture Channels Before Pixels` of the fixture channels. **Pixel
Count 1 = no pixels = exactly the old driver.** Every pixel gets the same values: still ONE light_v2
load. Composer sections: **Fixture** (Type, Start Address, Footprint, new read-only **Layout
Summary** numbered like a manual, Channel Map) / **Pixels** (Pixel Count, Channels Per Pixel 1-12,
Pixel Channel 1-12 Function/Default) / **Fixture Channels** (Channel Count now 0-32, Before
Pixels, Channel 1-32). Rows hide unless in use.
- **Channel Map text** carries the whole layout: `dimmer,strobe,18x(red,green,blue,white),program`
  (`Nx(...)`, also `N x (...)`, `N*(...)`; one group; `1x(...)` = inlined). Without a group the text
  format is unchanged character for character. Pasting it sets Pixel Count too. A pixel map on the
  mover is refused (it has no pixel properties).
- **Pixel Count 1 -> N auto-splits** the map: the longest run of color/color_extra channels becomes
  the pixel group (single-color types: dimmer + its fine), the rest stay fixture channels around it.
  So the Alcon is two edits: RGBW + Pixel Count 18. **N -> 1 flattens** one copy back in place.
- Type change on a pixel fixture keeps the count; pixel group -> the type's default map; masters the
  type allows AND that do not clash with the group are kept (single color: the master dimmer goes,
  because the dimmer now repeats per pixel).
- Validation is per ROW (fixture rows + one pixel group): a role once across both; coarse/fine must
  be in the same group; total over 512 refused with the arithmetic. 16-bit pairs are emitted per
  pixel. Extras / Set Control list a pixel role ONCE and apply it to every pixel.
- Engine change is small: `layouts.compile` expands the group into `layout.channels` (each copy
  tagged `pixel = p`, `layout.offsets[role]` = all offsets); `fixture.compute` no longer treats
  pixel copies as "repeated role -> default". **color.lua untouched.** Node needed no change.
**Proven offline:** the par A/B (8 light configs x 38 frames incl. colors, CCTs, levels, a fade, Set
Control, Manual Color) is **byte-identical** to build 20; every one of 18 pixels matches a reference
4ch par on the wire across colors, CCT, gamma, a mid-fade sample and OFF; Composer flows (1->18->1,
masters split, Before Pixels move, Channel Count growth, Channels Per Pixel growth, type changes);
zones (two drivers on one bar, exact boundary); refusals (mover overlap, >512, past universe end,
mover pixel map). Mutation: treating pixel copies as repeats is caught by 12 checks. Tests now
186 unit + 302 scenario.
**Bench next (Alcon):** confirm 18 pixels and RGBW order with the node's Channel Test (start 1, 8
channels; then the last pixel at 69-72 and nothing past it), then mark the docs row verified. Zones
are free: one driver per zone by Start Address.

## Option 4: driver-hosted web page — RESEARCHED, NOT BUILT (2026-10-11, discussion only)

Dave asked whether Control4's own rich config pages (Core5, Lux keypads) are web pages, whether we
can build drivers like that, and whether they really show in Navigator. Findings, from Snap One's
published docs (uibutton proxy protocol, DriverWorks API/fundamentals):
- **Composer: no.** Those Core5 / keypad editors are Composer's own compiled UI (managed .NET
  `Control4.Designer.*` modules; see better_composer/CLAUDE.md), not driver pages. A third-party
  driver cannot add a pane to Composer. Its Composer surface is properties (incl. SCROLL, TRACK,
  LINK), Actions and programming. A `LINK` property opens a URL in the dealer's browser, so a
  driver CAN host its own setup page (`C4:CreateServer`, OS 2.10+, TCP/HTTP on the controller) and
  link to it from Composer: a real, if unusual, route to a rich dealer UI. LAN only.
- **Navigator: yes, documented and long-standing.** The **`uibutton` proxy ("Experience button")**
  supports an HTML WebView: capability `web_view_url` (OS 2.10+), and with
  `controller://driver/<c4z name>/...` the page is served from the driver's own `www/` folder in the
  .c4z. **JavaScript API** (Navigator 321.46+, OS 3.1.3+): the page can `sendCommand` to its own
  driver, `subscribeToDataToUi`, `subscribeToVariable`, over the normal channels, so it works
  remotely in the mobile app too (`mobile_web_view_enabled`). T4 browser: Gecko/Firefox 96.
  4-tap on the header opens a JS console.
- **Rules Snap One attaches:** uncertified, the developer self-certifies on T3/T4/mobile browsers
  and owns all support; Snap One may decline to list it and support may tell a dealer to remove it.
  For our own installs that is acceptable.
- **What it would mean here:** a live pan/tilt pad (including press-and-hold, which Extras could
  never do), live strobe/effects, preset buttons, per-fixture panels. Crucially it need not be one
  per fixture: ONE separate "DMX Control" uibutton driver per room/system could address every
  fixture via SendToDevice, which keeps decision 1 (one fixture = one load) intact and adds one
  Experience button, not one per light. UNVERIFIED on this system: nothing web-view has been run
  here. **Positive control first, before any build:** add Snap One's
  `docs-driverworks/JS Demo Driver/JavascriptAPIDemo.c4z` and check it on the T4 and the app
  (the Extras saga is the lesson: confirm the UI path with a known-good driver before writing ours).

## Carried-over lessons applied (from YAS209)

Repeating timers pass `bRepeat=true`; every C4 call used was checked against Snap One's published
API; misconfiguration logs through `C4:ErrorLog` regardless of Debug Mode; the Channel Map mirror
cannot echo-loop (UpdateProperty does not fire OnPropertyChanged, and init reads properties once);
structural changes (proxies/connections) must be batched and backed up before install.

## Out of scope (brief 13)

QLC+ link, sACN, ArtPoll discovery, multi-element scenes beyond what full ALS gives the mover,
Amber/Lime/Cyan in color mixing (they are Extras sliders), per-pixel color / pixel mapping
(pixel FIXTURES are supported, all pixels one color), Control4-generated chases.
