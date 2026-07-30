# Yamaha Soundbar — Control4 driver

Umbrella DriverWorks driver for Yamaha soundbars. First supported model: **YAS-209**.
Presents to Control4 as a **Receiver** proxy (power / volume / mute / input select) plus Actions
for transport and hardware bringup.

> **The YAS-209 is not a MusicCast/YXC device.** It is a **Linkplay (WiiMu)** module — port 80 is
> closed and there is no YXC API on it. The FIRST architecture was written against the YXC docs
> and was wrong for this unit; the whole control layer was then reverse-engineered from scratch.
> Full playbook, including cert extraction and the general method for other locked devices:
> [`research/LINKPLAY_RE.md`](research/LINKPLAY_RE.md). `research/DESIGN.md` is that superseded
> first design, kept only for reference. *(Those "first/second architecture" generations are not
> product versions — the product version is in [`VERSION`](VERSION) and is semantic.)*

## Status

| Layer | Transport | State |
| --- | --- | --- |
| Volume / mute / transport | UPnP SOAP on `:49152`, no auth | **Validated on the real bar** (real director, 2026-07-26) |
| Power / input select | Linkplay httpapi on `:443`, mutual TLS | **Validated on the real bar** (real director, 2026-07-27) — handshake, `getStatusEx`, power on/off and input select all confirmed |

**Full IP control works end to end.**

**Product version: `0.9.0`** (see [`VERSION`](VERSION)) — pre-release. It becomes **`1.0.0`** at
first release, once IR is verified on the bar. Per repo convention, `1.0.0` means shipped; `0.x`
means still in the pipeline.

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

**Bass was tried through the proxy and withdrawn — the subwoofer lives in a property instead.**
The bar's Subwoofer Boost is a real, useful control: **−4 to +4, 0 = flat**, a range learned from
the bar itself by **Actions → Learn Subwoofer Range** (it reads a baseline, writes junk as a
negative control, then steps outward until the bar clamps or refuses) and independently confirmed
against the Yamaha app.

Wiring it to the proxy's bass control did not work out, for a structural reason worth recording:
**the receiver proxy cannot declare a bass range.** There is no bass equivalent of
`volume_number_of_steps` anywhere in its capabilities. With `has_*_bass_control` set, Composer
renders an **unbounded number box** — it was driven past 1000 by holding the up arrow — while the
bar accepts only ±4, so the driver clamps and the number on screen becomes fiction. A control that
misrepresents its own range is worse than no control.

So the subwoofer is the **Subwoofer Boost** property (`RANGED_INTEGER`, −4..4), which Composer
bounds correctly, and the EQ section stays empty. Don't re-add `has_discrete_bass_control` without
first solving the range problem.

Linkplay's `eq` field in `getPlayerStatus` belongs to the Linkplay layer, not the Yamaha one, and
is **deliberately not pursued**: Yamaha exposes no EQ anywhere, and if the field is live at all it
most likely affects only the network-streaming path. Subwoofer Boost covers the real need.

## Testing without hardware

`test/simharness.lua` runs the driver against a simulated bar — see [test/README.md](test/README.md).
It has already caught five bugs that hardware testing missed, two of which were silently
latent on the real device. Run it before any hardware trip.

## IR bringup — start here if IR "does nothing"

IR is one-way. The driver gets no acknowledgement, so **a wrong code, an unbound connection, a
missing emitter and a command the driver never routed to IR all look identical** — total silence.
The only way through is to eliminate them in order, and the actions below exist to do exactly that.

**1. `Test IR Emitter (fires Power On)`.** Fires one code with nothing else in the path: no proxy,
no capabilities, no Control Method check and no IP address, and reports what
Director says is bound to the IR output. Its output goes through the unsilenceable log path, so it
reports even with `Log Mode = Off`.

- **Emitter blinks** → the binding and emitter are fine. Any remaining failure is the code set or
  the routing; go to step 2.
- **No blink** → stop. It is physical: the IR output is not bound to this driver's IR connection,
  the emitter is not in the port, or it is not over the bar's IR window. No code change helps.

**2. `Verify IR Codes`.** Fires each code and scores it by reading the bar back over the IP path,
so every code gets an objective verdict. It needs Control Method = IP` and an `IP Address` —
without the readback there is no ground truth at all. It refuses loudly if either is missing.

**Control Method does not gate this.** `Verify IR Codes` and the emitter tests call `C4:SendIR`
directly, so they work with Control Method = IP. That is deliberate: IP is the measuring
instrument for the IR path, and you want both at once.

Each code is scored against a **prepared** baseline — the bar is first driven to the *opposite*
state over IP, and if that fails the code is reported `INCONCLUSIVE` rather than passed. Without
this, `POWER_ON` "passes" whenever the bar is already on, i.e. with no emitter connected at all.
The offline harness caught exactly that false pass; `lua test/simharness.lua driver.lua noemitter
VerifyIrCodes` is the standing negative control (must report nothing working) and `... irworks
VerifyIrCodes` the positive one (must report everything working).

### What IR can and cannot drive

| Control | Over IR | Note |
|---|---|---|
| Power on/off | yes | |
| Mute on/off/toggle | yes | |
| Volume up/down (press) | yes | one pulse per press |
| Volume (slider / absolute) | approximated | pulses toward the target from the last assumed level; drifts, since nothing confirms it |
| Volume press-and-hold | yes | `C4:SendIRStart`/`Stop`, falls back to a single pulse |
| Input select | **no** | refuses with a message — the seeded YSP-1000 set has TV/DVD/VCR/AUX, not this bar's inputs |
| Surround / EQ / subwoofer | **no** | IP only |

`<capabilities>` is **not per-control-method** — `has_discrete_volume_control` applies in IR mode
too, so Navigator and Halo send `SET_VOLUME_LEVEL` regardless. Every proxy command therefore needs
an IR branch or an explicit refusal; a command with neither falls through to the IP path and
silently emits nothing. Unimplemented proxy commands are now reported once each through the
unsilenceable path for this reason.

### Code provenance

Patterns are **candidates** seeded from Control4's Yamaha YSP-1000 driver (a 2005 soundbar).
Yamaha reuses system codes, so power/volume/mute have a fair chance; nothing is confirmed on the
YAS-209. `transmit` must be `PULSE` — the seed marks volume as `SUSTAIN`, which is an `av_gen`
convention where the *proxy* drives `SendIRStart`/`Stop` for you. A DriverWorks driver calls
`C4:SendIR` itself, and every shipping `lua_gen` IR driver checked (Pioneer VSX-LX503, 433 codes)
uses `PULSE` exclusively. The volume codes were converted on that basis.

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
  Yamaha's app. Power and input only. Requires **Control Method = IP**.

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

### Versioning — two different versions, only one of which Composer compares

A Control4 driver carries **two unrelated version strings**, and confusing them costs a session:

| | Where | What it does |
|---|---|---|
| **Product version** | `./VERSION`, semantic | What we call the driver. **Pre-release is `0.x`; the first RELEASE is `1.0.0`.** Edit by hand when the product moves. |
| **`<version>`** | `driver.xml`, a plain **integer** | A build counter, auto-bumped by `build.sh`. **The only one Composer compares** on Add/Update Driver — equal versions → *"versions are equal"* and your new code never loads. Not human-facing; the catalog agrees (Pioneer VSX-LX503 = 117, Onkyo TX-NR747 = 104). |
| **"Driver Version"** | a readonly property | **What Composer displays** — the stamped combination of the two above. |

The display property was maintained by hand and drifted: it read `2.1.0` for four builds while
`<version>` climbed 3→4→5. So "Composer says 2.1.0" and "the package is version 6" were both
true and neither answered the question.

All of it now comes from **one stamp**. The token `@BUILD@` appears in the property default, the
`UpdateProp` call and the load-line log; `build.sh` replaces all three at package time with
`v<product> (build <n>, <sha8>)` and **fails the build if the token is missing** — a version display
that can lie is worse than none. `build.sh` also **auto-bumps `<version>`** when the content
changed but the version did not (an unchanged rebuild keeps its number, so iterating doesn't
churn it). Never hardcode a version string here again.

The build prints the version, fingerprint and package sha; the driver logs the same string on
load through the unsilenceable path. **If the controller logs a different build than the one you
just built, Composer did not take your file** — check which file it opened (a stale copy that
hasn't synced to the Composer machine is the usual cause) before suspecting the code.

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
4. For IP control, set **Control Method** to the IP option, then run
   **Actions → Test IP Control Compatibility**.

### IP Control

The soundbar's local API requires a **client certificate** for mutual TLS. It was extracted from
the Yamaha mobile app, and inspecting it settles what it is:

```
subject = C=CN, ST=Shanghai, O=Linkplay, CN=www.linkplay.com   (self-signed)
serial  = 01        valid 2018-11-15 -> 2046-04-01
X509v3 extensions: none
```

Nothing in it is device-specific — no MAC, no serial, no per-unit identifier — and the identity is
**Linkplay's, not Yamaha's**. So it is a single shared credential baked into the Linkplay stack,
which means it should work on any YAS-209 without re-extraction, and plausibly on other
Linkplay-based products too (unverified). It ships inside the `.c4z`, so IP control needs no setup
beyond an IP address.

**The risk that follows from it being shared: a firmware update could rotate it, and would do so on
every device at once.** Time is not the threat — it runs to 2046 — only a deliberate rotation is.

**The driver cannot recover from that by itself.** There is no DriverWorks API that supplies a
client certificate at runtime: `NetPortOptions` carries only encoding/padding keys, and Director
reads the cert from the `driver.xml` paths at connection setup. The `.c4z` is a read-only archive,
and mutual TLS means the bar demands a certificate rather than issuing one. Replacing it means
extracting from the updated app and rebuilding. That is well outside what an integrator would
attempt, which is why the driver's job is to **state the verdict plainly** rather than leave it to
be inferred.

- **`Test IP Control Compatibility`** — attempts the handshake and a status read, then reports
  `COMPATIBLE` or `NOT COMPATIBLE` with the model and firmware the bar returned. Run it at install
  and after any soundbar firmware update. Safe to run under IR; it only tests whether IP *could*
  work.
- **State feedback** — IP only. Power, input, volume, mute, sound program and DSP settings are read
  back, so the UI stays right when someone uses the Yamaha remote, the panel or the app.
- **Exact volume** — IP only. Absolute level instead of the IR estimate, which drifts.
- **3D Surround / Clear Voice / Bass Extension** — IP sets the exact state; IR can only toggle.
- **Subwoofer Boost** — both methods, but only IP confirms what applied.
- **`Poll Interval Seconds` / `State Poll Seconds`** — IP only. Each state read is a full TLS
  handshake, which is why that timer is slow; `0` disables it in favour of `Get Device Status`.

**There is no `Owner Approved` property.** It was removed (2026-07-30): it gated the gray-area IP
path behind a consent toggle, but it was unlike anything in any other driver, easy to forget even
for the person who wrote it, and its refusal was the second-most-common cause of "the driver does
nothing". The consent it represented is now carried by documentation — the dropdown itself reads
**"IP - See Documentation for Usage"**, and this section is what it points at.


## Hardware bringup

Set **Log Level** to `5 - Debug` and **Log Mode** to `Print and Log`, then use the two diagnostic
Actions:

- **httpapi Diagnostics** — dumps control method, address, what the bundled PEM
  actually contains, SSL binding state, and queue depth. No network traffic.
- **Test IP Control Compatibility** — runs the diagnostics, then sends `getStatusEx` over the socket and
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
   It costs about a minute of no automation and leaves the device, its bindings, its programming
   **and its property values** intact. Remove/re-add avoids the restart but discards all of that.
   **This has now cost something twice:** once the project itself, and once a silent loss of
   volume control — a re-add reset **IP Address** to its blank default, so the driver received
   every button press and had nowhere to send it. If anything stops working right after a
   re-add, **check the properties before debugging the code**: IP Address, Control Method and
   the poll intervals are all back at defaults.
4. **Never delete the device and then run Add/Update Driver.** If you do want a clean re-add:
   remove the device, *finish* that operation, then add the updated driver as a new device.
5. **Batch structural changes.** Every `<capabilities>`/`<connections>` edit is another restart, so
   group them rather than shipping them one at a time.

> **Composer caches drivers by version.** After a rebuild the build-tag line in `OnDriverLateInit`
> confirms which build is actually live — check it before concluding a change did nothing.
