# Yamaha YAS-209 Sound Bar — Control4 driver design

**Status:** initial build (2026-07-25). Driver written against documentation; **not yet
load-tested on a controller or against a real YAS-209.** See "Open items / must validate on
hardware" at the bottom.

## 1. Device summary

Yamaha YAS-209 sound bar + wireless subwoofer (model YAS-CU209 bar + NS-WSW44 sub).
- **Network:** Ethernet + Wi-Fi. Control is IP (HTTP) on **port 80**.
- **Inputs:** HDMI In (4K passthrough), HDMI Out w/ **ARC + CEC** (to TV), Optical (TV), Bluetooth
  5.0, and network/streaming (Spotify Connect, Alexa built-in, DLNA server).
- **Audio modes:** Movie / Music / TV / Sports / Game / Stereo, plus Clear Voice, Bass Extension,
  and DTS Virtual:X ("3D Surround").
- **NOT full MusicCast:** marketed without MusicCast multiroom (can't add wireless surrounds). This
  is a *consumer-feature* distinction only — **the unit still exposes the Yamaha Extended Control
  (YXC) HTTP API**, which is what this driver uses. Confirmed by Yamaha's own external-control FAQ
  and multiple community integrations (Home Assistant, pyamaha, etc.).

## 2. Protocol: Yamaha Extended Control (YXC) v1

- Base URL: `http://<ip>/YamahaExtendedControl/v1/`
- All requests are **HTTP GET**; responses are JSON with `"response_code":0` on success.
- Full official spec extracted to `research/YXC-API-Basic-spec.txt` (+ the source PDF).

### Endpoints used by this driver
| Purpose | Request |
|---|---|
| Device info | `GET system/getDeviceInfo` → model_name, device_id, system_version, api_version |
| Capabilities | `GET system/getFeatures` → per-zone input list, sound_program list, volume range_step (min/max/step) |
| Zone status | `GET main/getStatus` → power, volume, mute, max_volume, input, sound_program, subwoofer_volume, … |
| Power | `GET main/setPower?power=on|standby|toggle` |
| Volume (absolute) | `GET main/setVolume?volume=<n>` |
| Volume (relative) | `GET main/setVolume?volume=up|down&step=<n>` (API ≥1.17) |
| Mute | `GET main/setMute?enable=true|false` |
| Input select | `GET main/setInput?input=<id>` |
| Sound program | `GET main/setSoundProgram?program=<id>` |
| Sleep timer | `GET main/setSleep?sleep=0|30|60|90|120` |
| Bass Extension | `GET main/setBassExtension?enable=true|false` |
| Clear Voice | `GET main/setClearVoice?enable=true|false` |
| 3D Surround | `GET main/set3dSurround?enable=true|false` |
| Subwoofer vol | `GET main/setSubwooferVolume?volume=<n>` |
| Transport | `GET netusb/setPlayback?playback=play|pause|stop|next|previous` |
| Now playing | `GET netusb/getPlayInfo` → artist/track/album/albumart |

> **Input IDs and sound_program IDs are device-specific** — the authoritative list comes from
> `system/getFeatures`. The driver logs that list at startup (Actions → "Query Features") so the
> dealer can confirm the exact IDs for their unit. The Lua `INPUT_MAP` table (connection id → YXC
> input id) is the single place to adjust if a unit reports different IDs. Best-known YAS-209 IDs
> are used as defaults (`tv`, `hdmi1`, `optical`, `bluetooth`, `server`).

### Volume scaling
Control4's `receiver` proxy uses a **0–100** level. YXC uses an integer whose max comes from
`getFeatures` (`range_step` for "volume"; also echoed as `max_volume` in `getStatus`).
- C4 → YXC: `yxc = round(level/100 * VOL_MAX)`
- YXC → C4: `level = round(yxc/VOL_MAX * 100)`
- `VOL_MAX` is read from `getFeatures` on connect (default 100 until known).

### Event / notify model (optional push — see §5)
When a request carries these headers, the device sends **UDP unicast** JSON notifications on
status changes to the advertised port:
```
X-AppName: MusicCast/1.0(Control4)
X-AppPort: <udp listen port>
```
Subscription times out after **10 min** of no request from that IP (any request resets it).
Notification JSON (flat, per-zone): `{"main":{"power","input","volume","mute","status_updated"},
"netusb":{"play_info_updated","play_time"}, "device_id":"…"}`.

## 3. Control4 mapping

**Proxy:** `receiver` (proxybindingid **5001**). Auto-binds as the room's Audio Volume / Audio
Selection / Video Selection device — correct model for a soundbar (matches the shipped
`receiver_philips_sound_bar_hts8100` reference driver).

### Connections (driver.xml)
| id | type | dir | class | maps to |
|---|---|---|---|---|
| 5001 | 2 | — | RECEIVER | proxy self |
| 6001 | 4 | — | NETWORK (port 80) | IP assignment + online monitoring |
| 7000 | 7 | output | AUDIO_VOLUME, AUDIO_SELECTION, VIDEO_SELECTION | **room end-point** |
| 2000 | 5 | output | HDMI | HDMI Out → TV (passthrough/ARC) |
| 3000 | 6 | input | DIGITAL_OPTICAL | YXC `tv` (TV audio / ARC / optical) |
| 3001 | 6 | input | HDMI | YXC `hdmi1` (HDMI In) |
| 3002 | 6 | input | DIGITAL_OPTICAL | YXC `optical` |
| 3003 | 6 | input | STEREO | YXC `bluetooth` |
| 3004 | 6 | input | STEREO | YXC `server` (network/streaming) |

`SET_INPUT` carries the input connection's **id** as `InputBindingID`; the driver maps id→YXC input.

### Receiver proxy commands handled (`ReceivedFromProxy`, binding 5001)
| Proxy command | Action |
|---|---|
| `ON` / `OFF` | `setPower on|standby` |
| `SET_VOLUME_LEVEL {LEVEL}` | `setVolume` (scaled) |
| `PULSE_VOL_UP` / `PULSE_VOL_DOWN` | `setVolume?volume=up|down&step` |
| `START_VOL_UP/DOWN`, `STOP_VOL_UP/DOWN` | ramp timer of pulses |
| `MUTE_ON` / `MUTE_OFF` / `MUTE_TOGGLE` | `setMute` |
| `SET_INPUT {InputBindingID}` | map id→YXC input, `setInput` |
| `PULSE_INPUT` | cycle through mapped inputs |

### Proxy notifications sent back (`C4:SendToProxy`, binding 5001, type NOTIFY)
| Notification | When |
|---|---|
| `ON` / `OFF` | power state changes |
| `VOLUME_LEVEL_CHANGED {LEVEL, OUTPUT=7000}` | volume changes |
| `MUTE_CHANGED {MUTE, OUTPUT=7000}` | mute changes |
| `INPUT_OUTPUT_CHANGED {INPUT=<connid>, OUTPUT=7000}` | input changes |

### Extra capabilities (driver Actions + read-only/LIST Properties, outside the proxy)
Sound Program (LIST, sets `setSoundProgram`), Bass Extension / Clear Voice / 3D Surround toggles,
Subwoofer Volume, Sleep timer, and net transport (Play/Pause/Stop/Next/Previous). Now-playing +
device info surfaced as read-only properties.

## 4. State strategy

- **Polling is primary and default** (`Poll Interval Seconds`, default 3): a timer calls
  `main/getStatus`, reconciles power/volume/mute/input, and pushes proxy notifications on change.
  High confidence — pure HTTP GETs. Commands also update proxy state **optimistically** for instant
  UI, then the next poll reconciles.
- **Push events are opt-in** (`Use Push Events`, default **Off**) — see §5.

## 5. Push events — EXPERIMENTAL, validate on hardware

The UDP-notify path (header subscription + a UDP listener via `C4:CreateNetworkConnection`, 10-min
keepalive tied to the poll) is implemented but **gated behind `Use Push Events` (default Off)**
because the exact DriverWorks UDP-receive binding mechanics need on-device confirmation. Polling
covers all state without it; push only lowers latency for changes made **at the soundbar itself**.

## 6. Dependencies / notable implementation choices

- **No JSON library dependency.** YXC responses are flat; the driver extracts fields with scoped
  Lua pattern matching (`%b{}` to isolate the `main`/`netusb` sub-objects). Keeps the driver
  self-contained (stdlib Lua only), matching repo convention.
- **HTTP via `C4:url():...:Get()`**, isolated in one helper (`YxcGet`) so the exact `OnDone`
  signature / header-set method can be adjusted in one place if a firmware/OS version differs.
- Device IP comes from the **network binding (6001)**; a manual `IP Address` property overrides it
  (authoritative), so the driver works even if binding-address retrieval differs by OS version.

## 7. Open items / must validate on hardware
1. **Exact YXC input IDs** for the YAS-209 (confirm via `getFeatures`; adjust `INPUT_MAP`).
2. **Exact sound_program IDs** (confirm via `getFeatures`/`getSoundProgramList`).
3. **`C4:url()` `OnDone` signature + header-set method** for the target OS 4.x (isolated in `YxcGet`).
4. **UDP push** binding mechanics (only if `Use Push Events` is enabled).
5. `setBassExtension` / `setClearVoice` / `set3dSurround` / `setSubwooferVolume` endpoint names
   (present in Advanced spec / getFeatures; confirm on unit).
6. Icons are **placeholders** — replace with real artwork.
