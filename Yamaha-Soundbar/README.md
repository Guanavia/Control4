# Yamaha Soundbar — Control4 driver

Umbrella DriverWorks driver for Yamaha soundbars. First supported model: **YAS-209**.
Presents to Control4 as a **Receiver** proxy (power / volume / mute / input select) plus Actions
for transport and hardware bringup.

> **The YAS-209 is not a MusicCast/YXC device.** It is a **Linkplay (WiiMu)** module — port 80 is
> closed and there is no YXC API on it. The v1 driver was written against the YXC docs and was
> wrong for this unit; the whole control layer was reverse-engineered from scratch. Full playbook,
> including cert extraction and the general method for other locked devices:
> [`research/LINKPLAY_RE.md`](research/LINKPLAY_RE.md). `research/DESIGN.md` is the superseded v1
> design, kept only for reference.

## Status

| Layer | Transport | State |
| --- | --- | --- |
| Volume / mute / transport | UPnP SOAP on `:49152`, no auth | **Validated on the real bar** (real director, 2026-07-26) |
| Power / input select | Linkplay httpapi on `:443`, mutual TLS | **Validated on the real bar** (real director, 2026-07-27) — handshake, `getStatusEx`, power on/off and input select all confirmed |

**Full IP control works end to end.**

## State feedback

Power and input are read back from the bar so the UI stays right when someone uses the Yamaha
remote or the front panel, on a **separate and much slower timer** than volume/mute
(**State Poll Seconds**, default 30s; `0` disables it). The two cadences are deliberately
different: UPnP is cheap plaintext SOAP, but every httpapi read costs a **full mutual-TLS
handshake**, because each request is one connect with `Connection: close`. Polling power/input at
the 3-second volume cadence would mean a TLS handshake every three seconds, forever.

Two decode tables are **provisional** and finish themselves from a real session:

- `MODE_TO_CONN` in `driver.lua` maps the Linkplay `mode` code to an input. The streaming,
  Bluetooth and optical codes are the documented values; **HDMI is unconfirmed on this unit**.
  Any unrecognised mode is logged once at WARNING with its raw value, so switching through the
  inputs with Debug logging on completes the table.
- Power feedback reads `"power saving"` from `YAMAHA_DATA_GET`. If that field isn't in the
  payload, the driver says so once rather than silently reporting nothing.

## Surround and EQ (the device control UI)

**Surround now works.** The Surround section of the device's control UI in Composer is driven
entirely by `<capabilities>`: it needs `has_discrete_surround_mode_select` plus a
`<surround_modes>` list of `{name, id}`. The driver declared neither, which is exactly why that
section was blank — nothing to do with the bar. It now declares all six confirmed modes (Movie,
Music, Sports, Game, TV Program, Stereo), handles `SET_SURROUND_MODE`, and reports
`SURROUND_MODE_CHANGED` when the mode changes at the bar.

Because surround is a proxy concept, **Sound Program is no longer a property** — it belongs in the
control UI, not the properties list. The `3D Surround`, `Clear Voice` and `Bass Extension` toggles
stay as properties: the receiver proxy models surround as a single mode list and has no concept of
independent DSP toggles, so there is nowhere else for them to go.

**EQ is deliberately left empty, and that is the honest answer.** Composer's EQ section is driven
by `has_discrete_bass_control` / `has_up_down_bass_control` and their treble, balance and loudness
equivalents. **This bar has none of them.** Everything `YAMAHA_DATA_GET` exposes that is
EQ-adjacent is either a toggle (`bass extension`) or a level with an unknown valid range
(`subwoofer volume`); there is no treble or balance control on the hardware at all. Declaring the
capability anyway would hand a dealer sliders that silently do nothing — worse than an empty
section.

The one realistic route to a populated EQ section is mapping **bass → `subwoofer volume`** — the
app's Subwoofer Boost, a signed level centred on 0 that moves both ways alongside the bass
extension toggle. Its limits are unknown, so **Actions → Learn Subwoofer Range** finds them: it
reads a baseline, writes a junk value as a negative control, then steps outward in each direction
until the bar either clamps (which reveals the limit in a single write) or refuses. Once the range
is known it can be mapped to the receiver proxy's BASS control for a real slider. Linkplay's `eq`
field in `getPlayerStatus` is a second lead, probably written via `setPlayerCmd:equalizer:<n>`,
untested.

## Testing without hardware

`test/simharness.lua` runs the driver against a simulated bar — see [test/README.md](test/README.md).
It has already caught three transport bugs that hardware testing missed, two of which were silently
latent on the real device. Run it before any hardware trip.

## Inputs

TV (ARC / optical), HDMI In, Bluetooth, Network / Streaming.

There is deliberately **no separate "Optical In"**. The bar has one optical/ARC input and the
Linkplay layer exposes exactly one `switchmode` for it (`optical`) — the same target the TV input
selects. A second entry was a duplicate control that picked the identical source, so it was
removed.

**All testing for this project is on real hardware by necessity** — a virtual director has no path
to the bar, so there is no VD test loop here.

## Two control surfaces

- **UPnP `:49152`** — no authentication. Volume, mute, transport. Polled for live state.
- **Linkplay httpapi `:443`** — **mutual TLS**, requires a client certificate extracted from
  Yamaha's app. Power and input only. Gated behind the **Owner Approved** property.

Confirmed commands (captured and validated against the bar):

| Function | Command |
| --- | --- |
| Power on | `YAMAHA_DATA_SET:{"power saving":"1"}` |
| Power off (standby) | `YAMAHA_DATA_SET:{"power saving":"0"}` |
| Input select | `setPlayerCmd:switchmode:HDMI\|bluetooth\|optical` (TV = `optical`) |

## Why the httpapi path is a raw socket, not `C4:url()`

`C4:url()` has **no client-certificate support** — confirmed by reading Control4's own
`global/url.lua`, where `SetOptions` handles cookies, `fail_on_error` and timeouts and nothing
else. It therefore cannot complete a mutual-TLS handshake, no matter how it is configured.

So power/input instead go over a **raw SSL network connection**: `driver.xml` declares binding
**6002 / port 443** with `classname SSL` and `certificate` / `private_key` / `cacert` (all three
may point at the same PEM — Control4 documents this). Director performs the handshake and hands
the driver a byte stream, over which `driver.lua` speaks HTTP/1.1 itself. The bar runs an old Boa
server, so requests carry `Connection: close` and the socket close is treated as end-of-body
(`Content-Length` is honoured when present).

The connection is bound to the **IP Address** property via `C4:CreateNetworkConnection`, so the
dealer never enters the address twice.

## Auto-discovery — where this actually stands

**True SDDP is not achievable here, and it isn't a driver-side limitation.** SDDP is a *device-side*
protocol: the bar itself would have to broadcast SDDP announcements naming the driver to load
(`driver` and `primary_proxy` are fields in the announcement). Implementing it requires Snap One's
SDDP SDK under a signed licence agreement, and it would have to live in Yamaha's firmware. Nothing
a third-party driver can add gets a non-SDDP device into "Discovered Devices" as an SDDP device.

**But Director's discovery is not SDDP-only.** `C4:GetDiscoveryInfo(binding)` documents three
mechanisms — **SDDP, DDDP and UPNP** — and returns `uuid`/`ip`/`model`/`manufacturer`/`name`/
`location` for UPnP-discovered devices. This bar *is* a UPnP MediaRenderer with a stable
`upnp_uuid` (`FFB8F002-0E74-2090-E14B-CD76FFB8F002`), so it is visible to that mechanism.

So the realistic feature is **auto-configuration rather than auto-discovery**: have the driver
locate the bar itself (SSDP/UPnP, matched on that UUID or the Linkplay model string) and populate
the IP Address property automatically — which also makes it self-heal when DHCP moves the bar.
That captures most of the day-to-day value of SDDP without the licensing. **Not built yet**; the
open question is how far Composer's own "Discovered Devices" list will go toward binding a
UPnP-discovered device to a custom driver, versus the driver simply self-locating.

## Layout

- `driver.xml` — devicedata: `receiver` proxy, connections (incl. the SSL httpapi port), properties, actions.
- `driver.lua` — UPnP SOAP layer, SSL httpapi transport, polling, receiver-proxy handlers.
- `build.sh` — produces the `.c4z`.
- `www/documentation.rtf` — dealer-facing docs shown in Composer.
- `www/icons/` — **placeholder** icons (replace with real artwork).
- `research/` — RE playbook + design notes. **Not shipped in the `.c4z`.**
- `linkplay_client.pem` — extracted client cert. **Gitignored** (gray-area material); regenerate
  per `research/LINKPLAY_RE.md`.

## Build the `.c4z`

```bash
./build.sh                 # plain private key (default)
ENCRYPT_KEY=1 ./build.sh   # encrypted key + protected="True"  (fallback, see below)
```

A `.c4z` is just a zip of the driver files at the archive root — no `research/`, no build script,
no README. The build stages into a temp dir, bundles the client cert, and prints what actually
went into the archive.

### Encrypted-key fallback (not needed — the plain key works)

The plain key was accepted on hardware, so this is only insurance. Control4 supports an encrypted
private key via `protected="True"` on `private_key`, which makes Director call
`GetPrivateKeyPassword(Binding, Port)` in the driver to obtain the passphrase — so the password is
entirely ours to choose, not a Control4 secret. `ENCRYPT_KEY=1 ./build.sh` re-encrypts the key
**and** stamps the attribute onto `driver.xml` in the staged copy; `driver.lua` already returns the
matching passphrase, so no Lua edit is needed. Both variants are verified to build.

## First-time configuration

1. Add the driver, place it in the soundbar's room.
2. Set the **IP Address** property (DHCP-reserve the bar).
3. Bind the **AUDIO/VIDEO OUTPUT** end-point to the room; wire real sources to the HDMI/Optical/TV inputs.
4. Leave **Owner Approved** at `No` unless the equipment owner has consented — see below.
5. For power/input, set **Owner Approved** to `Yes`, then run **Actions → Test httpapi (SSL)**.

### Owner Approved

Power and input rely on a client certificate extracted from Yamaha's own app. That is the
**equipment owner's** call to make, so it is gated behind a property that defaults to `No`. While
it is `No`, the driver still does volume, mute and transport over UPnP and leaves power/input to
IR. The same pattern should be reused for any future gray-area capability — see
`research/LINKPLAY_RE.md`.

## Hardware bringup

Set **Log Level** to `5 - Debug` and **Log Mode** to `Print and Log`, then use the two diagnostic
Actions:

- **httpapi Diagnostics** — dumps control method, Owner Approved, address, what the bundled PEM
  actually contains, SSL binding state, and queue depth. No network traffic.
- **Test httpapi (SSL)** — runs the diagnostics, then sends `getStatusEx` over the socket and
  reports pass/fail.
- **Learn Input Codes** — the one-press way to finish `MODE_TO_CONN`. Selects each input in turn,
  waits for the bar to settle, reads `getPlayerStatus` back, and prints a paste-ready table, then
  restores the input it started on. It works because ground truth is whatever *we* just selected:
  the send side (`switchmode`, a string) is confirmed, so whatever number comes back on the read
  side belongs to that input. **This physically cycles the bar through its inputs.**
- **Probe Yamaha Settings** — dumps the raw payloads of every read command (`YAMAHA_DATA_GET`,
  `getPlayerStatus`, `getStatusEx`). Run it once per state you care about — each surround mode,
  each EQ preset, each input — and diff the output. **The fields that move are the ones to
  drive.** This is how surround/EQ control and the remaining input mode codes get pinned down;
  none of it can be guessed safely from the docs, because `YAMAHA_DATA_GET`'s response shape has
  never been captured.

The log distinguishes the failure points that matter: socket going down *before* the request is
sent points at a rejected handshake (client cert), whereas a close with no response after sending
points at the server side.

> **The bundle probe is advisory and can be wrong in both directions.** Director reads the PEM out
> of the `.c4z` itself, so the TLS handshake is the only authoritative test. The first version of
> this check used `C4:ReadFile()` — which **does not exist** in DriverWorks, fails silently inside
> a `pcall`, and reported "cert not readable" on the very run whose handshake succeeded. It now
> uses `C4:FileExists()`. Never probe with `C4:FileOpen()`: it *creates* the file when missing.

### Updating the driver safely — READ THIS FIRST

A project was lost on 2026-07-27 doing this the casual way: the device was deleted from the room,
then **Add/Update Driver** was run in the same pass, and the project came back empty. It had to be
restored from an online backup. The update flow expects the device to still exist; deleting first
and then updating is not a supported sequence.

**Always, before touching this driver on a live project:**

1. **Take a local backup first** (Composer → File → Backup As). Cloud backup saved the day once;
   don't rely on it. This takes seconds and is specific to the moment before your change.
2. **Know which kind of change you are installing:**
   - **Lua only** (`driver.lua`) — hot. Update in place, no restart, no drama. Most work here is
     this kind.
   - **`<capabilities>` or `<connections>`** (`driver.xml`) — structural. These are read by the
     receiver proxy when Director *instantiates* the device, so a running instance cannot absorb
     them. Composer will prompt for a **Director restart**, and that prompt is legitimate.
3. **For a structural change, prefer the Director restart** over remove/re-add on a live project.
   It costs about a minute of no automation and leaves the device, its bindings and its
   programming intact. Remove/re-add avoids the restart but discards all of that.
4. **Never delete the device and then run Add/Update Driver.** If you do want a clean re-add:
   remove the device, *finish* that operation, then add the updated driver as a new device.
5. **Batch structural changes.** Every `<capabilities>`/`<connections>` edit is another restart, so
   group them rather than shipping them one at a time.

> **Composer caches drivers by version.** After a rebuild the build-tag line in `OnDriverLateInit`
> confirms which build is actually live — check it before concluding a change did nothing.
