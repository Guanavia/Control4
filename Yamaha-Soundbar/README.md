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

**Full IP control works end to end.** The remaining gap is **state feedback**: power and input are
write-only, so the driver reports what it last sent rather than what the bar is doing. Change the
input with the Yamaha remote and Control4's UI drifts out of sync until the next command.

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

The log distinguishes the failure points that matter: socket going down *before* the request is
sent points at a rejected handshake (client cert), whereas a close with no response after sending
points at the server side.

> **The bundle probe is advisory and can be wrong in both directions.** Director reads the PEM out
> of the `.c4z` itself, so the TLS handshake is the only authoritative test. The first version of
> this check used `C4:ReadFile()` — which **does not exist** in DriverWorks, fails silently inside
> a `pcall`, and reported "cert not readable" on the very run whose handshake succeeded. It now
> uses `C4:FileExists()`. Never probe with `C4:FileOpen()`: it *creates* the file when missing.

> **Composer caches drivers by version.** After a rebuild, **remove and re-add** the driver — the
> build-tag line in `OnDriverLateInit` confirms which build is actually live.
