# Offline test harness

`simharness.lua` runs `driver.lua` with **no controller and no soundbar**. It stubs the
DriverWorks `C4` API and simulates the bar's SSL socket end to end —
`NetConnect` → `ONLINE` → `SendToNetwork` → `ReceivedFromNetwork(HTTP response)` → `OFFLINE` —
so it exercises the real httpapi transport, the HTTP parsing and the queue, not just the sweep
logic.

```bash
lua test/simharness.lua driver.lua <archetype> <action>
```

- **archetype** — how the simulated bar behaves: `clamp` (limits out-of-range writes to the
  nearest valid value), `reject` (keeps its previous value), `acceptall` (stores any string,
  including junk), `noemitter` (accepts IR sends but transmits nothing), `irworks` (a bar that
  obeys the IR codes).
- **action** — any Composer Action name: `LearnSubwooferRange`, `LearnSoundPrograms`,
  `LearnInputCodes`, `ProbeSettings`, `TestHttpApi`, `VerifyIrCodes`, `IrTestPowerOn`.
  Two extra forms drive the **receiver proxy** instead of an Action, which is what a Navigator or
  Halo button press actually looks like to the driver:
  - `PROXY:<CMD>` — send `<CMD>` with Control Method = IP
  - `IR:<CMD>` — send `<CMD>` with Control Method = **IR**

  e.g. `lua test/simharness.lua driver.lua clamp "IR:SET_VOLUME_LEVEL=40"`. The run prints every
  IR code the driver emitted (`-- IR fired (n): ...`), and rejects any code id not declared in
  `driver.xml`. This is the only offline way to see whether a given button reaches the emitter
  at all.

The `acceptall` archetype exists to prove the negative controls fire. Running
`acceptall LearnSoundPrograms` must report **NEGATIVE CONTROL FAILED / INCONCLUSIVE** — if it ever
reports a clean all-pass, the control has stopped working and every sweep result is
unfalsifiable.

`VerifyIrCodes` has a control in **both** directions, because it can be wrong either way:

```bash
lua test/simharness.lua driver.lua noemitter VerifyIrCodes   # must report WORKING: (none)
lua test/simharness.lua driver.lua irworks   VerifyIrCodes   # must report all six WORKING
```

The negative one catches a sweep that passes codes it never proved; the positive one catches a
sweep stuck in the always-fail direction — which matters here because "all codes failed" is the
conclusion the real run is meant to be able to draw, so it has to be earned.

## Why this exists

Every hardware round trip on this project costs a driver rebuild, a Composer remove/re-add and a
trip to the bar. The sweeps are stateful async machines chaining dozens of requests, which is
exactly the kind of code that hangs or races. The harness caught **five real bugs that hardware
testing had not**:

1. **Stale-OFFLINE race.** The previous socket's close notification was being attributed to the
   next request, failing it with "socket closed with no response at all" moments before its reply
   arrived. Fixed with a settling gap (`PUMP_GAP_MS`) between requests.
2. **Cooldown raised too late.** The gap was set *after* the completion callback ran — and every
   sweep issues its next request from inside that callback, so the one request the gap existed to
   protect skipped it. Fixed by raising `gCooldown` before invoking the callback.
3. **Unreliable baseline.** The subwoofer sweep classified each probe by "did it change from what
   was there before", but never established what was there to begin with, making the negative
   control — which gates the whole sweep — a coin flip. Fixed with a baseline read.
4. **False passes in the IR verification** (the same baseline bug, recurring). A state code was
   scored purely as "field == wanted after firing", which passes whenever the bar was *already* in
   the wanted state — so with the bar on and unmuted, `POWER_ON` and `MUTE_OFF` both reported
   WORKS with no emitter connected at all. Fixed by driving the bar to the opposite state over IP
   first and reporting `INCONCLUSIVE` when that fails. **This one would have produced confidently
   wrong hardware conclusions**, which is worse than a hang.
5. **`SET_VOLUME_LEVEL` had no IR branch.** In IR mode it fell through to UPnP SOAP and emitted no
   IR at all, so a volume slider or Halo press did nothing — indistinguishable from a dead
   emitter. Found by driving the proxy directly (`IR:SET_VOLUME_LEVEL=40`); the pre-fix driver
   reports `-- IR fired: none`.

Note that (1) and (2) are latent on real hardware: the timing happened to work on the bar, so the
sweeps produced correct results while silently logging failed writes. The harness makes them
deterministic.

`drain()` aborts on a timer storm, so an infinite loop in the driver fails the run instead of
hanging it.
