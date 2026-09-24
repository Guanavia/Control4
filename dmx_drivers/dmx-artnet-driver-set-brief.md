# Driver set brief: DMX over Art-Net for Control4 (v2)

**Replaces:** `dmx-moving-head-driver-brief.md` (single-fixture Eliminator version).
**Workstream:** Control4 DriverWorks only, meaning native Composer, Director and Lua. No HA, MQTT or QLC+.
**Target OS:** 3.3.2 or later. This covers the light_v2 target API, color conversion helpers and improved `reduced_als_support`.
**Hardware in scope:** Pknight CR011R Art-Net node (1 universe), ColorKey Mover MiniWash Quad 4 MKII, DazzlingStage 4×8 W RGBW mini pars. Any other DMX fixture can be set up by type and custom channel layout.
**Coexistence:** David also runs Control4's own DMX system (Vibrant DALI/DMX gateway + stock "DMX Light Driver", which uses a proprietary protocol) on a **separate universe**. This driver set never touches it, and nothing here needs to interoperate with it.

---

## 1. Summary

The set has three drivers built from one shared codebase. It follows the same model as Control4's own DMX system and the old EV/Enttec Art-Net driver: one gateway driver per node, then one driver per fixture or "circuit", bound to it in Connections.

| Driver (c4z) | Role | Proxies |
|---|---|---|
| `artnet_node` | Owns one Art-Net universe on one node. Merges every bound fixture's channels into a single frame, runs all fades, and sends UDP to the node. | None. It's a gateway: properties plus a control output for fixtures. |
| `dmx_light` | Any fixture that doesn't move. Fixture types are Dimmer, Tunable White, Color Par/Wash, and Strobe/Effect. | `light_v2` (native dimmer and color picker, scenes, keypads, voice). Non-light channels (strobe, macros, programs, sound) go on the light's **Extras** tab. |
| `dmx_mover` | Moving fixtures, of type Moving Head Wash or Moving Head Spot/Beam. | `light_v2` for intensity and color (same as `dmx_light`). `uibutton` web view "Controls" for the d-pad, beam, effects and preset management. A second `light_v2` "Positions" is a preset selector, so position presets can go into Advanced Lighting scenes: level N% recalls position preset N. |

There are two drivers for fixtures, not one, because **proxies are fixed per c4z**. A par must not show a Controls button or a Positions load in Composer and Navigator, so movers and non-movers are separate files. Both use the same fixture-type and channel-layout engine, so the dealer experience is identical: pick a **Fixture Type**, pick a **Layout** (a built-in stack or Custom), and set the **Start Address**.

Every fixture driver controls **one circuit**, the way any Control4 load does. Several physical fixtures set to the same DMX address are simply one circuit. The set deliberately has no cue stacks, chases or timeline; beyond per-fixture presets and fades, that belongs to QLC+ (out of scope).

---

## 2. Requirements (from David)

1. Control regular RGBW fixtures and RGBW moving fixtures, at any DMX channels, over an Art-Net interface.
2. Choose fixtures by **type** (moving, par, spot, etc.), not brand. A sub-menu of preconfigured channel stacks for the lights in use, plus **Custom**, is secondary. What matters is that each type can be configured with the correct control inputs.
3. Channels/start address are selectable so fixtures can sit anywhere in the universe.
4. Movers: a **4-way d-pad** for pan/tilt, **sliders** for everything else. Show **only** the controls present in the fixture's layout.
5. **Presets** for movers that can be triggered from **buttons/keypads** and used in **Advanced Lighting scenes**.
6. Movers are **one driver**, not separate color and movement drivers.
7. Control one circuit at a time like normal Control4 lighting, not a virtual lighting desk. Keep complexity down; no QLC+-style sequencing.

---

## 3. Architecture

```
 Navigator / keypads / AL scenes / programming
        │                         │
  light_v2 proxy            uibutton web view (movers)
        │                         │
 ┌──────▼─────────────────────────▼──────┐     ┌──────────────────────────────┐
 │ dmx_light / dmx_mover (one per circuit)│     │ artnet_node (one per node)   │
 │  layout engine: roles → channels       │     │  512-slot universe buffer    │
 │  color engine: xy/CCT → emitters       │────▶│  per-slot fade engine        │
 │  jog engine, presets (mover)           │ msg │  16-bit pair fades           │
 │  NEVER touches the network             │◀────│  overlap detection           │
 └────────────────────────────────────────┘     │  frame scheduler + keepalive │
                                                │  ArtDmx → UDP 6454 unicast   │
                                                └──────────────┬───────────────┘
                                                               ▼
                                                   Pknight CR011R → DMX line
```

### 3.1 Node ↔ fixture link
- **Association:** a Composer control binding. `artnet_node` exposes a provider control output (custom class `ARTNET_DMX`). Each fixture driver has a consumer input of the same class. The dealer drags one to the other in Connections, like the Vibrant gateway's "Control Outputs".
- **Transport:** messages go via `C4:SendToDevice(deviceId, CMD, tParams)` and are received in `ExecuteCommand`.
  - A fixture finds its node with `C4:GetBoundProviderDevice(0, <input binding>)`.
  - The node learns each fixture's device id from `DMX_REGISTER`.
  - The binding is used only for the association, which avoids relying on undocumented `SendToProxy` behavior across non-proxy bindings. §11 (Phase 0) confirms this.
- **Multiple fixtures per output:** Phase 0 checks whether one provider binding accepts many consumers. If not, the node declares **24 numbered outputs** ("Fixture 1" … "Fixture 24"). If neither works, the fallback is a `DEVICE_SELECTOR` property on the fixture that picks its node.

### 3.2 Message protocol (all params are strings)

| Direction | Command | Params |
|---|---|---|
| fixture → node | `DMX_REGISTER` | `FIXTURE_ID` (the fixture's `C4:GetDeviceID()`), `NAME`, `START` (1–512), `FOOTPRINT` |
| fixture → node | `DMX_UPDATE` | `FIXTURE_ID`, `OFFSETS` (comma list of 0-based offsets within the footprint, or `ALL`), `VALUES` (comma list 0–255, same order), `FADE_MS` (0 = snap), `PAIRS` (optional, e.g. `0:1,2:3` = coarse:fine offsets to fade as 16-bit) |
| fixture → node | `DMX_UNREGISTER` | `FIXTURE_ID` (on address/layout change before re-register, and when the driver is removed if Director allows) |
| node → fixture | `NODE_STATE` | `ONLINE` (true/false), `CONFLICT` (empty, or a description of overlapping fixtures) |
| node → fixture | `NODE_RESYNC` | none. The node restarted or its settings changed, so every fixture re-registers and sends `OFFSETS=ALL`. |

Rules:
- The node keeps **per-fixture slices**. When two fixtures overlap, the node warns both through `NODE_STATE`, shows the conflict in its Status, and uses highest-takes-precedence (HTP) for the overlapping slots. Overlap is a configuration error, not a feature.
- Fixtures send only changed offsets. The node does all interpolation, so a scene recalling 6 fixtures is 6 messages, not 6 × 30 fps.
- **Jog exception:** the mover's jog engine sends position at up to about 20 Hz with `FADE_MS` ≈ tick length, which gives smooth motion.

### 3.3 Why the node owns fades
- One timer instead of one per fixture.
- Smooth, synchronized scene transitions across fixtures.
- Fixture drivers stay simple and stateless about timing.
- It mirrors the EV/Enttec master driver's fade-time design.

---

## 4. Art-Net and gateway reference

### ArtDmx packet (Art-Net 4)

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 8 | ID | `"Art-Net\0"` |
| 8 | 2 | OpCode | `0x5000` little-endian, i.e. bytes `00 50` |
| 10 | 2 | ProtVer | `00 0E` |
| 12 | 1 | Sequence | 1–255 rolling |
| 13 | 1 | Physical | 0 |
| 14 | 1 | SubUni | `(SubNet << 4) \| Universe` |
| 15 | 1 | Net | `Net & 0x7F` |
| 16 | 2 | Length | big-endian, always 512 |
| 18 | 512 | Data | slots 1–512 |

- Send **unicast** to the node IP on UDP **6454**. Broadcast is not allowed.
- **Resend** every 800–1000 ms when nothing has changed.
- A node **merges at most two sources** (keyed by IP or Physical), so exactly one `artnet_node` instance may target a given node and port address. The node driver scans its peers with `C4:GetDevicesByC4iName("artnet_node.c4z")` and warns about duplicates.
- Lua 5.1: build packets with `string.char` and integer math. Don't rely on a `bit` library. `C4:SendToNetwork` handles embedded `\0`.

### Pknight CR011R
- Configure it via the OLED menu or DMX-Workshop.
- Set the mode to **Art-Net → DMX (output)**.
- Give it a **static IP** on the Control4 LAN (2.x, 10.x or 192.168.x; the last octet can't be 0 or 255).
- Port address fields are **Net 0–127, Sub-Net 0–15, Universe 0–15**. `artnet_node` mirrors these three fields exactly, so there's no "universe 0 vs 1" ambiguity.

---

## 5. Fixture model

### 5.1 Fixture types

| Driver | Fixture Type | Roles offered in Custom layouts |
|---|---|---|
| `dmx_light` | Dimmer | Dimmer, Dimmer Fine |
| `dmx_light` | Tunable White | Dimmer (opt.), Warm White, Cool White, CCT, Strobe/Shutter |
| `dmx_light` | Color Par / Wash | Dimmer (opt.), Dimmer Fine, Red, Green, Blue, White, Amber, UV, Lime, Cyan, CCT, Strobe/Shutter, Zoom, Color Macro, Macro Speed, Program/Auto, Sound Sensitivity |
| `dmx_light` | Strobe / Effect | Dimmer, Strobe Rate, Strobe Duration, Program/Auto, Macro Speed, Sound Sensitivity (plus color roles if present) |
| `dmx_mover` | Moving Head Wash | everything in Color Par/Wash, plus Pan, Pan Fine, Tilt, Tilt Fine, Pan/Tilt Speed, Movement Macro, Reset/Control |
| `dmx_mover` | Moving Head Spot/Beam | Moving Head Wash roles, plus Color Wheel, Gobo Wheel, Gobo Rotation, Prism, Focus, Iris, Frost |

Available to every type: **Fixed Value** (always outputs a set value) and **Unused**.

### 5.2 Layout selection (Composer properties)
- **Fixture Type**: LIST, filtered per driver as in §5.1.
- **Layout**: DYNAMIC_LIST of built-in stacks for the selected type, plus `Custom`. Built-ins are data entries in `profiles.lua` (§6).
- **Custom** exposes:
  - `Channel Count` (RANGED_INTEGER 1–32).
  - `Channel N Function` (LIST of the type's roles) and `Channel N Default` (RANGED_INTEGER 0–255) for N = 1..32. Properties beyond the count are hidden with `C4:SetPropertyAttribs`.
  - `Channel Map (text)`: a STRING mirror like `pan,panfine,tilt,tiltfine,speed,dimmer,strobe,red,green,blue,white` for quick paste, export and import. Editing either form updates the other.
- **Start Address** (1–512). Validate `start + count − 1 ≤ 512`; if it doesn't fit, refuse, revert and explain in Status.
- **Footprint** (read-only): e.g. "DMX 17–32 (16 ch)".
- Selecting a built-in layout fills the channel map. Switching to Custom afterwards starts from that map, so a built-in can be tweaked.

### 5.3 Role semantics

| Role group | Behavior |
|---|---|
| Dimmer (+Fine) | Driven by light_v2 brightness. If the layout has **no Dimmer**, brightness becomes a **virtual dimmer** that scales all color emitters. This is needed for 4-ch pars. |
| Color emitters (R, G, B, W, WW, CW, A, UV, Lime, Cyan) | Driven by the color engine (§7) from light_v2 color. UV has no place in color space, so it's an Extras/Controls slider. |
| CCT | A 0–255 channel mapped linearly across the layout's `cct_min`/`cct_max` Kelvin (properties in Custom, defaults 2700/6500). |
| Strobe/Shutter | A slider with a **"Normal/Open" value** taken from `Channel N Default`. The fixture always rests at that value, so every fixture's open/no-strobe value can be configured. |
| Pan/Tilt (+Fine) | The mover jog engine. 16-bit when a Fine channel exists, otherwise 8-bit. |
| Pan/Tilt Speed | A slider. Per-layout `invert` flag (some fixtures run fast→slow). |
| Macro / Program / Wheel / Gobo / Prism roles | In built-in layouts: **named steps** (e.g. "P1 … P8", "Sound Active") from the profile. In Custom: a raw 0–255 slider, since the driver can't know the fixture's ranges. |
| Reset/Control | Not a slider. It's a **Reset Motors** action that sends the layout's reset value (Custom: `Reset Value`, `Reset Hold ms`, defaults 255 / 5000) and then returns to the default. |
| Fixed Value | Always outputs `Channel N Default`. |

---

## 6. Built-in layouts

Built-in layouts are data only. Add more by appending entries. Every built-in carries a `verified` flag; set it true only after bench testing (§11).

### 6.1 ColorKey Mover MiniWash Quad 4 MKII (type: Moving Head Wash)
Source: ColorKey MKII manual (B&H copy). Pan 540°, tilt 270°.

**16-channel**

| Ch | Role | Notes |
|---|---|---|
| 1 | Pan | |
| 2 | Pan Fine | |
| 3 | Tilt | |
| 4 | Tilt Fine | |
| 5 | Pan/Tilt Speed | direction not stated; verify |
| 6 | Dimmer | 0–100% |
| 7 | Strobe | "0–255 slow→fast"; whether 0 = no strobe is **not stated**, so default 0 and verify |
| 8 | Red | |
| 9 | Green | |
| 10 | Blue | |
| 11 | White | |
| 12 | Movement Macro | 0–15 none · 16–128 fast auto · 129–255 slow auto with sound |
| 13 | Sound Sensitivity | |
| 14 | Color Macro | 0–140 color change · 141–255 sound-active color |
| 15 | Macro Speed | 0–250 |
| 16 | Reset/Control | 250–255 = reset (use 255, hold ~5 s) |

**14-channel** is the same list without Pan Fine and Tilt Fine: 1 Pan, 2 Tilt, 3 Speed, 4 Dimmer, 5 Strobe, 6–9 RGBW, 10 Movement Macro, 11 Sound Sens, 12 Color Macro, 13 Macro Speed, 14 Reset/Control.

Use 16-ch in practice for smooth jog and fades.

### 6.2 DazzlingStage mini par 4×8 W RGBW (type: Color Par/Wash)
The listing only states "4/8 CH" and no public chart was found. These **typical** layouts for this OEM par family must be **checked against the paper manual that ships with the lights** before `verified=true`:
- **4-ch:** Red, Green, Blue, White. There's no dimmer, so the virtual dimmer applies.
- **8-ch:** Dimmer, Red, Green, Blue, White, Strobe, Program/Function, Program Speed. Channel order and program ranges vary between batches of these pars; fix `profiles.lua` from the manual.

If the order differs, the dealer can use Custom immediately. Built-ins are a convenience, not a dependency.

### 6.3 Profile data shape (example)
```lua
LAYOUTS["colorkey_miniwash_quad4_mk2_16"] = {
  label = "ColorKey MiniWash Quad 4 MKII (16ch)", type = "mover_wash", verified = false,
  pan_degrees = 540, tilt_degrees = 270,
  channels = {
    { role="pan" }, { role="pan_fine" }, { role="tilt" }, { role="tilt_fine" },
    { role="pt_speed", invert=false },
    { role="dimmer" }, { role="strobe", default=0 },
    { role="red" }, { role="green" }, { role="blue" }, { role="white" },
    { role="movement_macro", steps={ {"Off",0}, {"Auto (fast)",{16,128}}, {"Auto + Sound (slow)",{129,255}} } },
    { role="sound_sens" },
    { role="color_macro", steps={ {"Off",0}, {"Color change",{1,140}}, {"Sound color",{141,255}} } },
    { role="macro_speed", max=250 },
    { role="reset", reset_value=255, reset_hold_ms=5000 },
  },
}
```
The Custom layout compiles to exactly this shape at runtime, so the rest of the driver sees only one layout format.

---

## 7. Color and intensity engine (`dmx_light` and `dmx_mover`)

Base the light_v2 side on Snap One's **`drivers-template-code-public/proxies/light_proxy`** template. It already handles:
- the light_v2 proxy commands (including `SET_BRIGHTNESS_TARGET`, `SET_COLOR_TARGET`, `BUTTON_ACTION`, ALS commands);
- On modes and color presets;
- the TOP/BOTTOM/TOGGLE `BUTTON_LINK` bindings;
- notifies.

Only `modify/light_communicator.lua` gets filled in, and it translates into role values.

### 7.1 Capabilities (set dynamically from the layout)
- Always: `dimmer=true`, `supports_target=true`, `reduced_als_support=true`, `advanced_scene_support=false`.
- If there's any color emitter beyond a single white: `supports_color=true`.
- If CCT, WW+CW, or W is available: `supports_color_correlated_temperature=true`, with `color_correlated_temperature_min/max` from the layout (defaults 2700/6500). Send both color capabilities in a **single** `DYNAMIC_CAPABILITIES_CHANGED` (the SDK warns that split updates flip preset modes).
- Dimmer type: color capabilities off.
- `has_extras=true` when the layout has any role that isn't a light role (managed by the Extras library automatically).

### 7.2 Commands to honor
Param names come from the SDK template:
- `SET_BRIGHTNESS_TARGET` (`LIGHT_BRIGHTNESS_TARGET`, `RATE`).
- `SET_COLOR_TARGET` (`LIGHT_COLOR_TARGET_X`, `LIGHT_COLOR_TARGET_Y`, `LIGHT_COLOR_TARGET_MODE` 0 = full color / 1 = CCT, `LIGHT_COLOR_TARGET_RATE`, falling back to `RATE`).
- `SET_BRIGHTNESS_STOP`, `SET_COLOR_STOP`: ask the node to freeze the fade. Add a `DMX_UPDATE` variant or `DMX_STOP {FIXTURE_ID}`.
- `RAMP_SCENE_UP/DOWN`, `STOP_SCENE_RAMP`: required by reduced ALS. Implement as a brightness ramp toward 100/0 at the given rate, and stop on the stop command.
- `BUTTON_ACTION`: handled by the template.

Notifies: `LIGHT_BRIGHTNESS_CHANGING` once at the start of a fade, `LIGHT_BRIGHTNESS_CHANGED` once at the end, and the same for `LIGHT_COLOR_CHANGING/CHANGED` (`LIGHT_COLOR_CURRENT_X/Y`, `LIGHT_COLOR_CURRENT_COLOR_MODE`). **No incremental level streaming** (SDK guidance since OS 3.3.0).

### 7.3 Mixing algorithm
1. **Target chromaticity:**
   - Full color: `r,g,b = C4:ColorXYtoRGB(x, y, 1, "srgb")`, normalized so max = 1.
   - CCT mode: if a CCT channel exists, use it; if WW+CW exist, mix them linearly by mired between `cct_min`/`cct_max`; otherwise convert Kelvin → xy → RGB and continue.
2. **White extraction** (if W present): `w = min(r,g,b) × white_mix` (a property, default 1.0); subtract `w` from r, g and b. Amber/Lime/Cyan stay at 0 in v1 and are Extras/Controls sliders. Documented as a v1 simplification.
3. **Intensity:**
   - If a Dimmer role exists: dimmer = brightness, and emitters are at full chroma.
   - Otherwise (virtual dimmer): emitters × brightness.
   - Apply an optional **gamma** (property, default 2.2 when virtual dimming, 1.0 otherwise) so low levels aren't a cliff.
4. Convert to 0–255 (or 16-bit for Dimmer + Dimmer Fine) and send one `DMX_UPDATE` with `FADE_MS` = the proxy rate.

### 7.4 Extras tab (`dmx_light`)
Use the SDK's **Light Proxy Extras Interface Library** (`Extras.lua`, `ExtrasSlider`, `ExtrasList`, `ExtrasButton`):
- One section per role group present in the layout (Beam, Effects, Maintenance).
- Sliders for raw roles.
- Lists for stepped roles (built-ins).
- A button for Reset.
- Objects the layout doesn't have are **hidden**, not removed. When the layout changes, rebuild the setup once.

Every Extras command must be answered with an `EXTRAS_STATE_CHANGED` within 10 s, or the UI reverts.

---

## 8. `dmx_mover` specifics

### 8.1 Proxies and connections

| Binding | Proxy | Name shown | Purpose |
|---|---|---|---|
| 5001 (primary) | `light_v2` | "<Fixture>" | Intensity + color exactly as §7. Goes into AL scenes, voice, Room Off. |
| 5002 | `uibutton` + `web_view_url` | "<Fixture> Controls" | Web UI (§9) |
| 5003 | `light_v2` | "<Fixture> Positions" | Position-preset selector for AL scenes and keypads (§8.3) |
| (consumer) | control input `ARTNET_DMX` | "Art-Net Node" | Binding to `artnet_node` |

`web_view_url proxybindingid="5002"`: `controller://driver/dmx_mover/contents/index.html`. The name must equal the c4z filename, and it maps to the c4z's `www/`. Also set `mobile_web_view_enabled=true`.

### 8.2 Jog engine (d-pad)
- The UI sends `JOG_START {dir}` / `JOG_STOP {dir}`, and `JOG_KEEPALIVE` every 250 ms while held.
- **Dead-man stop** after 700 ms without a keepalive (mobile and remote sessions can lose the release).
- A repeating `C4:SetTimer(50, …)` runs only while jogging. Velocity ramps from a crawl to `Jog Speed × max` over about 1.5 s. Honor the `skips` argument. Two directions can be held at once for diagonals. A tap shorter than 150 ms moves one nudge step.
- **Soft limits** (Pan Min/Max, Tilt Min/Max as a percentage, properties) are enforced in one `set_position()` used by every path: UI, presets, programming.
- **Home** = the center of the soft-limit window.

### 8.3 Presets ("Positions" and looks)
- Up to **32 slots**, persisted as JSON with `C4:PersistSetValue`.
- Record: `{slot, name, layout_id, scope{position, color, beam, effects}, fade_ms, values{role → value}}`.
- **Scope** determines what's applied:
  - `position`: pan/tilt and speed.
  - `color`: dimmer and colors. When applied, it goes through the light_v2 path so the main load's state and notifies stay correct.
  - `beam`: zoom, strobe, focus, gobo, prism.
  - `effects`: macros, programs, sound.
- **Recall:** all changed roles go in one `DMX_UPDATE` with `FADE_MS`, and 16-bit pan/tilt pairs are declared in `PAIRS`. Any active jog is cancelled. Afterwards: fire `Preset Recalled`, update the variables `CURRENT_PRESET`/`CURRENT_PRESET_NAME`, and push to the UI.
- **Layout mismatch** (preset saved with another layout): apply roles that exist, skip the rest, and log it.
- **Positions proxy (5003) level mapping:**
  - **0** → no-op for position; report 0. It must **not** black out. Blackout belongs to the main light.
  - **1–32** → recall that slot.
  - **33–100** → recall the "Default Position" preset (property).
  - Report `LIGHT_BRIGHTNESS_CHANGED` with the slot currently in effect. Manual jogs **keep** the last reported slot, so a scene LED stays lit until another scene changes it. This behavior is a named constant.
  - Uses `reduced_als_support`. Scenes send `SET_BRIGHTNESS_TARGET`, and scene `RATE` > 0 overrides the preset fade.
- **Keypad workflow** (goes in `documentation.html`): make an AL scene containing the fixture's main load (intensity/color) and its **Positions** load at N%, then bind the scene to a keypad button for native LED tracking. Programming commands cover anything else.
- Presets never store Reset.

### 8.4 Programming commands (`<commands>`)

| Command | Params |
|---|---|
| Recall Preset | `Preset` (DYNAMIC_LIST via `GetCommandParamList`), `Fade (s)` (RANGED_FLOAT −1…30, −1 = preset's own) |
| Home Position | none |
| Nudge Position | `Direction` (Up/Down/Left/Right), `Amount %` (1–25) |
| Set Control | `Control` (DYNAMIC_LIST of the layout's roles), `Value %` (0–100) |
| Reset Motors | none |

Events: `Preset Recalled`, `Reset Started`, `Reset Finished`.

---

## 9. Mover web UI (`www/contents/index.html`)

### Platform constraints (uibutton docs)
- Embedded browsers are Firefox 96 (T3 on OS 3.1.3+, T4 on OS 3.2.1+) and Chrome 30 (T3 on ≤3.1.2). **T5 and current mobile apps are unlisted, so test them.**
- Write **ES5 only** in a single file with inline CSS/JS, no external resources, and **touch + mouse** events (don't rely on Pointer Events).
- Assets referenced from CSS must use full `controller://driver/dmx_mover/contents/…` URLs so the mobile app can load them.
- Tapping the header 4× opens the debug console.
- Web views are uncertified, so keep it simple.

### JS API
- On load: `C4.subscribeToDataToUi(true)`, then `C4.sendCommand("GET_STATE","{}",false,true)`. The reply arrives via `UIRequest`.
- Commands: `C4.sendCommand(cmd, jsonString, true, true)` → `ExecuteCommand`.
- Callbacks: `onDataToUi`, `onSendCommandError`, `onSubscribeToDataToUiError`.
- The driver pushes `C4:SendDataToUI("MV_STATE", {JSON = …})` (full state) and `MV_VALUES` (deltas, ≤5 Hz). Phase 0 confirms the exact shape the page receives.

### Schema-driven rendering
The driver sends the **active layout's control schema** (roles present, labels, steps, ranges) with the state. The page builds sections only from that schema, so a 14-ch fixture without fine channels, a spot with gobos, or a Custom layout each get exactly their own controls. The page has no fixture logic.

### Layout (phone-first, 2 columns on T4/T5 landscape)
1. **Header:** fixture name, layout, DMX range, current preset, and an On/Off toggle that mirrors the main light.
2. **Position:** a large d-pad with a center Home button, pan/tilt % readouts, and a Move Speed slider (if the role exists).
3. **Intensity & color:** a dimmer slider and emitter sliders (R/G/B/W/A/UV…) for direct control, which write through the light_v2 path so Navigator's native light stays in sync. Include quick color swatches.
4. **Beam:** zoom, focus, strobe, gobo, prism, and whatever else is present.
5. **Effects:** movement macro, color macro, program, sound sensitivity, macro speed.
6. **Presets:** a grid (tap to recall), "Save current…" (slot, name, scope checkboxes, fade), rename, delete. Presets from another layout are marked.
7. **Maintenance** (collapsed): Reset Motors, Identify.

Sliders throttle sends to 100 ms and always send the final value on release. The page reconciles with state the driver echoes back, so multiple panels stay in sync.

---

## 10. Composer properties

### `artnet_node`
- Driver Version.
- Debug Mode.
- Node IP Address.
- Art-Net Net (0–127), Sub-Net (0–15), Universe (0–15).
- Keepalive (ms, 500–4000, default 1000).
- Max Frame Rate (fps, 10–44, default 30).
- Status (read-only).
- **Patch** (read-only multi-line: each bound fixture with its DMX range, plus overlaps flagged).
- Actions: Resend Frame, Blackout Universe (temporary, until any fixture changes), Test Channel (sets channel N to value V for 5 s), Re-sync Fixtures.

### `dmx_light` / `dmx_mover` (shared)
- Driver Version.
- Debug Mode.
- Fixture Type.
- Layout.
- Start Address.
- Footprint (read-only).
- Custom channel properties (§5.2).
- CCT Min/Max.
- White Mix.
- Gamma.
- Default Fade (ms).
- Status (read-only: node binding, registration, conflicts).
- Action: **Identify** (flashes the fixture 3×, then restores).

### `dmx_mover` additions
- Pan Min/Max, Tilt Min/Max (%).
- Jog Speed (1–10).
- Default Position (DYNAMIC_LIST).
- Selected Preset (DYNAMIC_LIST) with actions Recall/Delete.
- Presets Export/Import (STRING JSON).
- Action: Reset Motors.

Dynamic lists are not persisted, so rebuild them in `OnDriverInit` with `C4:UpdatePropertyList`.

### State persistence
Each fixture persists its role values (debounced about 5 s) and re-sends `OFFSETS=ALL` on `OnDriverLateInit` and on `NODE_RESYNC`. A controller reboot restores the rig without jumps.

---

## 11. Phase 0: verification spike (do first, report before full build)

| # | Verify | Pass | Fallback |
|---|---|---|---|
| 1 | Node UDP: `CreateNetworkConnection` + `NetConnect(id, 6454, "UDP")` + `SendToNetwork` to the Pknight | Valid ArtDmx in Wireshark/DMX-Workshop; a par lights | Static UDP connection in driver.xml |
| 2 | Pknight port-address mapping | Driver 0/0/0 → node 0/0/0 works | Adjust mapping and document |
| 3 | Custom-class control binding node → fixture; `GetBoundProviderDevice` returns the node's device id; `SendToDevice` both ways | Messages round-trip | Use the SendToProxy-over-binding variant, or a `DEVICE_SELECTOR` property |
| 4 | One provider output can bind **many** consumers | 3+ fixtures on one output | 24 numbered outputs |
| 5 | `dmx_mover` multi-proxy: light_v2 (5001) + uibutton (5002) + light_v2 (5003) load, and each light_v2 gets its own capabilities (color on 5001, none on 5003) | Both loads usable in the AL editor | Put Positions in a tiny separate c4z that forwards via `SendToDevice` |
| 6 | light_v2 color end to end with the SDK template: Navigator picker → `SET_COLOR_TARGET` → xy→RGBW → fixture; AL scene with color | Colors look right on the par | Tune the mixing constants |
| 7 | Extras tab on light_v2 shows sliders/lists and hides objects | Visible on T4/T5 + app | Move par extras to Composer programming commands only |
| 8 | Web view path, JS API message shapes, hold/release on T4/T5/iOS/Android, local + remote | Controls render; the d-pad stops reliably | light_v2 Extras on the mover with tap-to-nudge buttons |
| 9 | Fixture facts: MKII strobe 0 = no strobe?; MKII speed direction; MKII reset hold time; DazzlingStage 4/8-ch order from the paper manual | Set `verified=true` in profiles | Fix `profiles.lua` |

Record findings in the repo (protocol notes under `tools/pcap_notes/` per project convention).

---

## 12. Code organization and testing

```
drivers/dmx_artnet/
  common/                    -- shared pure Lua, copied/squished into each c4z
    artnet.lua               -- pack(net, subnet, universe, seq, slots) -> string
    layouts.lua              -- role catalog, types, built-in layouts, custom compiler
    color.lua                -- xy/CCT -> emitters, white extraction, gamma
    protocol.lua             -- node<->fixture message encode/decode
    presets.lua              -- mover presets, scopes, persistence adapter
    jog.lua                  -- jog engine with injectable clock
  artnet_node/   driver.xml, driver.lua, lib/universe.lua (slices, fades, HTP overlap), lib/output.lua
  dmx_light/     driver.xml, driver.lua, light_communicator.lua, extras glue, www/
  dmx_mover/     driver.xml, driver.lua, light_communicator.lua, webui_bridge.lua, www/contents/index.html
  tests/         Lua 5.1 unit tests with a C4 stub
```
- Use the SDK light template and the Extras library as vendored dependencies. Follow the repo's existing build/squish conventions.
- **Unit tests (off-controller):**
  - Art-Net bytes (header, SubUni/Net, 512 length, sequence roll).
  - Layout compile (custom map → same shape as a built-in).
  - Footprint bounds.
  - Color engine: known xy → expected RGBW; virtual dimmer + gamma.
  - Universe merge and HTP overlap.
  - 16-bit pair fades.
  - Preset scopes and cross-layout recall.
  - Positions-level mapping.
  - Jog dead-man with a fake clock.
- **On-controller checklist:**
  - 4 pars + mover on one node with no flicker or overwrite.
  - AL scene with par colors + mover color + Positions at N% on a keypad with LED tracking.
  - Room Off.
  - Voice on/off/color.
  - Reboot restore.
  - Keepalive about 1 Hz when idle.
  - Overlap warning when two fixtures share channels.

---

## 13. Out of scope / later
- QLC+ link. Later options: trigger QLC+ cues from Control4, or put `artnet_node` into a "yield" mode where QLC+ becomes the only sender.
- sACN output (the Pknight is Art-Net only).
- ArtPoll discovery.
- Multi-element ALS.
- Amber/Lime/Cyan in color mixing.
- Pixel-mapped fixtures.
- Chases or effects generated by Control4.

## 14. Acceptance criteria
1. The dealer adds one `artnet_node` per node, then a `dmx_light` or `dmx_mover` per circuit. Each fixture is configured by Fixture Type → Layout (built-in or Custom) → Start Address and bound in Connections. Invalid footprints and overlaps are reported clearly.
2. Pars behave like native Control4 color lights (Navigator picker, scenes, keypads, voice), with their non-light channels on the Extras tab.
3. Movers are one driver. Intensity and color are native. The Controls page shows only the layout's controls. The d-pad moves while held and stops on release or within 0.7 s.
4. Mover presets can be saved and recalled from the UI, from programming, and from AL scenes via the Positions load, with keypad LED tracking.
5. Several fixtures share one universe with no overwrites. Fades run on the node. Idle keepalive is about 1 Hz and active updates are capped at the configured frame rate.
6. State and presets survive a controller reboot without the rig jumping.

---

## 15. Sources
- [ColorKey Mover MiniWash Quad 4 MKII manual (DMX charts)](https://www.bhphotovideo.com/lit_files/938789.pdf)
- [DazzlingStage mini par listing (4/8 CH)](https://www.amazon.com/Dazzlingstage-Lightweight-Sound-Activated-Controlled-Decoration/dp/B0D8HZ3LRM)
- [Art-Net 4 specification](https://art-net.org.uk/downloads/art-net.pdf)
- [Pknight CR011R product page](https://www.pknightpro.com/products/pknight-bi-directional-artnet-controller-cr011r) · [CR011R quick start](https://www.manualslib.com/manual/3762782/Pknight-Art-Net-Cr011r.html)
- [Control4 Vibrant DALI/DMX gateway install guide (reference model: gateway + DMX Light drivers via Connections)](https://docs.control4.com/docs/product/creative-lighting-made-for-control4-vibrant-dalidmx-gateway/installation-guide/english/latest/)
- [DriverWorks SDK home](https://github.com/snap-one/docs-driverworks) · [API reference](https://snap-one.github.io/docs-driverworks-api) · [XML reference](https://snap-one.github.io/docs-driverworks-xml) · [Fundamentals (multi-proxy, dynamic lists, Light V2 Extras library)](https://snap-one.github.io/docs-driverworks-fundamentals/)
- [Light V2 proxy docs](https://snap-one.github.io/docs-driverworks-proxyprotocol-lightv2) · [UI Button proxy docs (web view + JS API)](https://snap-one.github.io/docs-driverworks-proxyprotocol-uibutton)
- [Driver template code: light proxy template](https://github.com/snap-one/drivers-template-code-public)
- Reference design only: the Control4 "ArtNet DMX via Enttec ODE" master/element driver (v8.0.1, 2015), with a master per node, element drivers bound to it, fades on the master, and universe/subnet/Net properties.
