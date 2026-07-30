# Yamaha YAS-108 — Control4 driver

IR-only DriverWorks driver for the Yamaha YAS-108 soundbar.

## Why IR only

The YAS-108 has **no network interface** — no wifi, no ethernet, no local API. That is a hardware
fact, not a limitation of this driver, and everything else follows from it:

- The driver knows only what it last **sent**. Nothing confirms it, ever.
- Status properties are named **`Assumed …`** rather than `Current …`, because calling them
  "current" would put the lie in the label.
- `<capabilities>` deliberately does **not** declare discrete volume or discrete mute. The remote
  has up/down and a mute toggle, and with no feedback nothing could correct an estimated absolute
  level — so declaring them would force the driver to guess forever.

This is the opposite trade to the [YAS-209](../Yamaha-YAS209/), which has a Linkplay module and
therefore a real IP path with state feedback.

## Power and mute are toggle-only

The remote has no discrete power or mute keys — the capture Dave made confirms it, with those four
codes coming back empty. So discrete commands are **synthesised**: the driver sends a toggle only
when its assumption differs from what was asked.

That inverts if anyone uses the soundbar's own remote. Two Actions correct the assumption without
sending IR: **`Resync: bar is actually ON` / `OFF`**.

## IR codes

All 18 were captured from the genuine YAS-108 remote via Composer's IR learning
(`receiver_YAS-108-IRCodesTest_Receiver.c4i`, kept here for provenance), then **renumbered into
this driver's own id range**. The capture's ids collide semantically with the YAS-209 driver's —
its `1000` is Bass Extension, this one's was HDMI — which would be a trap for anyone comparing the
two side by side.

**Not yet tested on hardware.** The codes are captured from the real remote so they should be
correct, but no button has been fired at an actual YAS-108 yet.

## Build

```bash
./build.sh          # -> Yamaha-YAS108.c4z
```

The build validates driver.xml, compiles driver.lua, auto-bumps the integer `<version>` when
content changed, warns if a property or Action is missing from the documentation, and stamps the
product version + build number + fingerprint into the driver so the loaded build is identifiable.

## Testing without hardware

```bash
lua test/simharness.lua driver.lua normal TestIrEmitter
lua test/simharness.lua driver.lua normal "PROXY:SET_INPUT=3001"
lua test/simharness.lua driver.lua normal "PROP:Subwoofer Level=3"
```

The harness stubs the `C4` API and reports which IR codes were emitted on which binding. **Any
code id the driver sends that is not declared in `driver.xml` is a hard error** — on real hardware
that mistake is invisible, because a bad id and a dead emitter both produce silence.

Archetype `unbound` simulates Director reporting nothing on the IR binding.
