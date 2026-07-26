# Yamaha YAS-209 Sound Bar — Control4 driver

IP driver for the **Yamaha YAS-209** sound bar via the **Yamaha Extended Control (YXC)** HTTP API
(port 80). Presents to Control4 as a **Receiver** proxy (power / volume / mute / input select) plus
extra Actions for sound modes, DSP toggles, and net transport.

> **Status:** v1.0.0 — written from documentation. `driver.lua` compiles clean (`luac -p`), but the
> driver has **not yet been load-tested on a controller or against a real YAS-209.** See
> `research/DESIGN.md` §7 "Open items / must validate on hardware" before field use.

## Layout
- `driver.xml` — devicedata: `receiver` proxy, connections, properties, actions, commands.
- `driver.lua` — YXC HTTP layer, polling/state reconciliation, receiver-proxy handlers, optional UDP push.
- `www/documentation.rtf` — dealer-facing docs shown in Composer.
- `www/icons/` — **placeholder** icons (replace with real artwork).
- `research/` — design notes + the extracted YXC API spec. **Not shipped in the `.c4z`.**

## Build the `.c4z`
```bash
./build.sh          # produces Yamaha-SoundBar-YAS209.c4z (zip of driver files, research/ excluded)
```
A `.c4z` is just a zip of the driver files at the archive root (no `research/`, no build script,
no README).

## First-time configuration
1. Add the driver, place it in the sound bar's room.
2. Set the **IP Address** property (DHCP-reserve the sound bar).
3. Bind the **AUDIO/VIDEO OUTPUT** end-point to the room; wire real sources to the HDMI/Optical/TV inputs.
4. Run **Actions → Query Features** — logs the unit's real input + sound-program IDs. If they differ
   from the defaults, edit the `INPUT_MAP` table near the top of `driver.lua`.

## Key design decisions (see `research/DESIGN.md` for full detail)
- **Proxy:** `receiver` (matches Control4's own shipped sound-bar reference driver).
- **State:** polling `main/getStatus` is primary/default; commands update the UI optimistically then
  reconcile. UDP push events are opt-in/experimental behind the **Use Push Events** property.
- **No JSON dependency** — flat YXC responses are parsed with scoped Lua patterns (stdlib only).
- **HTTP isolated** in one `YxcGet` helper so the `C4:url()` signature can be tuned per OS version.
