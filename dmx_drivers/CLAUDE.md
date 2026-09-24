# dmx_drivers — Art-Net DMX driver set for Control4

**Status: OPEN, v0.0.0 — design reviewed (2026-09-24), nothing built yet.**
Spec: `dmx-artnet-driver-set-brief.md` (v2, Dave's brief). This file holds status, decisions
and review findings; where it and the brief disagree, this file records the decision.

Three c4z's from one shared codebase: `artnet_node` (gateway, owns one universe, all fades,
UDP 6454 unicast), `dmx_light` (light_v2 + Extras), `dmx_mover` (light_v2 + uibutton web view
+ a second light_v2 "Positions" preset selector). Hardware: Pknight CR011R, ColorKey MiniWash
Quad 4 MKII, DazzlingStage 4x8W RGBW pars. Separate universe from Control4's own Vibrant DMX.

## Review findings (2026-09-24) — amendments to the brief

**Repo-convention corrections**
- Layout is `dmx_drivers/` (one project folder), not `drivers/dmx_artnet/`; research notes go
  in `dmx_drivers/research/`, not `tools/pcap_notes/`. One project = one commit prefix
  (`dmx_drivers:`) even though it ships three c4z's.
- There is no "squish" convention. Build = a `build.sh` per the YAS209 pattern, run per driver:
  stage `common/*.lua` into each c4z, luac + `scopecheck.py` + XML `--`-in-comment check +
  docs-coverage warning, `VERSION` (0.x) + auto-bumped integer `<version>` + `@BUILD@` stamp.
  The brief's "Driver Version" property must be the `@BUILD@` token, never hardcoded.
- **c4z filenames are load-bearing** (`web_view_url controller://driver/dmx_mover/...` and
  `GetDevicesByC4iName("artnet_node.c4z")`), so the build must output exactly
  `artnet_node.c4z` / `dmx_light.c4z` / `dmx_mover.c4z` — no `-dmw` style suffix.

**Carried-over DriverWorks lessons that apply directly**
- Every repeating timer (frame scheduler, keepalive, jog 50 ms) passes `bRepeat=true`; never
  rely on `timer:Reset()` restarting a fired one-shot (YAS209 state poll died this way).
- Every `C4:` call gets checked against the published API before code depends on it
  (`C4:Log`, `C4:ReadFile` were both nil). Unverified in this brief so far:
  `GetDevicesByC4iName`, `ColorXYtoRGB`, `SetPropertyAttribs`, `SendToDevice` from a non-proxy
  driver, `UpdatePropertyList` for DYNAMIC_LIST.
- Misconfiguration (no node bound, no IP, footprint overflow, overlap) reports through an
  unsilenceable path, since a re-add resets Debug Mode/properties.
- Channel Map text <-> per-channel properties is a two-way mirror: needs the init guard +
  compare-before-write echo-loop guard, or editing one rewrites the other forever.
- Proxies/connections are STRUCTURAL: freeze all three driver.xml structures in Phase 0 before
  installing into Dave's live project; batch structural changes; back up before every update.
- Offline harness (simharness pattern) from day one: capture UDP payloads and decode them as
  ArtDmx, drive proxy commands as SEQUENCES, stubs no more forgiving than the real API.

**Design issues to settle**
1. **Positions load side effects — OPEN, deliberately deferred (Dave, 2026-09-24).** A
   light_v2 that reports level = slot N stays "on" forever (room lights-on indicator, Room Off,
   "all lights"). Dave is not yet sure position even needs to be its own part of a scene —
   Control4 was not designed for this kind of lighting. Decision: build the rest, let the right
   answer show itself during bring-up; do not lock the 5003 proxy in until then.
2. **Overlap policy — DECIDED (Dave, 2026-09-24): depends on fixture kind.**
   - `dmx_light` <-> `dmx_light`: **allowed**, merged HTP. Sharing channels between static
     fixtures is a legitimate control choice, not an error. Reported in the node's Patch as
     shared, not flagged as a conflict.
   - Anything involving a `dmx_mover`: **hard error**. Movers must be fully independent to work.
     The node refuses the later registration, both drivers show why, the refused mover outputs
     nothing.
   - Needs a `KIND` (light|mover) param on `DMX_REGISTER`.
   - Watch: HTP is right for intensity/color but on stepped channels (program, strobe, macro)
     the higher value wins, so one par in a program mode drags a sharing par into it. Also two
     sharing pars with different layouts is almost certainly a mistake — warn on that.
3. **Frame timer only while fades are active**; 1 Hz keepalive otherwise; cache the 512-slot
   frame string rather than rebuilding it every tick.
4. Add to Phase 0: what the CR011R outputs when Art-Net stops (hold last look vs blackout).
   Matters for controller reboots and the "no jump on restore" criterion.
5. Target is Dave's 4.x director; 3.3.2 stays as the API floor only.

## Next
Phase 0 (brief §11). Offline half can start immediately: `common/artnet.lua` + byte-exact tests
against the Art-Net 4 spec, the harness, and minimal node + fixture drivers. Hardware half needs
the CR011R on the LAN with a static IP and one par patched.
